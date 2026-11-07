#!/usr/bin/env bash
#
# setup-alerts.sh — configure l'envoi des alertes par e-mail (msmtp + relais SMTP de ton choix).
# À lancer UNE FOIS sur le VPS, en tant que 'deploy'. Idempotent (peut être relancé pour changer).
#
# Le mot de passe SMTP est saisi ICI, sur le VPS (saisie masquée, jamais affichée ni journalisée) et
# écrit uniquement dans ~/.msmtprc (permissions 600). Ne le colle nulle part ailleurs.
#
# Où trouver un relais SMTP (au choix) :
#   - Boîte mail Gandi liée à ahua.fr :  serveur mail.gandi.net, port 587 (STARTTLS), utilisateur = adresse complète
#   - Gmail : smtp.gmail.com, port 587, mot de passe d'application (pas le mot de passe du compte)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_not_root

set_kv() { # set_kv <fichier> <clé> <valeur> : remplace ou ajoute CLÉ=valeur
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  [[ ! -f "$file" ]] || grep -v "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$file"
  rm -f "$tmp"
}

log "Installation de msmtp"
if command -v msmtp > /dev/null; then
  info "déjà installé"
else
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq msmtp ca-certificates
fi

log "Paramètres"
read -r -p "Adresse qui REÇOIT les alertes : " TO
read -r -p "Serveur SMTP (ex : mail.gandi.net) : " HOST
read -r -p "Port [587] : " PORT; PORT="${PORT:-587}"
read -r -p "Utilisateur SMTP (souvent l'adresse complète) : " USER_SMTP
read -r -p "Adresse d'expédition (From) [$USER_SMTP] : " FROM; FROM="${FROM:-$USER_SMTP}"
read -r -s -p "Mot de passe SMTP (saisie masquée) : " PASS; echo
mail_re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
[[ "$TO" =~ $mail_re && "$FROM" =~ $mail_re ]] || die "Adresse e-mail invalide."
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ && "$PORT" =~ ^[0-9]{2,5}$ ]] || die "Serveur ou port invalide."
[[ "$USER_SMTP" =~ ^[^[:space:]]+$ && -n "$PASS" ]] || die "Utilisateur ou mot de passe vide."

if [[ "$PORT" == "465" ]]; then STARTTLS="off"; else STARTTLS="on"; fi

log "Écriture de ~/.msmtprc (600)"
(
  umask 077
  cat > "$HOME/.msmtprc" <<EOF
# Généré par scripts/setup-alerts.sh — contient un mot de passe : ne pas partager.
defaults
auth           on
tls            on
tls_starttls   $STARTTLS
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        alerts
host           $HOST
port           $PORT
from           $FROM
user           $USER_SMTP
password       $PASS

account default : alerts
EOF
)
chmod 600 "$HOME/.msmtprc"
unset PASS

log "Enregistrement dans infra/.env.ops"
set_kv "$OPS_ENV" ALERT_EMAIL "$TO"
set_kv "$OPS_ENV" ALERT_FROM "$FROM"
export ALERT_EMAIL="$TO" ALERT_FROM="$FROM"

log "E-mail de test"
alert "Test d'alerte" "Si tu lis ce message, les alertes du serveur fonctionnent.
Envoyé par scripts/setup-alerts.sh le $(date '+%F %T')."
info "Vérifie ta boîte (et les spams) dans la minute qui suit."
info "Si rien n'arrive : 'tail -5 ~/.msmtp.log' (erreur SMTP, sans mot de passe) puis 'msmtp --serverinfo --account=alerts' (test TLS)."
