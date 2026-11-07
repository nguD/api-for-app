#!/usr/bin/env bash
#
# check-project.sh <nom> — vérifie l'isolation Postgres d'un projet.
#
# Depuis un conteneur jetable placé sur le réseau du projet, avec les identifiants
# lus dans /srv/projects/<nom>/.env (jamais affichés), contrôle que :
#   - le rôle accède à SA base et peut y créer des tables
#   - le rôle n'est ni superuser, ni createdb, ni createrole, ni replication
#   - le rôle est REFUSÉ sur toutes les autres bases (postgres, template1, autres projets)
#   - le superutilisateur (dbadmin) est REFUSÉ par le réseau
#   - un mauvais mot de passe est refusé
# Lecture seule (sauf une table temporaire créée puis supprimée dans la base du projet).
#
set -uo pipefail

NAME="${1:-}"
[[ "$NAME" =~ ^[a-z][a-z0-9]{1,19}$ ]] || { echo "Usage : $0 <nom>" >&2; exit 1; }

PROJECTS_DIR="${PROJECTS_DIR:-/srv/projects}"
ENV_FILE="$PROJECTS_DIR/$NAME/.env"
NETWORK="net_${NAME}"

PASS=0; FAIL=0
ok() { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

[[ -r "$ENV_FILE" ]] || { echo "Fichier illisible : $ENV_FILE" >&2; exit 1; }

URL="$(sed -n 's/^DATABASE_URL=//p' "$ENV_FILE" | tail -n 1)"
re='^postgres://([^:]+):([^@]+)@postgres:5432/([a-z0-9_]+)$'
[[ "$URL" =~ $re ]] || { echo "DATABASE_URL illisible ou format inattendu dans $ENV_FILE" >&2; exit 1; }
ROLE="${BASH_REMATCH[1]}"; SECRET="${BASH_REMATCH[2]}"; DB="${BASH_REMATCH[3]}"
unset URL

PG_IMAGE="$(docker inspect -f '{{.Config.Image}}' postgres 2>/dev/null)"
[[ -n "$PG_IMAGE" ]] || { echo "Conteneur postgres introuvable." >&2; exit 1; }
docker network inspect "$NETWORK" >/dev/null 2>&1 || { echo "Réseau $NETWORK introuvable." >&2; exit 1; }

# client <user> <db> <password> <args psql...> : exécute psql depuis le réseau du projet.
# Le mot de passe passe par l'environnement (PGPASSWORD), jamais en argument de commande.
client() {
  local user="$1" db="$2" pw="$3"; shift 3
  PGPASSWORD="$pw" docker run --rm --network "$NETWORK" \
    -e PGPASSWORD -e PGCONNECT_TIMEOUT=5 \
    --memory 96m --cap-drop ALL --security-opt no-new-privileges:true --read-only \
    --entrypoint psql "$PG_IMAGE" \
    -X -w -At -q -h postgres -U "$user" -d "$db" -v ON_ERROR_STOP=1 "$@" 2>&1
}

first_line() { head -n 1 | cut -c1-110; }

echo "Projet $NAME : rôle $ROLE, base $DB, réseau $NETWORK"
echo
echo "Accès légitime"

out="$(client "$ROLE" "$DB" "$SECRET" -c "select current_user || '@' || current_database()")"
[[ "$out" == "${ROLE}@${DB}" ]] && ok "connexion à sa base ($out)" || ko "connexion à sa propre base impossible : $(first_line <<<"$out")"

out="$(client "$ROLE" "$DB" "$SECRET" -c "create table _isolation_probe(i int); drop table _isolation_probe;")"
[[ $? -eq 0 ]] && ok "peut créer/supprimer une table dans sa base" || ko "ne peut pas créer de table : $(first_line <<<"$out")"

out="$(client "$ROLE" "$DB" "$SECRET" -c "select rolsuper::text || rolcreatedb::text || rolcreaterole::text || rolreplication::text from pg_roles where rolname = current_user")"
[[ "$out" == "falsefalsefalsefalse" ]] && ok "rôle sans superuser/createdb/createrole/replication" || ko "attributs du rôle inattendus : $out"

echo
echo "Accès interdits (chaque refus est attendu)"

others="$(docker exec postgres psql -X -U dbadmin -d postgres -At -c "select datname from pg_database where datallowconn and datname <> '$DB' order by 1")"
for other in $others; do
  out="$(client "$ROLE" "$other" "$SECRET" -c "select 1")"
  if [[ $? -ne 0 ]]; then ok "refusé sur la base '$other' → $(first_line <<<"$out")"; else ko "ACCÈS POSSIBLE à la base '$other'"; fi
done

out="$(client dbadmin postgres "" -c "select 1")"
if [[ $? -ne 0 ]]; then ok "superutilisateur refusé par le réseau → $(first_line <<<"$out")"; else ko "le superutilisateur peut se connecter par le réseau"; fi

out="$(client "$ROLE" "$DB" "mauvais-mot-de-passe" -c "select 1")"
if [[ $? -ne 0 ]]; then ok "mauvais mot de passe refusé"; else ko "un mauvais mot de passe est accepté"; fi

unset SECRET
printf '\nRésultat : %d OK, %d FAIL\n' "$PASS" "$FAIL"
((FAIL == 0))
