#!/bin/bash
# SteamOS EGPU Buddy self-heal. Runs as root at boot (egpu-buddy-selfheal.service; unit in /etc, script here in
# /home: both survive an OS update that replaces /usr). If the root-side integration is missing or outdated it is
# re-applied from this payload; pacman packages and kernel modules are restored from the caches kept here.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); VER=$(cat "$HERE/VERSION" 2>/dev/null || echo dev)
USER_NAME=$(stat -c %U "$HERE"); log(){ logger -t egpu-buddy-selfheal "$*"; echo "$*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
ro=$(command -v steamos-readonly || true)
need=0
[ -x /usr/local/sbin/nv-egpu-buddy-privileged ] && [ -x /usr/local/sbin/egpu-hotplug-mount.sh ] || need=1
[ "$(cat /etc/nv-egpu-buddy/version 2>/dev/null)" = "$VER" ] || need=1
[ "${SELFHEAL_FORCE:-0}" = 1 ] && need=1
if [ $need = 1 ]; then
  log "root integration missing or outdated (have '$(cat /etc/nv-egpu-buddy/version 2>/dev/null)', payload $VER): repairing"
  [ -n "$ro" ] && $ro disable >/dev/null 2>&1
  if command -v pacman >/dev/null 2>&1 && [ -d "$HERE/pkgcache" ]; then
    for p in "$HERE"/pkgcache/*.pkg.tar.*; do [ -f "$p" ] || continue
      n=$(basename "$p" | sed -E 's/-[^-]+-[^-]+-[^-]+\.pkg\.tar\..*$//'); pacman -Q "$n" >/dev/null 2>&1 || { log "restoring package $n"; pacman -U --noconfirm --ask 4 "$p" >/dev/null 2>&1 || log "failed: $n"; }
    done
  fi
  EGPU_TARGET_USER=$USER_NAME EGPU_AUTO_YES=1 EGPU_COMPONENTS=core,session,gamescope,bootpolicy,desktopapp EGPU_PREBUILT_GAMESCOPE="$HERE/prebuilt/gamescope-gbm" \
    EGPU_ACCEPT_UNTESTED=1 bash "$HERE/install.sh" >/tmp/egpu-buddy-selfheal.log 2>&1 && log "repair done" || log "repair reported errors (see /tmp/egpu-buddy-selfheal.log)"
  [ -n "$ro" ] && $ro enable >/dev/null 2>&1
fi
# patched driver package: restore from cache (done above) or rebuild from the payload's PKGBUILD (source cached)
if command -v pacman >/dev/null 2>&1 && ! pacman -Q nvidia-open-egpu-dkms >/dev/null 2>&1 && [ -x "$HERE/packaging/nvidia-open-egpu/install-patched-nvidia.sh" ] && [ -f "/usr/lib/modules/$(uname -r)/build/Makefile" ]; then
  log "patched driver package missing: rebuilding from the payload"; [ -n "$ro" ] && $ro disable >/dev/null 2>&1
  EGPU_TARGET_USER=$USER_NAME bash "$HERE/packaging/nvidia-open-egpu/install-patched-nvidia.sh" >>/tmp/egpu-buddy-selfheal.log 2>&1 && log "driver package rebuilt" || log "driver rebuild failed (see /tmp/egpu-buddy-selfheal.log)"
  [ -n "$ro" ] && $ro enable >/dev/null 2>&1
fi
# kernel modules for the running kernel: DKMS rebuild if possible, else the cached modules of this exact kernel
K=$(uname -r)
if ! modinfo -n nvidia >/dev/null 2>&1 || [ ! -f "/usr/lib/modules/$K/updates/dkms/nvidia.ko.zst" ]; then
  if command -v dkms >/dev/null 2>&1 && [ -f "/usr/lib/modules/$K/build/Makefile" ]; then
    log "no patched modules for $K: dkms autoinstall"; [ -n "$ro" ] && $ro disable >/dev/null 2>&1; dkms autoinstall -k "$K" >/dev/null 2>&1 && log "dkms built for $K" || log "dkms build failed for $K"; [ -n "$ro" ] && $ro enable >/dev/null 2>&1
  elif [ -d "$HERE/modcache/$K" ]; then
    log "no headers for $K: restoring cached modules"; [ -n "$ro" ] && $ro disable >/dev/null 2>&1
    mkdir -p "/usr/lib/modules/$K/updates/dkms" && cp -a "$HERE/modcache/$K"/nvidia*.ko* "/usr/lib/modules/$K/updates/dkms/" && depmod -a "$K" && log "modules restored for $K"
    [ -n "$ro" ] && $ro enable >/dev/null 2>&1
  else
    log "no patched NVIDIA modules for kernel $K and no way to build or restore them; the eGPU will not attach on this kernel"
  fi
fi
# kernel parameters (bootloader config may have been regenerated)
if ! /usr/local/sbin/egpu-kernel-cmdline --check >/dev/null 2>&1; then
  /usr/local/sbin/egpu-kernel-cmdline --apply >/dev/null 2>&1 && log "kernel parameters re-applied; reboot needed" || log "kernel parameters missing and could not be written"
fi
exit 0
