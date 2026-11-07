#!/usr/bin/env bash
#
# lib/common.sh — fonctions partagées par les scripts d'exploitation (étape 6).
# À sourcer, pas à exécuter. Ne contient et n'affiche aucun secret.
#
# Configuration optionnelle : infra/.env.ops (non versionné, voir infra/.env.ops.example).
#

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$PLATFORM_DIR/infra"
OPS_ENV="$INFRA_DIR/.env.ops"

if [[ -f "$OPS_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$OPS_ENV"
  set +a
fi

: "${PROJECTS_DIR:=/srv/projects}"
: "${BACKUP_DIR:=/srv/backups}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_PREDEPLOY:=5}"
: "${DISK_WARN_PCT:=85}"
: "${CADDY_VOLUME:=infra_caddy_data}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[ATTENTION] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }

require_not_root() { [[ $EUID -ne 0 ]] || die "Lance ce script en tant que 'deploy', pas en root."; }

require_docker() {
  command -v docker >/dev/null || die "Docker introuvable."
  docker info >/dev/null 2>&1 || die "Docker inaccessible pour '$(id -un)' (groupe docker ?)."
}

# Superutilisateur Postgres via la socket Unix du conteneur (jamais par le réseau).
pg_admin() { docker exec -i postgres psql -X -q -U dbadmin -d postgres -v ON_ERROR_STOP=1 "$@"; }
pg_db()    { local db="$1"; shift; docker exec -i postgres psql -X -q -U dbadmin -d "$db" -v ON_ERROR_STOP=1 "$@"; }

# --------------------------------------------------------------------------
# Alertes par e-mail (msmtp, configuré par setup-alerts.sh). Ne fait jamais échouer l'appelant.
# --------------------------------------------------------------------------
alert() { # alert "sujet" "corps"
  local subject="$1" body="${2:-}" host enc
  if [[ -z "${ALERT_EMAIL:-}" ]]; then
    warn "ALERT_EMAIL non défini (lance scripts/setup-alerts.sh) : alerte non envoyée : $subject"
    return 0
  fi
  if ! command -v msmtp >/dev/null 2>&1; then
    warn "msmtp absent (lance scripts/setup-alerts.sh) : alerte non envoyée : $subject"
    return 0
  fi
  host="$(hostname -s)"
  enc="=?UTF-8?B?$(printf '%s' "[$host] $subject" | openssl base64 -A)?="   # sujet encodé (accents)
  {
    printf 'To: %s\n' "$ALERT_EMAIL"
    printf 'From: %s\n' "${ALERT_FROM:-$ALERT_EMAIL}"
    printf 'Subject: %s\n' "$enc"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n'
    printf '%s\n' "$body"
  } | msmtp -t || warn "Échec de l'envoi de l'alerte par e-mail."
  return 0
}

# --------------------------------------------------------------------------
# Sauvegardes : rotation
# --------------------------------------------------------------------------
list_backups() { # fichiers de sauvegarde d'un dossier, du plus ancien au plus récent (noms horodatés)
  find "$1" -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.part' ! -name '.*' | sort
}

prune_keep() { # prune_keep <dossier> <n> : ne garde que les n plus récents
  local dir="$1" keep="$2" f i n
  local files=()
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do files+=("$f"); done < <(list_backups "$dir")
  n=${#files[@]}
  for ((i = 0; i < n - keep; i++)); do
    rm -f -- "${files[$i]}" "${files[$i]}.sha256"
  done
  return 0
}

promote_weekly() { # promote_weekly <dossier_quotidien> <dossier_hebdo> : lien dur du dernier fichier si aucun hebdo < 6 jours
  local daily="$1" weekly="$2" latest
  latest="$(list_backups "$daily" | tail -n 1)"
  [[ -n "$latest" ]] || return 0
  install -d -m 700 "$weekly"
  if (( $(find "$weekly" -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.part' ! -name '.*' -mtime -6 | wc -l) == 0 )); then
    ln -f -- "$latest" "$weekly/"
    if [[ -f "$latest.sha256" ]]; then ln -f -- "$latest.sha256" "$weekly/"; fi
  fi
  return 0
}

# --------------------------------------------------------------------------
# Déploiement
# --------------------------------------------------------------------------
wait_healthy() { # wait_healthy <conteneur> [secondes]
  local c="$1" max="${2:-90}" i st
  for ((i = 0; i < max; i += 3)); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo absent)"
    case "$st" in
      healthy|running) return 0 ;;   # 'running' = conteneur sans healthcheck
      unhealthy) return 1 ;;
    esac
    sleep 3
  done
  return 1
}

pcompose() { # pcompose <projet> <tag_image> <args docker compose...>
  local name="$1" tag="$2"; shift 2
  ( cd "$PROJECTS_DIR/$name" && IMAGE_TAG="$tag" docker compose "$@" )
}

current_tag() { # tag de l'image du conteneur <projet>-api en cours (vide si absent)
  local img
  img="$(docker inspect -f '{{.Config.Image}}' "$1-api" 2>/dev/null || true)"
  [[ -z "$img" ]] || printf '%s' "${img##*:}"
}

valid_project_name() { [[ "$1" =~ ^[a-z][a-z0-9]{1,19}$ ]]; }
