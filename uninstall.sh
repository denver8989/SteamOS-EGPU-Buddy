#!/usr/bin/env bash
# Remove SteamOS-EGPU-Buddy files, restoring the newest .bak-egpu-buddy-* backup where one exists.
# Does NOT remove the patched NVIDIA driver package (pacman -R nvidia-open-egpu; reinstall nvidia-open-dkms) or the
# gamescope-gbm build (~/.local/gamescope-gbm, ~/build/gamescope-gbm) - delete those by hand if wanted.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
if [ "$(id -u)" = 0 ]; then USER_NAME=${EGPU_TARGET_USER:-${SUDO_USER:-}}; [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "running as root: set EGPU_TARGET_USER=<login user>"; exit 1; }; sudo(){ "$@"; }; AS_ROOT=1; else USER_NAME=${SUDO_USER:-$USER}; AS_ROOT=0; fi
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6); USER_UID=$(id -u "$USER_NAME")
userctl(){ if [ "$AS_ROOT" = 1 ]; then runuser -u "$USER_NAME" -- env "XDG_RUNTIME_DIR=/run/user/$USER_UID" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus" systemctl --user "$@"; else systemctl --user "$@"; fi; }
map_dest(){ case "$1" in system/*) echo "/${1#system/}";; user/*) echo "$USER_HOME/${1#user/}";; esac; }
restore_or_remove(){ # $1 dest ; run in the right privilege context
  local d=$1 b; b=$(ls -t "$d".bak-egpu-buddy-* 2>/dev/null | head -1)
  if [ -n "$b" ]; then mv -f "$b" "$d"; echo "restored $d"; else rm -f "$d"; echo "removed  $d"; fi
}
# SteamOS: a merged driver extension makes /usr (with /usr/local) read-only; it goes away below anyway, so unmerge first
if command -v steamos-readonly >/dev/null 2>&1 && grep -q '^sysext /usr ' /proc/mounts 2>/dev/null; then
  [ -d /sys/module/nvidia ] && { echo "The NVIDIA driver is loaded (eGPU in use). Safe Detach, unplug the eGPU, then uninstall again. Nothing was changed."; exit 21; }
  sudo systemd-sysext unmerge >/dev/null 2>&1 || { echo "could not unmerge the driver extension. Reboot with the eGPU unplugged and uninstall again. Nothing was changed."; exit 21; }
fi
userctl disable --now egpu-display-failover.service egpu-wake-guard.service 2>/dev/null
cd "$ROOT"; find user -type f | while read -r f; do restore_or_remove "$(map_dest "$f")"; done
sudo bash -c "$(declare -f restore_or_remove); systemctl disable egpu-mount.service egpu-boot-enumerate.service egpu-conditional-session.service egpu-buddy-selfheal.service egpu-buddy-resume.service 2>/dev/null; $(cd "$ROOT" && find system -type f | while read -r f; do printf 'restore_or_remove %q\n' "$(map_dest "$f")"; done); udevadm control --reload; systemctl daemon-reload"
[ "${EGPU_KEEP_PLUGIN:-0}" = 1 ] || sudo rm -rf "$USER_HOME/homebrew/plugins/EGPU-Buddy"
[ "${EGPU_KEEP_PLUGIN:-0}" = 1 ] || rm -rf "$USER_HOME/.local/share/steamos-egpu-buddy"; rm -f "$USER_HOME/.local/share/applications/egpu-safe-detach.desktop" "$USER_HOME/.config/autostart/egpu-buddy-tray.desktop" "$USER_HOME/Desktop/egpu-buddy.desktop" "$USER_HOME/Desktop/egpu-safe-detach.desktop"; rm -rf "$USER_HOME/.local/share/egpu-buddy" "$USER_HOME/.local/bin/egpu-buddy" "$USER_HOME/.local/share/applications/egpu-buddy.desktop"
# SteamOS: the driver extension and build root on /home, the OS-update keep-list, the GRUB drop-in (+ regenerate GRUB)
if [ -d /home/.egpu-buddy ] || [ -L /etc/extensions/egpu-nvidia ] || [ -L /etc/extensions/egpu-nvidia.raw ]; then
  echo "removing the NVIDIA driver extension (SteamOS)"
  if [ -x "$ROOT/packaging/nvidia-open-egpu/install-steamos-sysext.sh" ]; then sudo bash "$ROOT/packaging/nvidia-open-egpu/install-steamos-sysext.sh" --remove
  else sudo rm -f /etc/extensions/egpu-nvidia /etc/extensions/egpu-nvidia.raw; sudo systemd-sysext refresh >/dev/null 2>&1 || true; sudo ldconfig 2>/dev/null || true; sudo rm -rf /home/.egpu-buddy; fi
fi
sudo /usr/local/sbin/egpu-dm-session unpin >/dev/null 2>&1 || sudo rm -f /etc/plasmalogin.conf.d/zz-egpu-buddy-session.conf /etc/sddm.conf.d/zz-egpu-buddy-session.conf /etc/plasmalogin.conf.d/zz-steamos-autologin.conf
sudo rm -f /etc/sudoers.d/steamos-egpu-buddy /etc/sudoers.d/zz-steamos-egpu-buddy
sudo rm -f /etc/atomic-update.conf.d/egpu-buddy.conf
if [ -f /etc/default/grub.d/egpu-buddy.cfg ]; then sudo rm -f /etc/default/grub.d/egpu-buddy.cfg
  cfg=$(ls /efi/EFI/steamos/grub.cfg /boot/efi/EFI/steamos/grub.cfg /boot/grub/grub.cfg 2>/dev/null | head -1)
  [ -n "$cfg" ] && sudo grub-mkconfig -o "$cfg" >/dev/null 2>&1 && echo "kernel parameters removed from the boot configuration ($cfg)"; fi
sudo rm -f /etc/nv-egpu-buddy/version
userctl daemon-reload
echo "done. The stock gamescope-session / plasmalogin configuration is back in effect after a reboot."
