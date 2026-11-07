#!/usr/bin/env bash
#
# deploy.sh — déploie (ou met à jour) l'API d'un projet, avec retour arrière automatique.
#
# Usage : deploy.sh <projet> [--migrate] [--no-pull]
#   --migrate   applique les migrations Drizzle (node dist/db/migrate.js) AVANT de basculer.
#   --no-pull   ne fait pas de git pull (code déjà copié dans app/, ex : rsync).
#
# Déroulé :
#   1. git pull --ff-only dans /srv/projects/<projet>/app (si c'est un dépôt git ; refuse un arbre modifié)
#   2. sauvegarde de sécurité de la base du projet (dossier predeploy)
#   3. construction de l'image  <projet>-api:<sha git>  (ou horodatage si pas de git)
#   4. [--migrate] migrations avec la NOUVELLE image ; en cas d'échec, l'ancienne version reste en ligne
#   5. bascule (docker compose up -d --no-build) puis attente du healthcheck (90 s)
#   6. si la nouvelle version n'est pas saine : retour automatique à la version précédente
# Les 4 dernières images sont conservées pour permettre scripts/rollback.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

NAME="${1:-}"; [[ -n "$NAME" && "$NAME" != -* ]] || usage
shift
MIGRATE=0; PULL=1
while (($#)); do
  case "$1" in
    --migrate) MIGRATE=1; shift ;;
    --no-pull) PULL=0; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

valid_project_name "$NAME" || die "Nom de projet invalide : '$NAME'."
require_not_root
require_docker

PROJECT_DIR="$PROJECTS_DIR/$NAME"
APP_DIR="$PROJECT_DIR/app"
STATE_DIR="$PROJECT_DIR/.deploy"
CONTAINER="$NAME-api"
REPO_IMAGE="$NAME-api"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Projet '$NAME' introuvable ($PROJECT_DIR/docker-compose.yml)."
[[ -f "$APP_DIR/Dockerfile" ]]             || die "Pas de Dockerfile dans $APP_DIR."
install -d -m 700 "$STATE_DIR"

exec 8>"$STATE_DIR/lock"
flock -n 8 || die "Un déploiement de '$NAME' est déjà en cours."

# --------------------------------------------------------------------------
log "Code source"
if [[ -d "$APP_DIR/.git" && $PULL -eq 1 ]]; then
  [[ -z "$(git -C "$APP_DIR" status --porcelain)" ]] || die "Modifications locales non commitées dans $APP_DIR : refus de déployer."
  git -C "$APP_DIR" pull --ff-only
  TAG="$(git -C "$APP_DIR" rev-parse --short=12 HEAD)"
  info "commit déployé : $TAG ($(git -C "$APP_DIR" log -1 --format=%s))"
elif [[ -d "$APP_DIR/.git" ]]; then
  TAG="$(git -C "$APP_DIR" rev-parse --short=12 HEAD)"
  info "--no-pull : commit courant $TAG"
else
  TAG="manual-$(date -u +%Y%m%d%H%M%S)"
  info "app/ n'est pas un dépôt git : déploiement manuel, tag $TAG"
fi
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "Tag d'image invalide."

PREV="$(current_tag "$NAME")"
info "version en ligne : ${PREV:-aucune}"

# --------------------------------------------------------------------------
log "Sauvegarde de sécurité de la base $NAME"
"$SCRIPT_DIR/backup.sh" --db "$NAME" --kind predeploy

# --------------------------------------------------------------------------
log "Construction de l'image $REPO_IMAGE:$TAG"
pcompose "$NAME" "$TAG" build

if [[ $MIGRATE -eq 1 ]]; then
  log "Migrations (nouvelle image, ancienne version toujours en ligne)"
  pcompose "$NAME" "$TAG" run --rm --no-deps api node dist/db/migrate.js \
    || die "Migration échouée : rien n'a été basculé, la version $PREV reste en ligne. Sauvegarde de sécurité : $BACKUP_DIR/predeploy/$NAME/"
fi

# --------------------------------------------------------------------------
log "Bascule vers $TAG"
pcompose "$NAME" "$TAG" up -d --no-build
if wait_healthy "$CONTAINER" 90; then
  info "$CONTAINER est en bonne santé"
else
  warn "La version $TAG n'est pas devenue saine. Logs récents :"
  docker logs --tail 20 "$CONTAINER" >&2 || true
  if [[ -n "$PREV" && "$PREV" != "$TAG" ]] && docker image inspect "$REPO_IMAGE:$PREV" > /dev/null 2>&1; then
    warn "Retour automatique à la version $PREV..."
    pcompose "$NAME" "$PREV" up -d --no-build
    if wait_healthy "$CONTAINER" 90; then
      alert "Déploiement de $NAME annulé" "La version $TAG de $NAME n'a pas passé le healthcheck : retour automatique à $PREV (service rétabli).
Les migrations éventuelles restent appliquées : voir docs/operations.md."
      die "Déploiement de $TAG annulé, $PREV rétablie."
    fi
  fi
  alert "Déploiement de $NAME EN ÉCHEC" "La version $TAG de $NAME n'est pas saine et aucun retour arrière n'a pu être fait. Intervention nécessaire."
  die "Déploiement échoué et service non rétabli : docker logs $CONTAINER"
fi

if [[ -n "$PREV" && "$PREV" != "$TAG" ]]; then printf '%s' "$PREV" > "$STATE_DIR/previous"; fi

# --------------------------------------------------------------------------
log "Nettoyage des anciennes images (4 conservées)"
KEEP_TAGS=" $TAG ${PREV:-} $(cat "$STATE_DIR/previous" 2>/dev/null || true) "
n=0
while IFS= read -r t; do   # du plus récent au plus ancien
  [[ -n "$t" && "$t" != "<none>" ]] || continue
  n=$((n + 1))
  if [[ $n -gt 4 && "$KEEP_TAGS" != *" $t "* ]]; then
    docker rmi "$REPO_IMAGE:$t" > /dev/null 2>&1 && info "supprimée : $REPO_IMAGE:$t" || true
  fi
done < <(docker image ls "$REPO_IMAGE" --format '{{.Tag}}')
docker image prune -f > /dev/null 2>&1 || true

log "Déploiement terminé : $NAME $TAG"
info "Retour arrière si besoin : scripts/rollback.sh $NAME"
