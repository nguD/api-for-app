#!/usr/bin/env bash
#
# rollback.sh — revient à une version précédente de l'API d'un projet (image déjà construite localement).
#
# Usage : rollback.sh <projet> [tag]
#   sans tag : revient à la version précédente enregistrée par deploy.sh
#   --list   : (à la place du tag) affiche les versions disponibles
#
# ATTENTION : cela ne défait PAS les migrations de base de données. Voir docs/operations.md :
# écris tes migrations de façon rétro-compatible (ajouter avant de supprimer). Pour revenir à un état
# antérieur des données : scripts/restore.sh <projet> <dump> --apply.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

NAME="${1:-}"; [[ -n "$NAME" && "$NAME" != -* ]] || usage
TARGET="${2:-}"
valid_project_name "$NAME" || die "Nom de projet invalide : '$NAME'."
require_not_root
require_docker

PROJECT_DIR="$PROJECTS_DIR/$NAME"
STATE_DIR="$PROJECT_DIR/.deploy"
CONTAINER="$NAME-api"
REPO_IMAGE="$NAME-api"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Projet '$NAME' introuvable."

CUR="$(current_tag "$NAME")"

if [[ "$TARGET" == "--list" ]]; then
  echo "En ligne : ${CUR:-aucune}"
  echo "Versions disponibles (images locales) :"
  docker image ls "$REPO_IMAGE" --format '  {{.Tag}}   (créée {{.CreatedSince}})'
  exit 0
fi

if [[ -z "$TARGET" ]]; then
  [[ -f "$STATE_DIR/previous" ]] || die "Pas de version précédente enregistrée. Utilise : rollback.sh $NAME --list"
  TARGET="$(cat "$STATE_DIR/previous")"
fi
[[ "$TARGET" =~ ^[A-Za-z0-9._-]+$ ]] || die "Tag invalide."
docker image inspect "$REPO_IMAGE:$TARGET" > /dev/null 2>&1 || die "Image $REPO_IMAGE:$TARGET introuvable. Versions : rollback.sh $NAME --list"
[[ "$TARGET" != "$CUR" ]] || die "$TARGET est déjà la version en ligne."

log "Retour de $NAME : ${CUR:-?} → $TARGET"
pcompose "$NAME" "$TARGET" up -d --no-build
if wait_healthy "$CONTAINER" 90; then
  install -d -m 700 "$STATE_DIR"
  if [[ -n "$CUR" ]]; then printf '%s' "$CUR" > "$STATE_DIR/previous"; fi   # permet de ré-avancer
  info "$CONTAINER est en bonne santé sur la version $TARGET."
  info "Rappel : les migrations de base de données ne sont pas annulées."
else
  warn "La version $TARGET n'est pas saine : docker logs $CONTAINER"
  if [[ -n "$CUR" ]]; then
    warn "Retour à la version $CUR..."
    pcompose "$NAME" "$CUR" up -d --no-build
  fi
  exit 1
fi
