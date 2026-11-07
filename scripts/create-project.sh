#!/usr/bin/env bash
#
# create-project.sh <nom> [--domain api.<nom>.<domaine>] [--port 3000] [--show-password]
#
# Crée tout ce qu'il faut pour héberger une nouvelle API, isolée des autres :
#   - réseau Docker dédié (sous-réseau fixe) auquel Caddy et Postgres sont rattachés
#   - base Postgres + utilisateur dédié (pas superuser, REVOKE sur public)
#   - règle pg_hba limitée à cet utilisateur, cette base, ce sous-réseau
#   - dossier /srv/projects/<nom> : docker-compose.yml, .env (600), secrets/ (700)
#   - bloc Caddy (reverse proxy HTTPS)
#
# À lancer sur le VPS, en tant que 'deploy' (pas root). Si une étape échoue, ce
# qui vient d'être créé est annulé. Le mot de passe est écrit dans le .env du projet
# (600, jamais dans git) et n'est affiché que si --show-password est passé.
#
set -Eeuo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage : $0 <nom> [--domain api.<nom>.<domaine>] [--port 3000] [--show-password]
  <nom>  minuscules et chiffres, commence par une lettre, 2 à 20 caractères (ex : tenue)
EOF
  exit 1
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
NAME="${1:-}"; [[ -n "$NAME" && "$NAME" != -* ]] || usage
shift
DOMAIN=""; PORT="3000"; SHOW_PASSWORD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        DOMAIN="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --show-password) SHOW_PASSWORD=1; shift ;;
    *) usage ;;
  esac
done

[[ "$NAME" =~ ^[a-z][a-z0-9]{1,19}$ ]] || die "Nom invalide : minuscules et chiffres uniquement, commence par une lettre (2 à 20 caractères)."
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "Port invalide."
case "$NAME" in
  postgres|template0|template1|infra|caddy|dbadmin|admin|root|public) die "Nom réservé : '$NAME'." ;;
esac
[[ $EUID -ne 0 ]] || die "Lance ce script en tant que 'deploy', pas en root."

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$REPO_DIR/infra"
PROJECTS_DIR="${PROJECTS_DIR:-/srv/projects}"
PROJECT_DIR="$PROJECTS_DIR/$NAME"
DB="$NAME"
ROLE="${NAME}_app"
NETWORK="net_${NAME}"
HBA_FILE="$INFRA_DIR/postgres/hba.d/${NAME}.conf"
CADDY_FILE="$INFRA_DIR/caddy/sites/${NAME}.caddy"
NETWORKS_FILE="$INFRA_DIR/compose.networks.yml"

pg_admin() { docker exec -i postgres psql -X -q -U dbadmin -d postgres -v ON_ERROR_STOP=1 "$@"; }
caddy_exec() { ( cd "$INFRA_DIR" && docker compose exec -T "$@" ); }

# --------------------------------------------------------------------------
# Annulation en cas d'échec
# --------------------------------------------------------------------------
CREATED=()
CADDY_BACKUP=""
ARMED=0   # passe à 1 quand on commence à modifier le serveur
did() { [[ " ${CREATED[*]:-} " == *" $1 "* ]]; }

# Appelé à CHAQUE sortie du script (erreur, die, Ctrl+C) : annule si on était armé.
on_exit() {
  local code=$?
  trap - EXIT
  if [[ $code -eq 0 || $ARMED -ne 1 ]]; then exit "$code"; fi
  rollback "$code"
  exit "$code"
}
trap on_exit EXIT

rollback() {
  local code="$1"
  warn "Échec (code $code). Annulation de ce qui vient d'être créé..."
  if did caddy; then
    if [[ -n "$CADDY_BACKUP" && -f "$CADDY_BACKUP" ]]; then cp -a "$CADDY_BACKUP" "$CADDY_FILE"; else rm -f "$CADDY_FILE"; fi
    caddy_exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  fi
  if did dir; then rm -rf "$PROJECT_DIR"; fi
  if did hba; then
    rm -f "$HBA_FILE"
    pg_admin -c "select pg_reload_conf()" >/dev/null 2>&1 || true
  fi
  if did networkfile; then regenerate_networks_file || true; fi
  if did connected; then
    docker network disconnect "$NETWORK" postgres >/dev/null 2>&1 || true
    docker network disconnect "$NETWORK" caddy >/dev/null 2>&1 || true
  fi
  if did db; then
    pg_admin -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 || true
    pg_admin -c "DROP ROLE IF EXISTS \"$ROLE\"" >/dev/null 2>&1 || true
  fi
  if did network; then docker network rm "$NETWORK" >/dev/null 2>&1 || true; fi
  [[ -z "$CADDY_BACKUP" ]] || rm -f "$CADDY_BACKUP"
  warn "Création de '$NAME' annulée. Corrige le problème puis relance."
}

# --------------------------------------------------------------------------
# Fonctions
# --------------------------------------------------------------------------
regenerate_networks_file() {
  local f p projects=()
  for f in "$INFRA_DIR"/postgres/hba.d/*.conf; do
    [[ -e "$f" ]] || continue
    p="$(basename "$f" .conf)"
    projects+=("$p")
  done
  {
    echo "# GÉNÉRÉ par scripts/create-project.sh — ne pas éditer à la main"
    if ((${#projects[@]} == 0)); then
      echo "services: {}"
    else
      echo "services:"
      echo "  caddy:"
      echo "    networks:"
      for p in "${projects[@]}"; do echo "      net_$p: {}"; done
      echo "  postgres:"
      echo "    networks:"
      for p in "${projects[@]}"; do echo "      net_$p: {}"; done
      echo "networks:"
      for p in "${projects[@]}"; do
        echo "  net_$p:"
        echo "    external: true"
        echo "    name: net_$p"
      done
    fi
  } > "$NETWORKS_FILE"
}

pick_subnet() {
  local routes docker_nets hba n
  routes="$(ip -4 route show 2>/dev/null || true)"
  docker_nets="$(docker network ls -q | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
  hba="$(cat "$INFRA_DIR"/postgres/hba.d/*.conf 2>/dev/null || true)"
  for n in $(seq 1 254); do
    if [[ "$routes" != *"10.77.$n.0/24"* && "$docker_nets" != *"10.77.$n.0/24"* && "$hba" != *"10.77.$n.0/24"* ]]; then
      echo "10.77.$n.0/24"; return 0
    fi
  done
  die "Plus de sous-réseau libre dans 10.77.0.0/16."
}

render() { # render <template> : remplace les @@VARIABLES@@
  sed -e "s|@@PROJECT@@|$NAME|g" \
      -e "s|@@DOMAIN@@|$DOMAIN|g" \
      -e "s|@@PORT@@|$PORT|g" \
      -e "s|@@UID@@|$(id -u)|g" \
      -e "s|@@GID@@|$(id -g)|g" \
      "$1"
}

# --------------------------------------------------------------------------
# Pré-vérifications
# --------------------------------------------------------------------------
log "Vérifications préalables"
command -v docker  >/dev/null || die "Docker introuvable."
command -v openssl >/dev/null || die "openssl introuvable."
docker info >/dev/null 2>&1   || die "Docker inaccessible pour $(id -un)."
[[ -f "$INFRA_DIR/.env" ]]    || die "infra/.env absent : lance d'abord scripts/init-infra.sh."

health="$(docker inspect -f '{{.State.Health.Status}}' postgres 2>/dev/null || true)"
[[ "$health" == "healthy" ]] || die "Le conteneur postgres n'est pas 'healthy' (état : '${health:-absent}')."
caddy_state="$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null || true)"
[[ "$caddy_state" == "true" ]] || die "Le conteneur caddy ne tourne pas."

if [[ -z "$DOMAIN" ]]; then
  BASE_DOMAIN="$(sed -n 's/^BASE_DOMAIN=//p' "$INFRA_DIR/.env" | tail -n 1)"
  if [[ -z "$BASE_DOMAIN" ]]; then
    read -r -p "Domaine de base (ex : ahua.fr) : " BASE_DOMAIN
    [[ "$BASE_DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "Domaine invalide."
    printf 'BASE_DOMAIN=%s\n' "$BASE_DOMAIN" >> "$INFRA_DIR/.env"
    info "BASE_DOMAIN enregistré dans infra/.env"
  fi
  DOMAIN="api.${NAME}.${BASE_DOMAIN}"
fi
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || die "Domaine invalide : '$DOMAIN'."

[[ ! -e "$PROJECT_DIR" ]] || die "$PROJECT_DIR existe déjà."
[[ -z "$(pg_admin -At -c "select 1 from pg_roles where rolname='$ROLE'")" ]]    || die "Le rôle Postgres '$ROLE' existe déjà."
[[ -z "$(pg_admin -At -c "select 1 from pg_database where datname='$DB'")" ]]   || die "La base '$DB' existe déjà."
[[ -z "$(docker network ls -q --filter "name=^${NETWORK}\$")" ]]                || die "Le réseau Docker '$NETWORK' existe déjà."
[[ ! -e "$HBA_FILE" ]] || die "$HBA_FILE existe déjà."
if [[ -f "$CADDY_FILE" ]]; then
  placeholder="$(grep -c 'caddy-ok' "$CADDY_FILE" || true)"
  [[ "$placeholder" -gt 0 ]] || die "$CADDY_FILE existe déjà et n'est pas le site provisoire de test."
fi

info "Projet   : $NAME"
info "Base     : $DB   | Utilisateur : $ROLE"
info "Réseau   : $NETWORK"
info "Domaine  : $DOMAIN  → conteneur ${NAME}-api:${PORT}"

ARMED=1

# --------------------------------------------------------------------------
# Réseau Docker dédié, sous-réseau fixe
# --------------------------------------------------------------------------
log "Réseau Docker dédié"
SUBNET="$(pick_subnet)"
docker network create --driver bridge --subnet "$SUBNET" --label "platform.project=$NAME" "$NETWORK" >/dev/null
CREATED+=(network)
info "$NETWORK créé ($SUBNET)"

# --------------------------------------------------------------------------
# Base + utilisateur Postgres isolés
# --------------------------------------------------------------------------
log "Base et utilisateur Postgres"
PW="$(openssl rand -hex 24)"
CREATED+=(db)   # avant le SQL : si CREATE DATABASE échoue, le rôle déjà créé sera supprimé aussi
{
  printf "\\\\set pw '%s'\n" "$PW"
  cat <<'SQL'
CREATE ROLE :"role" LOGIN PASSWORD :'pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 15;
CREATE DATABASE :"db" OWNER :"role" TEMPLATE template0 ENCODING 'UTF8';
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
\connect :db
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL
} | pg_admin -v role="$ROLE" -v db="$DB"
info "rôle $ROLE (sans droits d'admin) et base $DB créés, accès PUBLIC révoqué"

# --------------------------------------------------------------------------
# pg_hba : cet utilisateur, cette base, ce sous-réseau, rien d'autre
# --------------------------------------------------------------------------
log "Règle d'accès pg_hba"
cat > "$HBA_FILE" <<EOF
# Projet $NAME — généré par create-project.sh (aucun secret ici)
host  $DB  $ROLE  $SUBNET  scram-sha-256
EOF
chmod 644 "$HBA_FILE"
CREATED+=(hba)
pg_admin -At -c "select pg_reload_conf()" >/dev/null
sleep 1
hba_errors="$(pg_admin -At -c "select count(*) from pg_hba_file_rules where error is not null")"
[[ "$hba_errors" == "0" ]] || die "pg_hba.conf invalide après ajout ($hba_errors erreur(s))."
info "$HBA_FILE appliqué"

# --------------------------------------------------------------------------
# Rattacher Postgres et Caddy au réseau du projet (sans redémarrage)
# --------------------------------------------------------------------------
log "Rattachement de Postgres et Caddy à $NETWORK"
docker network connect --alias postgres "$NETWORK" postgres >/dev/null
CREATED+=(connected)
docker network connect "$NETWORK" caddy >/dev/null
CREATED+=(networkfile)
regenerate_networks_file
( cd "$INFRA_DIR" && docker compose config -q ) || die "compose.networks.yml invalide."
info "compose.networks.yml mis à jour (persistance après redémarrage)"

# --------------------------------------------------------------------------
# Dossier projet
# --------------------------------------------------------------------------
log "Dossier $PROJECT_DIR"
install -d -m 755 "$PROJECT_DIR"
CREATED+=(dir)
install -d -m 700 "$PROJECT_DIR/secrets"
render "$INFRA_DIR/templates/project-compose.yml" > "$PROJECT_DIR/docker-compose.yml"
(
  umask 077
  {
    echo "# Projet $NAME — généré par create-project.sh."
    echo "# FICHIER SECRET (permissions 600) : ne jamais le commiter ni le coller dans un chat."
    echo "NODE_ENV=production"
    echo "PORT=$PORT"
    echo "LOG_LEVEL=info"
    echo "DATABASE_URL=postgres://${ROLE}:${PW}@postgres:5432/${DB}"
    echo "# Variables propres au projet : voir le .env.example du dépôt de l'API."
  } > "$PROJECT_DIR/.env"
)
chmod 600 "$PROJECT_DIR/.env"
info "docker-compose.yml, .env (600), secrets/ (700)"

# --------------------------------------------------------------------------
# Bloc Caddy
# --------------------------------------------------------------------------
log "Bloc Caddy pour $DOMAIN"
if [[ -f "$CADDY_FILE" ]]; then
  CADDY_BACKUP="$(mktemp)"
  cp -a "$CADDY_FILE" "$CADDY_BACKUP"
fi
render "$INFRA_DIR/templates/caddy-site.caddy.tmpl" > "$CADDY_FILE"
CREATED+=(caddy)
caddy_exec caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || die "Configuration Caddy invalide (restaurée)."
caddy_exec -w /etc/caddy caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || die "Rechargement de Caddy impossible (restauré)."
[[ -z "$CADDY_BACKUP" ]] || rm -f "$CADDY_BACKUP"
info "$CADDY_FILE appliqué"

ARMED=0   # tout est en place : on ne défait plus rien automatiquement

# --------------------------------------------------------------------------
# Auto-test d'isolation
# --------------------------------------------------------------------------
log "Test d'isolation"
if "$REPO_DIR/scripts/check-project.sh" "$NAME"; then
  checks_ok=1
else
  checks_ok=0
  warn "Des contrôles d'isolation ont échoué : voir ci-dessus. Le projet est créé mais NE PAS l'utiliser avant correction."
fi

cat <<EOF

────────────────────────────────────────────────────────────
Projet '$NAME' créé.

  Domaine        : https://$DOMAIN  (enregistrement DNS A requis vers ce serveur)
  Dossier        : $PROJECT_DIR
  Base / rôle    : $DB / $ROLE   (réseau $NETWORK, $SUBNET)
  Conteneur API  : ${NAME}-api  (écoute $PORT, pas encore démarré)

  Prochaines étapes :
    1. cd $PROJECT_DIR && git clone <url-du-depot-api> app
    2. compléter $PROJECT_DIR/.env (variables propres au projet)
    3. déposer les fichiers secrets éventuels dans $PROJECT_DIR/secrets/
    4. docker compose up -d --build
EOF
if [[ "$SHOW_PASSWORD" -eq 1 ]]; then
  cat <<EOF

  Mot de passe Postgres de $ROLE (affiché UNE SEULE FOIS, ne le colle nulle part) :
    $PW
  Il est aussi dans $PROJECT_DIR/.env (600), car l'API en a besoin.
EOF
else
  cat <<EOF

  Mot de passe Postgres : écrit dans $PROJECT_DIR/.env (600), non affiché.
  (relance avec --show-password sur un nouveau projet pour l'afficher une fois.)
EOF
fi
echo "────────────────────────────────────────────────────────────"

[[ "$checks_ok" -eq 1 ]]
