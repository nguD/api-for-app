#!/usr/bin/env bash
#
# verify-hardening.sh — contrôles de l'état du VPS après durcissement.
# À lancer en root. Lecture seule : ne modifie rien.
# Avant la phase 'lockdown', les contrôles SSH échouent : c'est normal.
#
set -uo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
PASS=0; FAIL=0; WARN=0

ok() { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
wa() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

check() { # check "description" commande...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ko "$desc"; fi
}

[[ $EUID -eq 0 ]] || { echo "À lancer en root (ou avec sudo)." >&2; exit 1; }

section "SSH (valeurs effectives de sshd -T)"
EFF="$(sshd -T 2>/dev/null)"
for kv in \
  "permitrootlogin no" \
  "passwordauthentication no" \
  "kbdinteractiveauthentication no" \
  "pubkeyauthentication yes" \
  "allowusers $DEPLOY_USER" \
  "maxauthtries 4"; do
  if grep -qix "$kv" <<<"$EFF"; then ok "$kv"; else ko "attendu '$kv'"; fi
done

section "Utilisateur $DEPLOY_USER"
check "existe" id "$DEPLOY_USER"
check "dans le groupe sudo" bash -c "id -nG '$DEPLOY_USER' | tr ' ' '\n' | grep -qx sudo"
HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
check "authorized_keys non vide" test -s "$HOME_DIR/.ssh/authorized_keys"
if [[ -f "$HOME_DIR/.ssh/authorized_keys" ]]; then
  [[ "$(stat -c %a "$HOME_DIR/.ssh/authorized_keys")" == "600" ]] \
    && ok "authorized_keys en 600" || ko "authorized_keys doit être en 600"
fi
[[ "$(passwd -S "$DEPLOY_USER" 2>/dev/null | awk '{print $2}')" == "P" ]] \
  && ok "mot de passe sudo défini" || ko "mot de passe sudo non défini (passwd $DEPLOY_USER)"

section "Pare-feu ufw"
UFW="$(ufw status verbose 2>/dev/null)"
grep -q '^Status: active' <<<"$UFW" && ok "ufw actif" || ko "ufw inactif"
grep -q 'Default: deny (incoming)' <<<"$UFW" && ok "entrant : deny par défaut" || ko "politique entrante != deny"
ALLOWED="$(ufw status 2>/dev/null | awk '/ALLOW|LIMIT/ {print $1}' | sed 's#(v6)##' | sort -V -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$ALLOWED" == "22/tcp 80/tcp 443/tcp" ]]; then
  ok "règles autorisées : $ALLOWED"
else
  ko "règles autorisées inattendues : $ALLOWED (attendu : 22/tcp 80/tcp 443/tcp)"
fi

section "fail2ban"
check "service actif" systemctl is-active --quiet fail2ban
check "jail sshd actif" fail2ban-client status sshd

section "Mises à jour automatiques"
check "unattended-upgrades activé" systemctl is-enabled --quiet unattended-upgrades
APT_CFG="$(apt-config dump 2>/dev/null)"   # variable : évite SIGPIPE + pipefail avec grep -q
if grep -q 'Unattended-Upgrade::Automatic-Reboot "false"' <<<"$APT_CFG"; then
  ok "redémarrage automatique désactivé"
else
  ko "Automatic-Reboot devrait être false"
fi
if [[ -f /var/run/reboot-required ]]; then
  wa "un redémarrage est nécessaire (noyau mis à jour) : lance 'reboot' à un moment adapté"
else
  ok "aucun redémarrage requis"
fi

section "Mémoire et système"
SWAP_LIST="$(swapon --show --noheadings)"
[[ -n "$SWAP_LIST" ]] && ok "swap actif" || ko "pas de swap"
[[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "Europe/Paris" ]] \
  && ok "fuseau Europe/Paris" || wa "fuseau différent de Europe/Paris"
check "sysctl durci chargé (tcp_syncookies=1)" bash -c '[[ "$(sysctl -n net.ipv4.tcp_syncookies)" == 1 ]]'

section "Docker"
check "docker actif" systemctl is-active --quiet docker
check "rotation des logs configurée" grep -q 'max-size' /etc/docker/daemon.json
USER_GROUPS=" $(id -nG "$DEPLOY_USER" 2>/dev/null) "
[[ "$USER_GROUPS" == *" docker "* ]] \
  && ok "$DEPLOY_USER dans le groupe docker" || ko "$DEPLOY_USER pas dans le groupe docker"

section "Ports en écoute hors loopback"
BAD_TCP=(); INFO_UDP=()
while read -r proto _ _ _ local _; do
  addr="${local%:*}"; port="${local##*:}"
  case "$addr" in 127.*|"[::1]"|"::1"|*%lo) continue ;; esac
  if [[ "$proto" == tcp ]]; then
    case "$port" in 22|80|443) ;; *) BAD_TCP+=("tcp/$port ($addr)") ;; esac
  else
    INFO_UDP+=("udp/$port ($addr)")
  fi
done < <(ss -tulnH)
if ((${#BAD_TCP[@]} == 0)); then
  ok "aucun port TCP inattendu (seuls 22/80/443 sont autorisés)"
else
  ko "ports TCP inattendus : ${BAD_TCP[*]}"
fi
if ((${#INFO_UDP[@]} > 0)); then
  wa "ports UDP en écoute (bloqués par ufw, à titre d'info) : ${INFO_UDP[*]}"
fi
echo "  Détail TCP :"; ss -tlnH | awk '{print "    "$4}'

printf '\nRésultat : %d OK, %d FAIL, %d WARN\n' "$PASS" "$FAIL" "$WARN"
((FAIL == 0))
