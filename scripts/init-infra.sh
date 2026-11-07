#!/usr/bin/env bash
#
# init-infra.sh — prépare le serveur pour la stack infra (Caddy + Postgres).
# À lancer UNE FOIS, en tant que 'deploy' (pas root), depuis le dépôt cloné.
# Idempotent. N'affiche et ne stocke aucun secret dans git.
#
set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Lance ce script en tant que 'deploy', pas en root."

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$REPO_DIR/infra"
ME="$(id -un)"
POSTGRES_UID=999   # utilisateur 'postgres' de l'image officielle

command -v docker >/dev/null || die "Docker introuvable."
docker info >/dev/null 2>&1   || die "Docker inaccessible pour '$ME' (groupe docker ? reconnecte-toi)."
command -v openssl >/dev/null || die "openssl introuvable."

log "Dossiers /srv/projects et /srv/backups"
sudo install -d -o "$ME" -g "$ME" -m 755 /srv/projects
sudo install -d -o "$ME" -g "$ME" -m 700 /srv/backups

log "Fichier infra/.env"
if [[ -f "$INFRA_DIR/.env" ]]; then
  info "existe déjà, non modifié"
else
  read -r -p "Email pour Let's Encrypt (alertes d'expiration) : " ACME_EMAIL
  [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Email invalide."
  sed "s|^ACME_EMAIL=.*|ACME_EMAIL=$ACME_EMAIL|" "$INFRA_DIR/.env.example" > "$INFRA_DIR/.env"
  chmod 600 "$INFRA_DIR/.env"
  info ".env créé (permissions 600)"
fi

log "Secret du superutilisateur Postgres (jamais affiché)"
SECRET="$INFRA_DIR/secrets/postgres_password"
install -d -m 700 "$INFRA_DIR/secrets"
if sudo test -f "$SECRET"; then
  info "existe déjà, non modifié"
else
  openssl rand -hex 24 | tr -d '\n' | sudo sh -c 'umask 077; cat > "$1"' _ "$SECRET"
  sudo chown "$POSTGRES_UID:$POSTGRES_UID" "$SECRET"
  sudo chmod 400 "$SECRET"
  info "créé : lisible uniquement par l'utilisateur postgres du conteneur (400)"
  info "NOTE : tu n'as pas besoin de le connaître. L'administration se fait via 'docker exec' (socket interne)."
fi

log "Fichiers générés vides (remplis plus tard par create-project.sh)"
if [[ ! -f "$INFRA_DIR/compose.networks.yml" ]]; then
  printf '# GÉNÉRÉ par scripts/create-project.sh — ne pas éditer à la main\nservices: {}\n' \
    > "$INFRA_DIR/compose.networks.yml"
  info "compose.networks.yml créé"
fi
mkdir -p "$INFRA_DIR/postgres/hba.d" "$INFRA_DIR/caddy/sites"

log "Validation de la configuration Docker Compose"
( cd "$INFRA_DIR" && docker compose config -q ) && info "docker compose config : OK"

cat <<EOF

────────────────────────────────────────────────────────────
Préparation terminée. Pour démarrer la stack :
  cd $INFRA_DIR
  docker compose pull
  docker compose up -d
  docker compose ps
────────────────────────────────────────────────────────────
EOF
