#!/usr/bin/env bash
#
# healthwatch.sh — supervision minimale avec alerte e-mail. Lancé toutes les 2 minutes par un timer systemd.
#
# Usage : healthwatch.sh            exécution normale (silencieuse ; envoie un e-mail si l'état change)
#         healthwatch.sh --check    affiche le résultat de chaque contrôle, sans état ni e-mail
#
# Contrôles : Docker, conteneurs (caddy, postgres, <projet>-api : en marche ET « healthy »),
#             réponse HTTPS de chaque API (/health, via Caddy), validité du certificat (> 14 jours),
#             espace disque (< DISK_WARN_PCT %), âge de la dernière sauvegarde (< 26 h).
#
# Anti-bruit : alerte seulement après 2 échecs consécutifs (~4 min), un seul e-mail par incident,
# rappel toutes les 12 h tant que ça dure, e-mail « rétabli » à la fin.
#
# Limite assumée : si le VPS entier est éteint, il ne peut pas s'envoyer d'e-mail. Complète avec un
# moniteur EXTERNE gratuit (UptimeRobot / Healthchecks.io) sur https://<domaine>/health : voir docs/operations.md.
#
set -uo pipefail   # pas de -e : un contrôle en échec ne doit pas empêcher les suivants

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MODE="run"
case "${1:-}" in
  "") ;;
  --check) MODE="check" ;;
  *) sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

FAIL_THRESHOLD=2
REMIND_AFTER=$((12 * 3600))
BACKUP_MAX_AGE=$((26 * 3600))

PROBLEMS=()   # "clé|message"
add_problem() { PROBLEMS+=("$1|$2"); }
say() { [[ "$MODE" != "check" ]] || printf '%s\n' "$*"; }

file_age() { # âge en secondes d'un fichier (mtime), ou vide s'il n'existe pas
  [[ -e "$1" ]] || return 0
  echo $(( $(date +%s) - $(stat -c %Y "$1") ))
}

# --------------------------------------------------------------------------
# Contrôles
# --------------------------------------------------------------------------
check_container() { # check_container <conteneur>
  local c="$1" st
  if ! st="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)"; then
    add_problem "ctr-$c" "conteneur « $c » introuvable"
    return
  fi
  case "$st" in
    "running healthy"|"running -") say "  [OK]   conteneur $c ($st)" ;;
    *) add_problem "ctr-$c" "conteneur « $c » : état « $st »" ;;
  esac
}

check_https() { # check_https <projet> <domaine>
  local n="$1" d="$2"
  if curl -fsS -o /dev/null --max-time 10 --resolve "$d:443:127.0.0.1" "https://$d/health" 2> /dev/null; then
    say "  [OK]   https://$d/health"
  else
    add_problem "http-$n" "https://$d/health ne répond pas correctement (API, Caddy ou base de données)"
  fi
  if echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$d" 2> /dev/null \
      | openssl x509 -noout -checkend $((14 * 86400)) > /dev/null 2>&1; then
    say "  [OK]   certificat $d valide (> 14 jours)"
  else
    add_problem "cert-$n" "certificat TLS de $d expire dans moins de 14 jours (ou illisible)"
  fi
}

run_checks() {
  say "Docker et conteneurs"
  if ! docker info > /dev/null 2>&1; then
    add_problem "docker" "le démon Docker ne répond pas"
    return
  fi
  check_container caddy
  check_container postgres

  say "APIs"
  local p n d site
  for p in "$PROJECTS_DIR"/*/; do
    [[ -f "${p}docker-compose.yml" ]] || continue
    n="$(basename "$p")"
    check_container "$n-api"
    site="$INFRA_DIR/caddy/sites/$n.caddy"
    d=""
    [[ -f "$site" ]] && d="$(sed -n 's/^\([a-z0-9.-]\{3,\}\) *{.*$/\1/p' "$site" | head -n 1)"
    if [[ -n "$d" ]]; then check_https "$n" "$d"; else add_problem "site-$n" "domaine de $n introuvable dans $site"; fi
  done

  say "Ressources et sauvegardes"
  local pct age
  pct="$(df -P "$PROJECTS_DIR" | awk 'NR==2 { gsub("%", "", $5); print $5 }')"
  if [[ -n "$pct" && "$pct" -ge "$DISK_WARN_PCT" ]]; then
    add_problem "disk" "disque plein à ${pct} % (seuil ${DISK_WARN_PCT} %)"
  else
    say "  [OK]   disque à ${pct:-?} %"
  fi
  age="$(file_age "$BACKUP_DIR/.last_success")"
  if [[ -z "$age" ]]; then
    add_problem "backup" "aucune sauvegarde complète réussie enregistrée (lance scripts/backup.sh)"
  elif [[ "$age" -gt "$BACKUP_MAX_AGE" ]]; then
    add_problem "backup" "dernière sauvegarde réussie il y a $((age / 3600)) h (attendu : < 26 h)"
  else
    say "  [OK]   dernière sauvegarde il y a $((age / 3600)) h"
  fi
  if [[ -n "${RCLONE_REMOTE:-}" ]]; then
    age="$(file_age "$BACKUP_DIR/.last_offsite_success")"
    if [[ -z "$age" || "$age" -gt "$BACKUP_MAX_AGE" ]]; then
      add_problem "offsite" "dernière copie hors VPS trop ancienne ou absente"
    else
      say "  [OK]   dernière copie hors VPS il y a $((age / 3600)) h"
    fi
  fi
}

run_checks

# --------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
  if ((${#PROBLEMS[@]} == 0)); then
    echo; echo "Tout est OK."; exit 0
  fi
  echo; echo "Problèmes :"
  for pr in "${PROBLEMS[@]}"; do echo "  [KO]   ${pr#*|}"; done
  exit 1
fi

# --------------------------------------------------------------------------
# Gestion d'état : un e-mail par incident, rappel, rétablissement
# --------------------------------------------------------------------------
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/platform/healthwatch"
install -d -m 700 "$STATE_DIR"
NOW="$(date +%s)"
DOWN_MSGS=""; UP_MSGS=""
CURRENT_KEYS=" "

state_file() { printf '%s/%s' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }

for pr in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do
  key="${pr%%|*}"; msg="${pr#*|}"
  CURRENT_KEYS+="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_') "
  sf="$(state_file "$key")"
  count=0; alerted=0
  [[ -f "$sf" ]] && IFS='|' read -r count alerted _ < "$sf"
  count=$((count + 1))
  if [[ "$count" -ge "$FAIL_THRESHOLD" ]]; then
    if [[ "$alerted" -eq 0 ]]; then
      DOWN_MSGS+="- $msg"$'\n'; alerted="$NOW"
    elif [[ $((NOW - alerted)) -ge "$REMIND_AFTER" ]]; then
      DOWN_MSGS+="- (rappel) $msg"$'\n'; alerted="$NOW"
    fi
  fi
  printf '%s|%s|%s\n' "$count" "$alerted" "$msg" > "$sf"
done

for sf in "$STATE_DIR"/*; do
  [[ -f "$sf" ]] || continue
  base="$(basename "$sf")"
  [[ "$CURRENT_KEYS" != *" $base "* ]] || continue
  count=0; alerted=0; msg=""
  IFS='|' read -r count alerted msg < "$sf"
  if [[ "${alerted:-0}" -ne 0 ]]; then UP_MSGS+="- rétabli : $msg"$'\n'; fi
  rm -f "$sf"
done

host="$(hostname -s)"
if [[ -n "$DOWN_MSGS" ]]; then
  alert "ALERTE : problème détecté" "Problème(s) détecté(s) sur $host le $(date '+%F %T') :

$DOWN_MSGS
Diagnostic : ssh ahua, puis 'scripts/healthwatch.sh --check' et 'docker ps'."
fi
if [[ -n "$UP_MSGS" ]]; then
  alert "Rétabli" "Retour à la normale sur $host le $(date '+%F %T') :

$UP_MSGS"
fi
exit 0
