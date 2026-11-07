#!/usr/bin/env bash
#
# restore.sh — test de restauration et restauration réelle d'une base de projet.
#
# Usage :
#   restore.sh --test [--db NOM] [--alert]
#       Restaure la dernière sauvegarde quotidienne de chaque base (ou de NOM) dans une base JETABLE
#       (restore_test_<nom>, mêmes propriétaire et droits que la vraie), compare le nombre de lignes
#       avec la base en production, puis supprime la base jetable. Ne touche JAMAIS aux bases réelles.
#       --alert : envoie un e-mail en cas d'échec (utilisé par le timer hebdomadaire).
#
#   restore.sh <nom> <fichier.dump> --apply
#       RESTAURATION RÉELLE : arrête l'API du projet, fait une sauvegarde de sécurité (predeploy),
#       SUPPRIME puis recrée la base <nom>, restaure le fichier, redémarre l'API.
#       Demande de retaper le nom de la base pour confirmer.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

MODE=""; ONLY_DB=""; ALERT=0; NAME=""; FILE=""
while (($#)); do
  case "$1" in
    --test)  MODE="test"; shift ;;
    --apply) MODE="apply"; shift ;;
    --db)    ONLY_DB="${2:-}"; shift 2 ;;
    --alert) ALERT=1; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) if [[ -z "$NAME" ]]; then NAME="$1"; elif [[ -z "$FILE" ]]; then FILE="$1"; else usage; fi; shift ;;
  esac
done
[[ -n "$MODE" ]] || usage

require_not_root
require_docker
[[ "$(docker inspect -f '{{.State.Running}}' postgres 2>/dev/null || true)" == "true" ]] || die "Le conteneur postgres ne tourne pas."

role_for() { # rôle propriétaire d'une base de projet : <base>_app (sinon dbadmin)
  if [[ "$(pg_admin -At -c "select 1 from pg_roles where rolname='${1}_app'")" == "1" ]]; then
    printf '%s_app' "$1"
  else
    printf 'dbadmin'
  fi
}

verify_sha() { # verify_sha <fichier>
  local f="$1"
  if [[ -f "$f.sha256" ]]; then
    ( cd "$(dirname "$f")" && sha256sum -c --quiet "$(basename "$f").sha256" ) || die "Somme de contrôle incorrecte : $f"
    info "somme de contrôle OK"
  else
    warn "Pas de fichier .sha256 à côté de $f : intégrité non vérifiée."
  fi
}

create_db() { # create_db <base> <rôle> : même création que scripts/create-project.sh
  {
    cat <<'SQL'
CREATE DATABASE :"db" OWNER :"role" TEMPLATE template0 ENCODING 'UTF8';
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
\connect :db
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL
  } | pg_admin -v db="$1" -v role="$2"
}

restore_into() { # restore_into <base> <rôle> <fichier> ; échoue avec le message de pg_restore
  local db="$1" role="$2" file="$3" err
  if ! err="$(docker exec -i postgres pg_restore -U dbadmin -d "$db" --no-owner --no-acl --role="$role" \
        --single-transaction --exit-on-error < "$file" 2>&1)"; then
    printf '%s\n' "$err" | head -n 15 >&2
    return 1
  fi
}

latest_dump() { # latest_dump <base>
  list_backups "$BACKUP_DIR/daily/$1" | grep -E '\.dump$' | tail -n 1 || true
}

# --------------------------------------------------------------------------
test_one() { # test_one <base> : retourne 0 si la restauration est valide
  local db="$1" scratch="restore_test_$1" role file t restored live total=0 rc=0
  file="$(latest_dump "$db")"
  [[ -n "$file" ]] || { warn "Aucune sauvegarde quotidienne pour '$db'."; return 1; }
  log "Test de restauration : $db"
  info "fichier : $file"
  verify_sha "$file"
  role="$(role_for "$db")"
  pg_admin -c "DROP DATABASE IF EXISTS \"$scratch\" WITH (FORCE)" > /dev/null
  create_db "$scratch" "$role"
  info "base jetable $scratch créée (propriétaire $role)"
  if restore_into "$scratch" "$role" "$file"; then
    info "pg_restore terminé sans erreur"
    printf '    %-28s %12s %12s\n' "table (schéma public)" "restauré" "production"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      restored="$(pg_db "$scratch" -At -c "select count(*) from public.\"$t\"")"
      live="$(pg_db "$db" -At -c "select count(*) from public.\"$t\"" 2>/dev/null || echo '?')"
      printf '    %-28s %12s %12s\n' "$t" "$restored" "$live"
      total=$((total + 1))
    done < <(pg_db "$scratch" -At -c "select tablename from pg_tables where schemaname='public' order by 1")
    if [[ $total -eq 0 ]]; then
      warn "Aucune table restaurée dans le schéma public : sauvegarde vide ou invalide."
      rc=1
    fi
  else
    warn "pg_restore a échoué pour '$db' (voir les messages ci-dessus)."
    rc=1
  fi
  pg_admin -c "DROP DATABASE IF EXISTS \"$scratch\" WITH (FORCE)" > /dev/null || warn "Suppression de $scratch impossible."
  info "base jetable supprimée"
  if [[ $rc -eq 0 ]]; then info "RÉSULTAT $db : OK ($total table(s) restaurée(s))"; else info "RÉSULTAT $db : ÉCHEC"; fi
  return $rc
}

if [[ "$MODE" == "test" ]]; then
  umask 077
  install -d -m 700 "$BACKUP_DIR"
  exec 9>"$BACKUP_DIR/.lock"
  flock -n 9 || die "Une sauvegarde ou un autre test est en cours."
  failed=0
  if [[ -n "$ONLY_DB" ]]; then dbs="$ONLY_DB"; else dbs="$(cd "$BACKUP_DIR/daily" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -type d ! -name '_*' -printf '%f\n' | sort || true)"; fi
  [[ -n "$dbs" ]] || { warn "Aucune sauvegarde trouvée dans $BACKUP_DIR/daily : lance d'abord scripts/backup.sh."; failed=1; }
  for db in $dbs; do test_one "$db" || failed=1; done
  if [[ $failed -ne 0 ]]; then
    [[ $ALERT -ne 1 ]] || alert "Test de restauration ÉCHOUÉ" "Le test de restauration automatique a échoué le $(date -u '+%F %T') UTC.
Relance à la main : scripts/restore.sh --test   (journal : journalctl -u platform-restoretest)."
    log "Test de restauration : ÉCHEC"
    exit 1
  fi
  log "Test de restauration : TOUT EST OK"
  exit 0
fi

# --------------------------------------------------------------------------
# Restauration réelle
# --------------------------------------------------------------------------
valid_project_name "$NAME" || die "Nom de projet invalide : '${NAME}'."
[[ -n "$FILE" && -f "$FILE" ]] || die "Fichier de sauvegarde introuvable : '${FILE}'. Usage : restore.sh <nom> <fichier.dump> --apply"
[[ -d "$PROJECTS_DIR/$NAME" ]] || die "Projet '$NAME' introuvable dans $PROJECTS_DIR."
ROLE="${NAME}_app"
[[ "$(pg_admin -At -c "select 1 from pg_roles where rolname='$ROLE'")" == "1" ]] || die "Rôle $ROLE introuvable."
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

cat <<EOF

  RESTAURATION RÉELLE
  Base           : $NAME  (propriétaire $ROLE)
  Fichier        : $FILE
  Conséquence    : la base $NAME actuelle sera SUPPRIMÉE puis remplacée par ce fichier.
                   L'API $NAME-api sera arrêtée pendant l'opération.
  Filet          : une sauvegarde de sécurité de l'état actuel est faite avant (dossier predeploy).

EOF
read -r -p "Tape le nom de la base ($NAME) pour confirmer : " CONFIRM
[[ "$CONFIRM" == "$NAME" ]] || die "Confirmation différente : abandon, rien n'a été modifié."

verify_sha "$FILE"

log "Sauvegarde de sécurité de l'état actuel"
"$SCRIPT_DIR/backup.sh" --db "$NAME" --kind predeploy

log "Arrêt de $NAME-api"
pcompose "$NAME" "$(current_tag "$NAME")" stop api

restore_failed() {
  local code=$?
  trap - EXIT
  if [[ $code -ne 0 ]]; then
    warn "Restauration INTERROMPUE (code $code). La base $NAME peut être vide ou partielle."
    warn "L'état d'avant est dans $BACKUP_DIR/predeploy/$NAME/ : relance restore.sh avec ce fichier pour revenir en arrière."
  fi
  exit "$code"
}
trap restore_failed EXIT

log "Recréation de la base $NAME"
pg_admin -c "DROP DATABASE IF EXISTS \"$NAME\" WITH (FORCE)"
create_db "$NAME" "$ROLE"

log "Restauration"
restore_into "$NAME" "$ROLE" "$FILE" || die "pg_restore a échoué."
trap - EXIT

log "Redémarrage de $NAME-api"
# 'up --no-build' (et non 'start') : fonctionne aussi si le conteneur n'a jamais été créé (nouveau serveur).
# L'image doit exister : tag en cours, ou 'local' (docker compose build) sur un serveur neuf.
pcompose "$NAME" "$(current_tag "$NAME")" up -d --no-build api
if wait_healthy "$NAME-api" 90; then
  info "$NAME-api est en bonne santé : restauration terminée."
else
  warn "$NAME-api n'est pas devenue saine : vérifie 'docker logs $NAME-api'."
  exit 1
fi
