#!/usr/bin/env bash
#
# harden.sh — durcissement d'un VPS Ubuntu 26.04 LTS neuf (production).
#
# Deux phases, pour ne jamais se verrouiller dehors :
#   ./harden.sh install "<clé publique ssh-ed25519>"
#       Phase 1. Crée l'utilisateur sudo, installe la clé, configure ufw,
#       fail2ban, mises à jour auto, swap, sysctl, rotation des logs Docker.
#       NE TOUCHE PAS à la config SSH : root et mot de passe restent actifs.
#   ./harden.sh lockdown
#       Phase 2. À lancer SEULEMENT après avoir testé la connexion par clé
#       avec l'utilisateur deploy. Désactive root et le mot de passe SSH.
#
# Le script est idempotent (relançable sans risque). Aucun secret dedans.
#
set -euo pipefail
umask 022

DEPLOY_USER="${DEPLOY_USER:-deploy}"
TZ_NAME="${TZ_NAME:-Europe/Paris}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-hardening.conf"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root."

usage() {
  cat <<EOF
Usage :
  $0 install "ssh-ed25519 AAAA... commentaire"
  $0 lockdown
EOF
  exit 1
}

user_home() { getent passwd "$DEPLOY_USER" | cut -d: -f6; }

validate_pubkey() {
  local key="$1" tmp
  [[ "$key" == "ssh-ed25519 "* ]] \
    || die "La clé doit commencer par 'ssh-ed25519 ' (clé PUBLIQUE, fichier .pub). Ne donne jamais la clé privée."
  [[ "$key" != *$'\n'* ]] || die "La clé doit tenir sur une seule ligne."
  tmp="$(mktemp)"
  printf '%s\n' "$key" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "Clé publique invalide."
  fi
  rm -f "$tmp"
}

# --------------------------------------------------------------------------
# Phase 1 : install
# --------------------------------------------------------------------------
cmd_install() {
  local pubkey="${1:-}"
  [[ -n "$pubkey" ]] || usage
  validate_pubkey "$pubkey"

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  log "Mise à jour du système et installation des paquets"
  apt-get update -qq
  apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
  apt-get -y -qq install ufw fail2ban unattended-upgrades curl ca-certificates rsync

  log "Fuseau horaire : $TZ_NAME"
  timedatectl set-timezone "$TZ_NAME"

  log "Utilisateur '$DEPLOY_USER' (sudo, connexion par clé uniquement)"
  if id "$DEPLOY_USER" &>/dev/null; then
    info "existe déjà"
  else
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
  fi
  usermod -aG sudo "$DEPLOY_USER"

  local home
  home="$(user_home)"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  if ! grep -qxF "$pubkey" "$home/.ssh/authorized_keys"; then
    printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys"
    info "clé publique ajoutée"
  else
    info "clé publique déjà présente"
  fi
  chown "$DEPLOY_USER:$DEPLOY_USER" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"

  log "Pare-feu ufw : seuls 22, 80, 443 ouverts"
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP (Caddy)'
  ufw allow 443/tcp comment 'HTTPS (Caddy)'
  ufw logging low
  ufw --force enable
  ufw status verbose

  log "fail2ban (protection SSH)"
  cat > /etc/fail2ban/jail.d/10-hardening.local <<'EOF'
# Géré par harden.sh
[DEFAULT]
backend  = systemd
banaction = ufw
bantime  = 1h
findtime = 10m
maxretry = 4
bantime.increment = true
bantime.maxtime   = 1w

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2
  fail2ban-client status sshd || warn "Le jail sshd ne répond pas encore, vérifie avec verify-hardening.sh"

  log "Mises à jour de sécurité automatiques (sans redémarrage automatique)"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat > /etc/apt/apt.conf.d/52-hardening-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  systemctl enable unattended-upgrades >/dev/null 2>&1
  systemctl restart unattended-upgrades

  log "Swap de $SWAP_SIZE"
  if swapon --show --noheadings | grep -q .; then
    info "swap déjà actif"
  else
    if [[ -e /swapfile ]]; then
      die "/swapfile existe déjà mais n'est pas actif : à examiner à la main."
    fi
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    info "swap créé"
  fi

  log "Réglages noyau (sysctl)"
  cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Géré par harden.sh
vm.swappiness = 10
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
  sysctl --system >/dev/null

  log "Docker : rotation des logs (évite de remplir le disque)"
  if [[ -f /etc/docker/daemon.json ]]; then
    warn "/etc/docker/daemon.json existe déjà : non modifié. Vérifie qu'il limite la taille des logs."
  else
    install -d -m 755 /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
    systemctl restart docker
    info "daemon.json créé, Docker redémarré"
  fi
  if getent group docker >/dev/null; then
    usermod -aG docker "$DEPLOY_USER"
    info "'$DEPLOY_USER' ajouté au groupe docker (accès équivalent à root, voir README)"
  fi

  cat <<EOF

────────────────────────────────────────────────────────────
Phase 1 terminée. SSH n'a PAS été modifié (root et mot de passe
fonctionnent encore). Prochaines actions :

  1. Définis le mot de passe SUDO de '$DEPLOY_USER' (tape-le ici,
     ne le partage jamais). Il ne sert PAS à se connecter en SSH :
       passwd $DEPLOY_USER

  2. Depuis ton Mac, dans un NOUVEAU terminal, teste la connexion
     par clé (voir les commandes données dans le chat).

  3. Quand ça marche, reviens ici et lance :
       ./harden.sh lockdown
────────────────────────────────────────────────────────────
EOF
}

# --------------------------------------------------------------------------
# Phase 2 : lockdown
# --------------------------------------------------------------------------
cmd_lockdown() {
  id "$DEPLOY_USER" &>/dev/null || die "L'utilisateur '$DEPLOY_USER' n'existe pas : lance d'abord 'install'."

  local home
  home="$(user_home)"
  [[ -s "$home/.ssh/authorized_keys" ]] \
    || die "Aucune clé dans $home/.ssh/authorized_keys : lockdown refusé (tu serais enfermé dehors)."

  local pw_state
  pw_state="$(passwd -S "$DEPLOY_USER" | awk '{print $2}')"
  [[ "$pw_state" == "P" ]] \
    || die "'$DEPLOY_USER' n'a pas de mot de passe sudo. Lance : passwd $DEPLOY_USER"

  id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx sudo \
    || die "'$DEPLOY_USER' n'est pas dans le groupe sudo."

  cat <<EOF

ATTENTION : cette étape désactive la connexion SSH de root et par mot de passe.
Avant de continuer, tu dois avoir RÉUSSI, depuis ton Mac, dans un autre terminal :
   ssh -i ~/.ssh/ahua_vps_ed25519 -o IdentitiesOnly=yes $DEPLOY_USER@<IP>
   puis 'sudo -v' (avec le mot de passe sudo)
Garde ce terminal root OUVERT pendant tout le test. En cas de problème,
la console web IONOS permet de réparer.

EOF
  local answer
  read -r -p "Connexion par clé testée avec succès ? Tape OUI en majuscules : " answer
  [[ "$answer" == "OUI" ]] || die "Annulé, rien n'a été modifié."

  log "Écriture de $SSHD_DROPIN"
  local backup=""
  if [[ -f "$SSHD_DROPIN" ]]; then
    backup="$(mktemp)"
    cp -a "$SSHD_DROPIN" "$backup"
  fi

  # Nommé 00-* : sshd garde la PREMIÈRE valeur rencontrée, ce fichier doit
  # passer avant 50-cloud-init.conf (qui active parfois PasswordAuthentication).
  cat > "$SSHD_DROPIN" <<EOF
# Géré par harden.sh — ne pas éditer à la main
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
AllowUsers $DEPLOY_USER
MaxAuthTries 4
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
# 'local' : autorise les tunnels -L (accès admin à Postgres), pas les -R
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  chmod 644 "$SSHD_DROPIN"

  rollback() {
    if [[ -n "$backup" ]]; then cp -a "$backup" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
  }

  if ! sshd -t; then
    rollback
    die "Configuration SSH invalide, annulée. SSH n'a pas été rechargé."
  fi

  local eff kv
  eff="$(sshd -T)"
  for kv in \
    "permitrootlogin no" \
    "passwordauthentication no" \
    "kbdinteractiveauthentication no" \
    "pubkeyauthentication yes" \
    "allowusers $DEPLOY_USER"; do
    if ! grep -qix "$kv" <<<"$eff"; then
      rollback
      die "Valeur effective inattendue ('$kv') : un autre fichier de sshd_config.d prend le dessus. Config annulée, SSH non rechargé."
    fi
  done
  info "sshd -t OK et valeurs effectives vérifiées"

  systemctl reload ssh || systemctl restart ssh
  [[ -n "$backup" ]] && rm -f "$backup"

  cat <<EOF

────────────────────────────────────────────────────────────
Lockdown appliqué. Cette session root reste ouverte : NE LA FERME PAS
avant d'avoir fait les tests suivants depuis le Mac (voir le chat) :
  - la connexion de '$DEPLOY_USER' par clé fonctionne encore
  - root et le mot de passe sont refusés
Puis lance ici : ./verify-hardening.sh
────────────────────────────────────────────────────────────
EOF
}

case "${1:-}" in
  install)  shift; cmd_install "$@" ;;
  lockdown) cmd_lockdown ;;
  *)        usage ;;
esac
