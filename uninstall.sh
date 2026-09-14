#!/usr/bin/env bash
# Remove SteamOS-EGPU-Buddy files, restoring the newest .bak-egpu-buddy-* backup where one exists.
# Does NOT remove the patched NVIDIA driver package (pacman -R nvidia-open-egpu; reinstall nvidia-open-dkms) or the
# gamescope-gbm build (~/.local/gamescope-gbm, ~/build/gamescope-gbm) - delete those by hand if wanted.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-$USER}; USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
map_dest(){ case "$1" in system/*) echo "/${1#system/}";; user/*) echo "$USER_HOME/${1#user/}";; esac; }
restore_or_remove(){ # $1 dest ; run in the right privilege context
  local d=$1 b; b=$(ls -t "$d".bak-egpu-buddy-* 2>/dev/null | head -1)
  if [ -n "$b" ]; then mv -f "$b" "$d"; echo "restored $d"; else rm -f "$d"; echo "removed  $d"; fi
}
systemctl --user disable egpu-display-failover.service 2>/dev/null
cd "$ROOT"; find user -type f | while read -r f; do restore_or_remove "$(map_dest "$f")"; done
sudo bash -c "$(declare -f restore_or_remove); systemctl disable egpu-mount.service egpu-boot-enumerate.service egpu-conditional-session.service 2>/dev/null; $(cd "$ROOT" && find system -type f | while read -r f; do printf 'restore_or_remove %q\n' "$(map_dest "$f")"; done); udevadm control --reload; systemctl daemon-reload"
sudo rm -rf "$USER_HOME/homebrew/plugins/EGPU-Buddy"
rm -rf "$USER_HOME/.local/share/egpu-buddy" "$USER_HOME/.local/bin/egpu-buddy" "$USER_HOME/.local/share/applications/egpu-buddy.desktop"
systemctl --user daemon-reload
echo "done. The stock gamescope-session / plasmalogin configuration is back in effect after a reboot."
