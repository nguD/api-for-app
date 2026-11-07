#!/usr/bin/env bash
#
# install-timers.sh — installe les timers systemd : sauvegarde (03h30), supervision (2 min),
# test de restauration (dimanche 05h00). À lancer en tant que 'deploy' (utilise sudo). Idempotent.
#
# Prérequis recommandé : avoir lancé scripts/backup.sh une fois (sinon la supervision signale
# « aucune sauvegarde ») et scripts/setup-alerts.sh (sinon les alertes ne partent pas).
#
# Usage : install-timers.sh            installe et active
#         install-timers.sh --remove   désactive et supprime
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_not_root

UNITS=(platform-backup platform-healthwatch platform-restoretest)
SRC="$PLATFORM_DIR/server/systemd"
DEST="/etc/systemd/system"
ME="$(id -un)"

if [[ "${1:-}" == "--remove" ]]; then
  for u in "${UNITS[@]}"; do
    sudo systemctl disable --now "$u.timer" 2> /dev/null || true
    sudo rm -f "$DEST/$u.service" "$DEST/$u.timer"
  done
  sudo systemctl daemon-reload
  log "Timers supprimés"
  exit 0
fi

[[ -d "$SRC" ]] || die "Dossier $SRC introuvable."
groups_of_me=" $(id -nG "$ME") "
[[ "$groups_of_me" == *" docker "* ]] || die "'$ME' n'est pas dans le groupe docker."

log "Installation des unités systemd (utilisateur $ME, dépôt $PLATFORM_DIR)"
for u in "${UNITS[@]}"; do
  for ext in service timer; do
    sed -e "s|@@USER@@|$ME|g" -e "s|@@REPO@@|$PLATFORM_DIR|g" "$SRC/$u.$ext" | sudo tee "$DEST/$u.$ext" > /dev/null
    sudo chmod 644 "$DEST/$u.$ext"
  done
done
sudo systemctl daemon-reload
for u in "${UNITS[@]}"; do
  sudo systemd-analyze verify "$DEST/$u.service" "$DEST/$u.timer" || warn "systemd-analyze a signalé un avertissement pour $u."
  sudo systemctl enable --now "$u.timer"
done

log "Prochaines exécutions"
systemctl list-timers 'platform-*' --no-pager
