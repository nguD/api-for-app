#!/usr/bin/env bash
#
# bunny-setup.sh <projet> [--check]
#
# Configure Bunny.net pour un projet (photos privées) SANS que les clés quittent le serveur :
#   - sans option : te demande les 5 valeurs (les clés sont saisies en silence, rien ne s'affiche), les écrit dans
#     /srv/projects/<projet>/.env (permissions 600, sauvegarde de l'ancien fichier), puis lance la vérification ;
#   - --check : relit le .env et vérifie VRAIMENT Bunny de bout en bout (écriture dans la Storage Zone, lecture par
#     le CDN avec jeton, refus sans jeton, refus avec jeton falsifié, suppression), puis nettoie.
#
# Aucune clé n'est affichée, journalisée, passée en argument de commande (invisible dans `ps`) ni stockée ailleurs que
# dans le .env du projet. La sortie ne contient que des PASS/FAIL : elle peut être collée dans un chat.
# Les fichiers de test sont écrits dans _healthcheck/ de la zone, hors de users/ : aucune donnée utilisateur touchée.
#
set -uo pipefail

NAME="${1:-}"
MODE="${2:-set}"
[[ "$NAME" =~ ^[a-z][a-z0-9]{1,19}$ ]] || { echo "Usage : $0 <projet> [--check]" >&2; exit 1; }
[[ "$MODE" == "set" || "$MODE" == "--check" ]] || { echo "Usage : $0 <projet> [--check]" >&2; exit 1; }

PROJECTS_DIR="${PROJECTS_DIR:-/srv/projects}"
ENV_FILE="$PROJECTS_DIR/$NAME/.env"
[[ -f "$ENV_FILE" ]] || { echo "Fichier introuvable : $ENV_FILE (le projet existe-t-il ?)" >&2; exit 1; }
[[ -w "$ENV_FILE" ]] || { echo "Fichier non modifiable par '$(id -un)' : $ENV_FILE" >&2; exit 1; }

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok() { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# Caractères refusés dans une valeur du .env (guillemets, espaces, $, #, antislash...) : docker compose les interpréterait.
SAFE_VALUE_RE='^[A-Za-z0-9._:/+=@-]+$'

# ---------------------------------------------------------------------------------------------------------------
# Écriture du .env
# ---------------------------------------------------------------------------------------------------------------
do_set() {
  log "Saisie de la configuration Bunny pour « $NAME »"
  cat <<'TXT'
Où trouver les valeurs dans le tableau de bord Bunny (https://dash.bunny.net) :
  1. Storage > ta zone > « FTP & API Access » : nom de la zone, nom d'hôte (région) et « Password »
     (c'est la clé d'écriture de la zone, PAS le mot de passe de ton compte Bunny).
  2. Delivery > ta Pull Zone (liée à la zone de stockage) > « Security » > « Token Authentication » :
     ACTIVE-la, copie la clé (« Security Key »). Le nom d'hôte de la Pull Zone figure dans « General » (…b-cdn.net).
Les clés se tapent en silence (rien ne s'affiche) ; tu peux les coller avec Cmd+V puis Entrée.
TXT
  local zone host cdn access token

  read -r -p "Nom de la Storage Zone : " zone
  [[ "$zone" =~ ^[a-z0-9-]{1,64}$ ]] || die "Nom de zone invalide (minuscules, chiffres, tirets)."

  read -r -p "Hôte de stockage [storage.bunnycdn.com] : " host
  host="${host:-storage.bunnycdn.com}"
  [[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$host" == *.* ]] || die "Hôte invalide (sans https://, sans /)."

  read -r -p "Nom d'hôte de la Pull Zone (ex. monzone.b-cdn.net, sans https://) : " cdn
  [[ "$cdn" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$cdn" == *.* ]] || die "Nom d'hôte invalide (sans https://, sans /)."

  read -r -s -p "Password de la Storage Zone (clé d'écriture, saisie masquée) : " access; echo
  [[ ${#access} -ge 8 && "$access" =~ $SAFE_VALUE_RE ]] || die "Clé de stockage invalide (8 caractères minimum, sans espace ni guillemet)."

  read -r -s -p "Clé de Token Authentication de la Pull Zone (saisie masquée) : " token; echo
  [[ ${#token} -ge 8 && "$token" =~ $SAFE_VALUE_RE ]] || die "Clé de Token Authentication invalide (8 caractères minimum, sans espace ni guillemet)."

  [[ "$access" != "$token" ]] || warn_same=1
  [[ -z "${warn_same:-}" ]] || echo "  (attention : les deux clés sont identiques, vérifie que tu n'as pas collé deux fois la même)"

  local tmp backup
  backup="$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  umask 077
  cp -p "$ENV_FILE" "$backup" && chmod 600 "$backup"
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  # Retire d'anciennes lignes BUNNY_*, garde tout le reste tel quel, puis ajoute le bloc.
  { grep -v '^BUNNY_' "$ENV_FILE" || true; } > "$tmp"
  [[ -s "$tmp" && "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]] && printf '\n' >> "$tmp"
  {
    printf 'BUNNY_STORAGE_ZONE=%s\n' "$zone"
    printf 'BUNNY_STORAGE_HOST=%s\n' "$host"
    printf 'BUNNY_STORAGE_ACCESS_KEY=%s\n' "$access"
    printf 'BUNNY_CDN_HOSTNAME=%s\n' "$cdn"
    printf 'BUNNY_TOKEN_AUTH_KEY=%s\n' "$token"
  } >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
  unset access token

  echo "  .env mis à jour (5 variables BUNNY_*), permissions $(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")."
  echo "  Ancienne version conservée : $(basename "$backup") (même dossier, permissions 600)."
}

# ---------------------------------------------------------------------------------------------------------------
# Vérification de bout en bout
# ---------------------------------------------------------------------------------------------------------------
env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1; }

b64url_sha256() { # le jeton Bunny : base64url(SHA256(clé + chemin + expiration)), sans « = »
  printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

do_check() {
  log "Vérification de Bunny pour « $NAME » (rien n'est affiché de secret)"
  local zone host cdn access token
  zone="$(env_get BUNNY_STORAGE_ZONE)"; host="$(env_get BUNNY_STORAGE_HOST)"; cdn="$(env_get BUNNY_CDN_HOSTNAME)"
  access="$(env_get BUNNY_STORAGE_ACCESS_KEY)"; token="$(env_get BUNNY_TOKEN_AUTH_KEY)"
  local v missing=()
  for v in zone host cdn access token; do [[ -n "${!v}" ]] || missing+=("$v"); done
  if ((${#missing[@]} > 0)); then ko "variables BUNNY_* manquantes dans le .env (${missing[*]}) : lance d'abord $0 $NAME"; return; fi
  ok "les 5 variables BUNNY_* sont présentes (permissions $(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE"))"
  [[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")" == "600" ]] || ko "le .env n'est pas en 600"

  local file path code i expires sig url
  file="$(mktemp)"; trap 'rm -f "$file"' RETURN
  printf 'tenue healthcheck %s\n' "$(date -u +%FT%TZ)" > "$file"
  path="_healthcheck/probe-$(date +%s).txt"

  # 1. Écriture dans la Storage Zone (la clé passe par stdin, jamais par la ligne de commande).
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -K - 2>/dev/null <<EOF || true
request = "PUT"
url = "https://$host/$zone/$path"
header = "AccessKey: $access"
header = "Content-Type: application/octet-stream"
upload-file = "$file"
EOF
)"
  case "$code" in
    200|201) ok "écriture dans la Storage Zone ($code)" ;;
    401|403) ko "écriture refusée ($code) : « Password » de la zone ou nom de zone/hôte incorrect"; return ;;
    000)     ko "hôte de stockage injoignable : vérifie BUNNY_STORAGE_HOST"; return ;;
    *)       ko "écriture -> HTTP $code"; return ;;
  esac

  # 2. Lecture par le CDN avec un jeton valide (la propagation peut prendre quelques secondes).
  expires=$(( $(date +%s) + 600 ))
  sig="$(b64url_sha256 "$token/$path$expires")"
  url="https://$cdn/$path"
  code=000
  for i in 1 2 3 4 5 6; do
    code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$url?token=$sig&expires=$expires" 2>/dev/null || true)"
    [[ "$code" == "200" ]] && break
    sleep 3
  done
  if [[ "$code" == "200" ]]; then ok "lecture par le CDN avec jeton valide (200)"
  else ko "lecture par le CDN avec jeton -> $code : la Pull Zone est-elle liée à la Storage Zone ? la clé Token Authentication est-elle la bonne ? (Bunny signe : clé + /chemin + expiration, SHA-256)"; fi

  # 3. Refus sans jeton, avec jeton falsifié, avec jeton expiré.
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  [[ "$code" == "401" || "$code" == "403" ]] && ok "sans jeton : refusé ($code)" \
    || ko "sans jeton -> $code : les images seraient PUBLIQUES, active « Token Authentication » sur la Pull Zone"
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$url?token=${sig}x&expires=$expires" 2>/dev/null || true)"
  [[ "$code" == "401" || "$code" == "403" ]] && ok "jeton falsifié : refusé ($code)" || ko "jeton falsifié -> $code"
  local past=$(( $(date +%s) - 60 ))
  sig="$(b64url_sha256 "$token/$path$past")"
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$url?token=$sig&expires=$past" 2>/dev/null || true)"
  [[ "$code" == "401" || "$code" == "403" ]] && ok "jeton expiré : refusé ($code)" || ko "jeton expiré -> $code"

  # 4. Nettoyage.
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -K - 2>/dev/null <<EOF || true
request = "DELETE"
url = "https://$host/$zone/$path"
header = "AccessKey: $access"
EOF
)"
  [[ "$code" == "200" ]] && ok "suppression du fichier de test (200)" || ko "suppression -> HTTP $code (fichier $path à supprimer à la main dans Bunny)"
  unset access token
}

[[ "$MODE" == "set" ]] && do_set
do_check

printf '\nRésultat : %d PASS, %d FAIL\n' "$PASS" "$FAIL"
if ((FAIL == 0)); then
  echo "Bunny est prêt. Il reste à déployer l'API v2 (scripts/deploy.sh $NAME --migrate), sur feu vert."
else
  echo "Corrige le point en FAIL puis relance : $0 $NAME --check  (ou sans option pour ressaisir les valeurs)."
fi
((FAIL == 0))
