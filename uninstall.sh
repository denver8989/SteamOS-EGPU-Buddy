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
runtime_leftovers(){
  printf '%s\n' \
    /etc/nv-egpu-buddy \
    /var/lib/nvegpu \
    "$USER_HOME/.local/gamescope-gbm" \
    "$USER_HOME/.local/lib/nv-egpu-buddy" \
    "$USER_HOME/.config/environment.d/10-egpu-gamescope-output.conf"
}

# --verify: list anything this project left behind. Used to prove a clean uninstall
# before a from-scratch reinstall. Prints nothing and exits 0 when the machine is clean.
if [ "${1:-}" = "--verify" ]; then
  left=0
  for f in $(cd "$ROOT" && find system user -type f); do
    d=$(map_dest "$f"); [ -e "$d" ] && { echo "LEFT  $d"; left=1; }
  done
  for d in $(runtime_leftovers) /etc/sudoers.d/zz-steamos-egpu-buddy /etc/sudoers.d/steamos-egpu-buddy \
           /etc/extensions/egpu-nvidia.raw /etc/extensions/egpu-nvidia /home/.egpu-buddy \
           /etc/plasmalogin.conf.d/zz-egpu-buddy-session.conf /etc/sddm.conf.d/zz-egpu-buddy-session.conf; do
    [ -e "$d" ] && { echo "LEFT  $d"; left=1; }
  done
  grep -q '^sysext /usr ' /proc/mounts 2>/dev/null && { echo "LEFT  driver extension still merged into /usr"; left=1; }
  grep -qE '^IgnorePkg.*\b(nvidia-utils|lib32-nvidia-utils|opencl-nvidia|lib32-opencl-nvidia)\b' /etc/pacman.conf 2>/dev/null &&
    { echo "LEFT  pacman.conf still pins NVIDIA packages (IgnorePkg)"; left=1; }
  # the boot configuration must be able to boot unattended and quietly, as it did before the install
  bcfg=$(ls /efi/EFI/steamos/grub.cfg /boot/efi/EFI/steamos/grub.cfg /boot/grub/grub.cfg 2>/dev/null | head -1)
  if [ -n "$bcfg" ] && sudo test -r "$bcfg"; then
    sudo grep -q 'steamenv_init' "$bcfg" 2>/dev/null || sudo grep -qE '^[[:space:]]*set timeout=' "$bcfg" 2>/dev/null ||
      { echo "LEFT  boot config would stop at a menu (no steamenv header and no timeout)"; left=1; }
  fi
  # The plugin and the installed copy it runs from are kept ON PURPOSE when the uninstall
  # came from the plugin (it cannot delete itself mid-run, and you need it to reinstall).
  for d in "$USER_HOME/homebrew/plugins/EGPU-Buddy" "$USER_HOME/.local/share/steamos-egpu-buddy"; do
    [ -e "$d" ] || continue
    if [ "${EGPU_KEEP_PLUGIN:-0}" = 1 ]; then echo "kept  $d (plugin uninstall keeps this so it can reinstall)"
    else echo "LEFT  $d"; left=1; fi
  done
  [ "$left" = 0 ] && echo "clean: nothing from this project is left on the system"
  exit $left
fi
# SteamOS: a merged driver extension makes /usr (with /usr/local) read-only; it goes away below anyway, so unmerge first
if command -v steamos-readonly >/dev/null 2>&1 && grep -q '^sysext /usr ' /proc/mounts 2>/dev/null; then
  [ -d /sys/module/nvidia ] && { echo "The NVIDIA driver is loaded (eGPU in use). Safe Detach, unplug the eGPU, then uninstall again. Nothing was changed."; exit 21; }
  sudo systemd-sysext unmerge >/dev/null 2>&1 || { echo "could not unmerge the driver extension. Reboot with the eGPU unplugged and uninstall again. Nothing was changed."; exit 21; }
fi
userctl disable --now egpu-display-failover.service egpu-wake-guard.service egpu-buddy-tray.service 2>/dev/null
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
# The install pins the NVIDIA userspace by adding it to pacman's IgnorePkg. Leaving that behind means
# the package manager keeps holding packages back for software that is no longer here — which is not
# "the machine as it was". Remove only the entries this project adds, never the whole line, and drop
# the line entirely if it was empty before.
if [ -f /etc/pacman.conf ] && grep -qE '^IgnorePkg' /etc/pacman.conf; then
  sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak-egpu-buddy-$(date +%Y%m%d-%H%M%S)"
  for pk in nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia; do
    sudo sed -i -E "s/^(IgnorePkg[[:space:]]*=.*)[[:space:]]+$pk\b/\1/; s/^(IgnorePkg[[:space:]]*=)[[:space:]]*$pk\b/\1/" /etc/pacman.conf
  done
  # an IgnorePkg line left with nothing on it was not there before us
  sudo sed -i -E '/^IgnorePkg[[:space:]]*=[[:space:]]*$/d' /etc/pacman.conf
  echo "restored pacman.conf (NVIDIA package pins removed)"
fi
if [ -f /etc/default/grub.d/egpu-buddy.cfg ]; then sudo rm -f /etc/default/grub.d/egpu-buddy.cfg
  cfg=$(ls /efi/EFI/steamos/grub.cfg /boot/efi/EFI/steamos/grub.cfg /boot/grub/grub.cfg 2>/dev/null | head -1)
  if [ -n "$cfg" ] && sudo grub-mkconfig -o "$cfg" >/dev/null 2>&1; then
    echo "kernel parameters removed from the boot configuration ($cfg)"
    # Uninstalling must leave the machine as it was found. grub-mkconfig on SteamOS produces a config
    # WITHOUT the steamenv header block, and without it the bootloader strips the verbosity parameters
    # and adds none back, and there is no timeout — so a boot comes up as a wall of console text and
    # stops at a menu, on a handheld with no keyboard. Removing this project must not leave that behind.
    if ! sudo grep -q 'steamenv_init' "$cfg" 2>/dev/null && sudo grep -q '^menuentry ' "$cfg" 2>/dev/null; then
      sudo awk 'BEGIN{done=0}
           /^menuentry / && !done {
             print "## start header steamenv sub block (restored on uninstall)"
             print "insmod steamenv"
             print "steamenv_loader_mode=auto"
             print "steamenv_kernel_mode=keep"
             print "steamenv_quiet=\"loglevel=3 splash quiet plymouth.ignore-serial-consoles fbcon=vc:4-6\""
             print "steamenv_noisy=\"loglevel=5 sysrq_always_enabled splash=verbose fbcon=nodefer\""
             print "steamenv_verbosity=\"\""
             print "timeout=0"
             print "timeout_style=menu"
             print "steamenv_init"
             print "## end steamenv header sub block"
             print ""
             done=1
           }
           {print}' "$cfg" > /tmp/egpu-grub-restored.$$ && sudo cp /tmp/egpu-grub-restored.$$ "$cfg" && rm -f /tmp/egpu-grub-restored.$$
      echo "restored SteamOS's boot header (quiet boot, no menu) — the machine boots as it did before"
    fi
    sudo grep -qE '^[[:space:]]*set timeout=' "$cfg" 2>/dev/null ||
      { sudo sed -i '1i set timeout=0' "$cfg"; sudo sed -i '1i set timeout_style=hidden' "$cfg"; }
  fi
fi
sudo rm -f /etc/nv-egpu-buddy/version
# Everything else this project creates at RUNTIME rather than at install time. Without
# these a reinstall is not a fresh install: it inherits old state, an old gamescope and
# an old routing file. Listed in one place so --verify can check the same set.
runtime_leftovers | while read -r d; do sudo rm -rf "$d"; done
sudo rm -f /var/log/egpu-*.log /run/nvegpu/* 2>/dev/null
userctl daemon-reload
echo "done. The stock gamescope-session / plasmalogin configuration is back in effect after a reboot."
