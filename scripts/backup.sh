#!/usr/bin/env bash
#
# backup.sh — sauvegarde des bases Postgres, de la configuration et des certificats Caddy.
#
# Usage : backup.sh [--db NOM] [--kind daily|predeploy]
#   (sans option)  sauvegarde quotidienne complète : une dump par base + rôles Postgres
#                  + configuration des projets (.env, secrets) + volume Caddy (certificats).
#                  Rotation : KEEP_DAILY quotidiennes (7) + KEEP_WEEKLY hebdomadaires (4).
#                  Copie hors VPS si RCLONE_REMOTE est défini (remote rclone chiffré obligatoire).
#   --db NOM       une seule base (utilisé par deploy.sh et restore.sh)
#   --kind predeploy  sauvegarde de sécurité avant déploiement/restauration (gardées : KEEP_PREDEPLOY)
#
# Disposition : $BACKUP_DIR/{daily,weekly,predeploy}/<base>/<base>_<horodatage UTC>.dump (+ .sha256)
#               $BACKUP_DIR/{daily,weekly}/_globals | _config | _caddy
# Les fichiers sont en 600 dans des dossiers 700 : ils contiennent des secrets (hachages, .env).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

ONLY_DB=""; KIND="daily"
while (($#)); do
  case "$1" in
    --db)   ONLY_DB="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ "$KIND" == "daily" || "$KIND" == "predeploy" ]] || usage
[[ -z "$ONLY_DB" || "$ONLY_DB" =~ ^[a-z][a-z0-9_]{1,40}$ ]] || die "Nom de base invalide."
FULL=0; [[ -z "$ONLY_DB" && "$KIND" == "daily" ]] && FULL=1

require_not_root
require_docker
umask 077
install -d -m 700 "$BACKUP_DIR"

# Un seul traitement à la fois (sauvegarde, test de restauration).
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || die "Une autre sauvegarde ou un test de restauration est en cours."

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PARTS=()

on_exit() {
  local code=$?
  trap - EXIT
  local p
  for p in ${PARTS[@]+"${PARTS[@]}"}; do rm -f -- "$p"; done
  if [[ $code -ne 0 && "$KIND" == "daily" ]]; then
    alert "Sauvegarde ÉCHOUÉE" "La sauvegarde $KIND du $(date -u '+%F %T') UTC a échoué (code $code).
Détails : journalctl -u platform-backup --since today   (ou relance scripts/backup.sh à la main)."
  fi
  exit "$code"
}
trap on_exit EXIT

pg_running="$(docker inspect -f '{{.State.Running}}' postgres 2>/dev/null || true)"
[[ "$pg_running" == "true" ]] || die "Le conteneur postgres ne tourne pas."

finalize() { # finalize <fichier> : somme de contrôle + affichage
  local f="$1" size
  ( cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
  size="$(du -h "$f" | cut -f1)"
  info "$(basename "$f")  ($size)"
}

dump_db() { # dump_db <base>
  local db="$1" dir out tmp
  dir="$BACKUP_DIR/$KIND/$db"
  install -d -m 700 "$dir"
  out="$dir/${db}_${STAMP}.dump"; tmp="$out.part"
  PARTS+=("$tmp")
  docker exec postgres pg_dump -U dbadmin -d "$db" -Fc -Z 6 > "$tmp"
  [[ -s "$tmp" ]] || die "Dump vide pour '$db'."
  docker exec -i postgres pg_restore --list < "$tmp" > /dev/null || die "Dump de '$db' illisible (pg_restore --list a échoué)."
  mv "$tmp" "$out"
  finalize "$out"
}

# --------------------------------------------------------------------------
log "Bases Postgres ($KIND)"
if [[ -n "$ONLY_DB" ]]; then
  [[ "$(pg_admin -At -c "select 1 from pg_database where datname='$ONLY_DB'")" == "1" ]] || die "Base '$ONLY_DB' introuvable."
  DBS="$ONLY_DB"
else
  DBS="$(pg_admin -At -c "select datname from pg_database where not datistemplate and datname <> 'postgres' and datname not like 'restore\_test\_%' order by 1")"
fi
[[ -n "$DBS" ]] || warn "Aucune base de projet à sauvegarder."
for db in $DBS; do dump_db "$db"; done

if [[ $FULL -eq 1 ]]; then
  # ------------------------------------------------------------------------
  log "Rôles Postgres (pg_dumpall --globals-only)"
  dir="$BACKUP_DIR/daily/_globals"; install -d -m 700 "$dir"
  out="$dir/globals_${STAMP}.sql.gz"; PARTS+=("$out.part")
  docker exec postgres pg_dumpall -U dbadmin --globals-only | gzip -6 > "$out.part"
  gzip -t "$out.part"
  mv "$out.part" "$out"; finalize "$out"

  # ------------------------------------------------------------------------
  log "Configuration des projets et de l'infra (.env, secrets, Caddy, pg_hba)"
  dir="$BACKUP_DIR/daily/_config"; install -d -m 700 "$dir"
  out="$dir/config_${STAMP}.tar.gz"; PARTS+=("$out.part")
  items=()
  for p in "$PROJECTS_DIR"/*/; do
    [[ -d "$p" ]] || continue
    n="$(basename "$p")"
    for f in docker-compose.yml .env secrets; do
      [[ -e "$p$f" ]] && items+=("${PROJECTS_DIR#/}/$n/$f")
    done
  done
  for f in .env .env.ops compose.networks.yml caddy/sites postgres/hba.d; do
    [[ -e "$INFRA_DIR/$f" ]] && items+=("${INFRA_DIR#/}/$f")
  done
  tar -C / -czf "$out.part" "${items[@]}"
  tar -tzf "$out.part" > /dev/null
  mv "$out.part" "$out"; finalize "$out"
  info "NB : le secret du superutilisateur Postgres (infra/secrets) n'est volontairement pas inclus."

  # ------------------------------------------------------------------------
  log "Certificats TLS de Caddy (volume $CADDY_VOLUME)"
  if docker volume inspect "$CADDY_VOLUME" > /dev/null 2>&1; then
    caddy_image="$(docker inspect -f '{{.Config.Image}}' caddy 2>/dev/null || true)"
    if [[ -z "$caddy_image" ]]; then
      warn "Conteneur caddy introuvable : volume non sauvegardé."
    else
      dir="$BACKUP_DIR/daily/_caddy"; install -d -m 700 "$dir"
      out="$dir/caddy_data_${STAMP}.tar.gz"; PARTS+=("$out.part")
      # Même image que Caddy (déjà présente, aucun téléchargement), sans réseau, en lecture seule.
      docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
        -v "$CADDY_VOLUME":/data:ro --entrypoint tar "$caddy_image" -czf - -C /data . > "$out.part" \
        || warn "tar a signalé un avertissement (fichier modifié pendant la lecture ?) : archive vérifiée ci-dessous."
      [[ -s "$out.part" ]] || die "Archive Caddy vide."
      tar -tzf "$out.part" > /dev/null || die "Archive Caddy illisible."
      mv "$out.part" "$out"; finalize "$out"
    fi
  else
    warn "Volume $CADDY_VOLUME introuvable : certificats non sauvegardés."
  fi
fi

# --------------------------------------------------------------------------
log "Rotation"
if [[ "$KIND" == "predeploy" ]]; then
  for db in $DBS; do prune_keep "$BACKUP_DIR/predeploy/$db" "$KEEP_PREDEPLOY"; done
  info "predeploy : $KEEP_PREDEPLOY conservées par base"
else
  if [[ $FULL -eq 1 ]]; then names="$(cd "$BACKUP_DIR/daily" && find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"; else names="$DBS"; fi
  for n in $names; do
    promote_weekly "$BACKUP_DIR/daily/$n" "$BACKUP_DIR/weekly/$n"
    prune_keep "$BACKUP_DIR/daily/$n" "$KEEP_DAILY"
    prune_keep "$BACKUP_DIR/weekly/$n" "$KEEP_WEEKLY"
  done
  info "quotidiennes : $KEEP_DAILY | hebdomadaires : $KEEP_WEEKLY"
fi

[[ $FULL -ne 1 ]] || touch "$BACKUP_DIR/.last_success"

# --------------------------------------------------------------------------
if [[ $FULL -eq 1 && -n "${RCLONE_REMOTE:-}" ]]; then
  log "Copie hors VPS ($RCLONE_REMOTE)"
  command -v rclone > /dev/null || die "RCLONE_REMOTE est défini mais rclone n'est pas installé."
  remote_name="${RCLONE_REMOTE%%:*}"
  remotes="$(rclone listremotes --long)"
  if ! grep -Eq "^${remote_name}:[[:space:]]+crypt$" <<< "$remotes"; then
    die "Le remote '$remote_name' n'est pas de type 'crypt'. Refus d'envoyer des archives contenant des secrets en clair."
  fi
  rclone sync "$BACKUP_DIR" "$RCLONE_REMOTE" \
    --exclude '.lock' --exclude '.last_*' --exclude '*.part' --transfers 2 --stats-one-line -v
  touch "$BACKUP_DIR/.last_offsite_success"
  info "copie hors VPS terminée"
fi

log "Terminé"
info "Espace utilisé par $BACKUP_DIR : $(du -sh "$BACKUP_DIR" | cut -f1)"
