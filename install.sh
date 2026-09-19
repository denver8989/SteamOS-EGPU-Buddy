#!/usr/bin/env bash
# SteamOS-EGPU-Buddy installer core. The graphical front end is installer/steamos-egpu-buddy; this script does the work.
#
#   ./install.sh                 install the default components (core, session, gamescope, decky, bootpolicy)
#   ./install.sh --with-driver   also build + install the patched nvidia-open kernel modules (Arch-based only)
#   ./install.sh --check         only report what differs between this repo and the live system
#   ./install.sh --no-gamescope  skip the GBM-scanout gamescope
#   EGPU_COMPONENTS=core,session,gamescope,decky,bootpolicy,desktopapp,driver   (env) subset to install
#   STOCK_GAMESCOPE_SESSION=/path  (env) the distro's gamescope-session script the wrapper should call
#   EGPU_PREBUILT_GAMESCOPE=dir     (env) prebuilt gamescope tree (usr/bin, usr/share) used when no toolchain is present
#
# Every replaced file is backed up next to itself as <file>.bak-egpu-buddy-<timestamp>.
# Paths that say /home/deck are rewritten to the current user's home; the sudoers rule to the current user.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
VER=$(cat "$ROOT/VERSION" 2>/dev/null || echo dev)
# Normal use: run as the login user, sudo is requested for system files. Root use (the Decky plugin's
# "Install system integration"): EGPU_TARGET_USER names the login user; user files are created as that user.
if [ "$(id -u)" = 0 ]; then
  USER_NAME=${EGPU_TARGET_USER:-${SUDO_USER:-}}; [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "running as root: set EGPU_TARGET_USER=<login user>"; exit 1; }
  AS_ROOT=1; sudo(){ "$@"; }
else
  USER_NAME=${SUDO_USER:-$USER}; AS_ROOT=0
fi
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6); USER_UID=$(id -u "$USER_NAME")
userctl(){ if [ "$AS_ROOT" = 1 ]; then runuser -u "$USER_NAME" -- env "XDG_RUNTIME_DIR=/run/user/$USER_UID" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus" systemctl --user "$@"; else systemctl --user "$@"; fi; }
umkdir(){ if [ "$AS_ROOT" = 1 ]; then runuser -u "$USER_NAME" -- mkdir -p "$@"; else mkdir -p "$@"; fi; }
uown(){ [ "$AS_ROOT" = 1 ] && chown -R "$USER_NAME" "$@" 2>/dev/null || true; }
COMPONENTS=${EGPU_COMPONENTS:-core,session,gamescope,decky,bootpolicy,desktopapp}
MODE=install
for a in "$@"; do case "$a" in --check) MODE=check;; --with-driver) COMPONENTS="$COMPONENTS,driver";; --no-gamescope) COMPONENTS=${COMPONENTS//gamescope/};; *) echo "unknown option $a"; exit 1;; esac; done
want(){ case ",$COMPONENTS," in *",$1,"*) return 0;; *) return 1;; esac; }
say(){ printf '\033[1m%s\033[0m\n' "$*"; }

# ---- preflight -----------------------------------------------------------------------------------
say "== preflight ($COMPONENTS)"
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" = steamos ] && [ "$MODE" = install ]; then
  echo "note: SteamOS (experimental): OS updates replace /usr; the self-heal service re-applies this integration at the next boot"
  echo "      from the copy kept in your home, restores cached packages and kernel modules, and rebuilds the driver if headers exist."
fi
for c in systemctl udevadm lspci; do command -v $c >/dev/null || { echo "missing $c"; exit 1; }; done
lspci -Dn | grep -qE '0300: 10de:' || echo "note: no NVIDIA GPU on the bus right now (fine, it is hot-pluggable)"
# runtime tools the scripts call (package names are Arch/SteamOS; Bazzite equivalents are similar)
miss=""; for c in setpci:pciutils modetest:libdrm fuser:psmisc jq:jq xxd:vim perl:perl python3:python qdbus6:qt6-tools kscreen-doctor:libkscreen xprop:xorg-xprop boltctl:bolt nvidia-smi:nvidia-utils; do
  command -v "${c%%:*}" >/dev/null 2>&1 || miss="$miss ${c%%:*}(${c#*:})"; done
[ -z "$miss" ] || echo "warning: missing tools, some paths will degrade:$miss"
STOCK=${STOCK_GAMESCOPE_SESSION:-}; [ -n "$STOCK" ] || for s in /usr/lib/steamos/gamescope-session /usr/bin/gamescope-session /usr/bin/gamescope-session-plus; do [ -f "$s" ] && { STOCK=$s; break; }; done
[ -n "$STOCK" ] || echo "warning: no gamescope-session script found; Game Mode pieces will be inert"
# NVIDIA userspace + driver packages (the hot-plug path loads nvidia-open; nvidia-smi/NVML drive the controls)
# ---- untested hardware: say so, and get an explicit acceptance before anything is installed ----
if [ "$MODE" = install ] && untested=$(bash "$ROOT/system/usr/local/sbin/egpu-detect" --untested 2>/dev/null); then
  echo; echo "*** THIS HARDWARE OR SYSTEM HAS NOT BEEN TESTED WITH SteamOS EGPU Buddy ***"
  printf '%s\n' "$untested" | sed 's/^/    /'
  echo "    Everything here was verified on one machine only (see TESTED.md). On yours it may not work, may leave the"
  echo "    screen dark, or may need a reboot to recover. You install and test it AT YOUR OWN RISK."
  if [ "${EGPU_ACCEPT_UNTESTED:-0}" != 1 ]; then
    if [ -t 0 ]; then read -rp "    Type YES to continue: " r; [ "$r" = YES ] || { echo "aborted"; exit 1; }
    else echo "    (unattended run without EGPU_ACCEPT_UNTESTED=1: aborting)"; exit 1; fi
  fi
  echo
fi
# stock SteamOS ships pacman without an initialised keyring: every package operation then fails ("keyring is not
# writable / required key missing"). Initialise and populate it once (seen on a Legion Go, SteamOS, 2026-09-18).
if [ "$MODE" = install ] && command -v pacman-key >/dev/null 2>&1 && ! sudo pacman-key --list-keys >/dev/null 2>&1; then
  say "== initialising the pacman keyring (first package operation on this system)"
  { sudo pacman-key --init && sudo pacman-key --populate; } >/dev/null 2>&1 || echo "warning: could not initialise the pacman keyring; package steps will fail"
fi
# SteamOS only: the driver step builds everything in a build root on /home, and the distro packages (3.8: 575.64.05,
# ~1.4 GB) neither fit the 5 GB system partition nor match the tested driver. Every other distro keeps its own packages.
if ! { want driver && command -v steamos-readonly >/dev/null 2>&1; } && ! command -v nvidia-smi >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1 && [ "$MODE" = install ]; then
  yes=${EGPU_AUTO_YES:-}; if [ -z "$yes" ] && [ -t 0 ]; then read -rp "NVIDIA packages are missing. Install nvidia-open-dkms + nvidia-utils now with pacman? [y/N] " r; [ "${r,,}" = y ] && yes=1; fi
  if [ "$yes" = 1 ]; then say "== installing nvidia-open-dkms nvidia-utils lib32-nvidia-utils"; sudo pacman -S --needed --noconfirm nvidia-open-dkms nvidia-utils lib32-nvidia-utils || echo "warning: NVIDIA package install failed; install them by hand"; else echo "warning: no nvidia-smi; install nvidia-open-dkms + nvidia-utils before plugging the eGPU in"; fi
fi
# USB4 / Thunderbolt stack: the eGPU arrives over it (AMD USB4 and Intel Thunderbolt share the kernel driver + boltd)
if [ "$MODE" = install ]; then
  if ! command -v boltctl >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1; then say "== installing bolt (Thunderbolt/USB4 device manager)"; sudo pacman -S --needed --noconfirm bolt >/dev/null || echo "warning: could not install bolt"; fi
  sudo modprobe thunderbolt 2>/dev/null || true
  if [ -d /sys/bus/thunderbolt/devices/domain0 ]; then say "== USB4/Thunderbolt controller present ($(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null || echo ?) security level)"
  else echo "WARNING: no USB4/Thunderbolt controller is visible to the kernel. Enable USB4 / Thunderbolt in the firmware (BIOS) settings, then reboot; the eGPU cannot attach without it."; fi
fi
# What counts is whether the parameters are PERSISTED in the bootloader configuration (the running kernel can have them
# from hand-edited entries that the next kernel update regenerates without them). Written but not active = just reboot.
KC="$ROOT/system/usr/local/sbin/egpu-kernel-cmdline"
if bash "$KC" --written >/dev/null 2>&1; then
  bash "$KC" --check >/dev/null 2>&1 || echo "note: the kernel parameters are written; they become active with the next reboot (before plugging the eGPU in)"
else
  echo "note: the eGPU kernel parameters are not in the bootloader configuration yet; this install writes them (backup kept). Reboot BEFORE plugging the eGPU in."
  CMDLINE_MISSING=1
fi

# ---- file map ------------------------------------------------------------------------------------
map_dest(){ case "$1" in system/*) echo "/${1#system/}";; user/*) echo "$USER_HOME/${1#user/}";; esac; }
in_scope(){ # component gating by path
  case "$1" in
    system/usr/local/sbin/egpu-conditional-session|system/etc/systemd/system/egpu-conditional-session.service) want bootpolicy;;
    user/.local/bin/nv-egpu-gamescope-*|user/.local/lib/*|user/.config/systemd/user/gamescope-session.service.d/*|user/.config/systemd/user/steam-launcher.service.d/*|user/.config/gamescope/*|user/.config/environment.d/*|user/.local/bin/egpu-display-profile.sh|user/.local/bin/egpu-kwin-route.sh) want session;;
    *) want core;;
  esac
}
mapfile -t ALL < <(cd "$ROOT" && find system user -type f | sort)
FILES=(); for f in "${ALL[@]}"; do in_scope "$f" && FILES+=("$f"); done

templ(){ sed -e "s|/home/deck|$USER_HOME|g" -e "s|^deck ALL=|$USER_NAME ALL=|" -e "s|^Environment=STOCK_GAMESCOPE_SESSION=.*|Environment=STOCK_GAMESCOPE_SESSION=${STOCK:-/usr/lib/steamos/gamescope-session}|"; }
differs(){ [ -f "$2" ] || return 0; ! cmp -s <(templ < "$ROOT/$1") "$2"; }

if [ "$MODE" = check ]; then
  say "== check (repo vs live)"
  n=0; for f in "${FILES[@]}"; do d=$(map_dest "$f"); if [ ! -r "$(dirname "$d")" ]; then echo "UNREADABLE $d (root-only dir; installed by sudo)"; elif [ ! -e "$d" ]; then echo "MISSING  $d"; n=$((n+1)); elif differs "$f" "$d"; then echo "DIFFERS  $d"; n=$((n+1)); fi; done
  echo "$n file(s) differ or are missing"; exit 0
fi

# ---- SteamOS: a merged driver extension makes ALL of /usr read-only ------------------------------
# On SteamOS /usr/local is part of the system partition (no separate mount), and a merged system extension turns /usr
# into a read-only overlay: a second install then fails with "Read-only file system" (seen on a real device, 0.7.21).
# So: unmerge for the duration of the install, and merge again on EVERY way out. Not while the driver is in use.
SYSEXT_TOOL="$ROOT/packaging/nvidia-open-egpu/install-steamos-sysext.sh"
if command -v steamos-readonly >/dev/null 2>&1 && grep -q '^sysext /usr ' /proc/mounts 2>/dev/null; then
  if [ -d /sys/module/nvidia ]; then echo "The NVIDIA driver is loaded (eGPU in use). Safe Detach, unplug the eGPU, then run the install again. Nothing was changed."; exit 21; fi
  say "== SteamOS: unmerging the driver extension while the system files are written"
  sudo systemd-sysext unmerge >/dev/null 2>&1 || { echo "could not unmerge the driver extension (files in use?). Reboot with the eGPU unplugged and run the install again. Nothing was changed."; exit 21; }
  trap 'sudo bash "$SYSEXT_TOOL" --activate >/dev/null 2>&1 || true' EXIT
fi

# ---- user files ----------------------------------------------------------------------------------
say "== installing user files"
for f in "${FILES[@]}"; do case "$f" in user/*) ;; *) continue;; esac
  d=$(map_dest "$f"); umkdir "$(dirname "$d")"
  if [ -e "$d" ] && differs "$f" "$d"; then cp -a "$d" "$d.bak-egpu-buddy-$TS"; fi
  templ < "$ROOT/$f" > "$d"; chmod --reference="$ROOT/$f" "$d" 2>/dev/null || true; uown "$d"
done
if want session; then
  chmod +x "$USER_HOME"/.local/bin/nv-egpu-* "$USER_HOME"/.local/bin/egpu-* "$USER_HOME/.local/lib/nv-egpu-buddy/gamescope-shim/gamescope" 2>/dev/null || true
fi

# ---- system files (sudo) -------------------------------------------------------------------------
say "== installing system files (sudo)"
SYS_TMP=$(mktemp -d); n=0
for f in "${FILES[@]}"; do case "$f" in system/*) ;; *) continue;; esac
  d=$(map_dest "$f"); mkdir -p "$SYS_TMP/$(dirname "$d")"; templ < "$ROOT/$f" > "$SYS_TMP/$d"; chmod --reference="$ROOT/$f" "$SYS_TMP/$d" 2>/dev/null || true; n=$((n+1))
done
if [ "$n" -gt 0 ]; then
sudo bash -c "
set -e; TS=$TS
cd '$SYS_TMP'; find . -type f | while read -r f; do d=\"\${f#.}\"; mkdir -p \"\$(dirname \"\$d\")\"; if [ -e \"\$d\" ] && ! cmp -s \"\$f\" \"\$d\"; then cp -a \"\$d\" \"\$d.bak-egpu-buddy-\$TS\"; fi; install -m \"\$(stat -c %a \"\$f\")\" \"\$f\" \"\$d\"; done
[ -f /etc/sudoers.d/steamos-egpu-buddy ] && { chmod 0440 /etc/sudoers.d/steamos-egpu-buddy; visudo -cf /etc/sudoers.d/steamos-egpu-buddy >/dev/null; }
chmod 0755 /usr/local/sbin/egpu-* /usr/local/sbin/nv-egpu-buddy-* /usr/local/bin/nv-egpu-offset-helper 2>/dev/null || true
mkdir -p /etc/nv-egpu-buddy /var/lib/nvegpu; echo '$VER' > /etc/nv-egpu-buddy/version
# reloads are conveniences (a reboot applies everything); they have nothing to talk to in a chroot/container
udevadm control --reload >/dev/null 2>&1 || true; udevadm trigger --subsystem-match=pci --action=change >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
for u in egpu-mount egpu-boot-enumerate egpu-conditional-session egpu-buddy-selfheal egpu-buddy-resume; do [ -f /etc/systemd/system/\$u.service ] && systemctl enable \$u.service >/dev/null; done
if [ -f /etc/pacman.conf ]; then
  # pin the NVIDIA userspace to the patched modules' version: append to an existing IgnorePkg line, never replace it
  for pk in nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia; do
    grep -qE '^IgnorePkg\\s*=.*\\b'\$pk'\\b' /etc/pacman.conf && continue
    if grep -qE '^IgnorePkg\\s*=' /etc/pacman.conf; then sed -i -E '0,/^IgnorePkg\\s*=.*/s//& '\$pk'/' /etc/pacman.conf; else sed -i -E '0,/^#\\s*IgnorePkg\\s*=.*/s//IgnorePkg = '\$pk'/' /etc/pacman.conf; fi
  done
fi
true
"
fi
rm -rf "$SYS_TMP"
userctl daemon-reload >/dev/null 2>&1 || true   # no user session bus (install at boot, chroot): the next login picks the units up
want core && { userctl enable egpu-display-failover.service; userctl enable --now egpu-wake-guard.service; } >/dev/null 2>&1 || true

# ---- gamescope with GBM scan-out (NVIDIA scan-out corruption fix) --------------------------------
if want gamescope; then
  PRE=${EGPU_PREBUILT_GAMESCOPE:-$ROOT/prebuilt/gamescope-gbm}
  if [ "$AS_ROOT" = 0 ] && command -v meson >/dev/null && command -v ninja >/dev/null && command -v cc >/dev/null && command -v cmake >/dev/null; then
    say "== building GBM-scanout gamescope from source (a few minutes)"
    HOME="$USER_HOME" "$ROOT/packaging/gamescope-gbm/build.sh" || echo "build failed; the session shim falls back to /usr/bin/gamescope"
  else
    # By DETECTION, not by distro name: take the first shipped build that actually RUNS here (every library resolves).
    # gamescope-gbm = built on CachyOS (needs a recent libstdc++); gamescope-gbm-steamos = built in a SteamOS 3.8 build root.
    # A system neither fits gets a build on the device after the driver step (SteamOS build root), else the distro gamescope.
    PICK=""; for c in "$PRE" "$ROOT"/prebuilt/gamescope-gbm*; do [ -x "$c/usr/bin/gamescope" ] || continue
      ldd "$c/usr/bin/gamescope" 2>/dev/null | grep -q 'not found' || { PICK=$c; break; }; done
    if [ -n "$PICK" ]; then
      say "== installing the prebuilt GBM-scanout gamescope that runs on this system ($(basename "$PICK"))"
      # atomic swap: a running gamescope keeps the old binary busy (ETXTBSY), so never copy over it in place
      G="$USER_HOME/.local/gamescope-gbm"; umkdir "$G"; rm -rf "$G/usr.new" "$G/usr.old"; cp -a "$PICK/usr" "$G/usr.new"
      [ -d "$G/usr" ] && mv "$G/usr" "$G/usr.old"; mv "$G/usr.new" "$G/usr"; rm -rf "$G/usr.old"; uown "$G"
    else
      say "== no shipped gamescope build runs on this system; it is built on the device after the driver step"
      NEED_GAMESCOPE_BUILD=1
    fi
  fi
fi

# ---- desktop app ----------------------------------------------------------------------------------
if want desktopapp; then
  say "== installing the EGPU Buddy desktop app"
  D="$USER_HOME/.local/share/egpu-buddy"; A="$USER_HOME/.local/share/applications"; umkdir "$D" "$USER_HOME/.local/bin" "$A" "$USER_HOME/.config/autostart"
  cp "$ROOT"/desktop-app/egpu-buddy "$ROOT"/desktop-app/egpu-buddy-server.py "$ROOT"/desktop-app/egpu-buddy-window.py "$ROOT"/desktop-app/egpu-buddy.qml "$ROOT"/desktop-app/index.html "$ROOT"/desktop-app/egpu-buddy.png "$D/"
  chmod +x "$D/egpu-buddy" "$D"/*.py; ln -sf "$D/egpu-buddy" "$USER_HOME/.local/bin/egpu-buddy"
  # menu: the app and "Safely Eject eGPU"; Plasma autostart: the tray icon; desktop folder (when there is one): both launchers
  for f in egpu-buddy egpu-safe-detach; do sed "s#/home/deck#$USER_HOME#g" "$ROOT/desktop-app/$f.desktop" > "$A/$f.desktop"; uown "$A/$f.desktop"
    if [ -d "$USER_HOME/Desktop" ]; then cp "$A/$f.desktop" "$USER_HOME/Desktop/$f.desktop"; chmod +x "$USER_HOME/Desktop/$f.desktop"; uown "$USER_HOME/Desktop/$f.desktop"; fi; done
  sed "s#/home/deck#$USER_HOME#g" "$ROOT/desktop-app/egpu-buddy-tray.desktop" > "$USER_HOME/.config/autostart/egpu-buddy-tray.desktop"
  uown "$D" "$USER_HOME/.local/bin/egpu-buddy" "$USER_HOME/.config/autostart/egpu-buddy-tray.desktop"
fi

# ---- Decky plugin --------------------------------------------------------------------------------
if want decky; then
  if [ -d "$USER_HOME/homebrew/plugins" ]; then
    say "== installing the EGPU Buddy Decky plugin"
    sudo rm -rf "$USER_HOME/homebrew/plugins/EGPU-Buddy"; sudo mkdir -p "$USER_HOME/homebrew/plugins/EGPU-Buddy"
    sudo cp -r "$ROOT/decky-plugin/egpu-buddy/dist" "$ROOT/decky-plugin/egpu-buddy/main.py" "$ROOT/decky-plugin/egpu-buddy/plugin.json" "$ROOT/decky-plugin/egpu-buddy/package.json" "$USER_HOME/homebrew/plugins/EGPU-Buddy/"
    sudo chown -R "$USER_NAME" "$USER_HOME/homebrew/plugins/EGPU-Buddy"; sudo systemctl restart plugin_loader.service 2>/dev/null || true
  else
    echo "Decky Loader not found (no ~/homebrew/plugins); skipping the plugin"
  fi
fi

# ---- SteamOS: tell the OS updater which of our /etc files to carry over ---------------------------------------------
# An update keeps /etc/systemd/system/*.service (+ wants) and whatever /etc/atomic-update.conf.d/*.conf lists
# (/usr/lib/rauc/atomic-update-keep.conf on Valve's image). Everything else in /etc is reset.
if [ "$MODE" = install ] && [ -d /etc/atomic-update.conf.d ]; then
  say "== SteamOS: registering the integration's /etc files with the OS updater"
  sudo tee /etc/atomic-update.conf.d/egpu-buddy.conf >/dev/null <<'KEEP'
/etc/extensions/**
/etc/default/grub.d/egpu-buddy.cfg
/etc/udev/rules.d/*egpu*.rules
/etc/modprobe.d/*egpu*.conf
/etc/modules-load.d/egpu-thunderbolt.conf
/etc/sudoers.d/steamos-egpu-buddy
/etc/nv-egpu-buddy/**
/etc/pacman.d/gnupg/**
KEEP
fi

# ---- patched NVIDIA driver (optional, Arch-based) ------------------------------------------------
if want driver; then
  PKGV="$(sed -n 's/^pkgver=//p' "$ROOT/packaging/nvidia-open-egpu/PKGBUILD")-$(sed -n 's/^pkgrel=//p' "$ROOT/packaging/nvidia-open-egpu/PKGBUILD")"
  if command -v pacman >/dev/null && [ "${EGPU_DRIVER_FORCE:-0}" != 1 ] && pacman -Q nvidia-open-egpu-dkms 2>/dev/null | grep -q "$PKGV\$"; then say "== patched driver package $PKGV already installed (EGPU_DRIVER_FORCE=1 to rebuild)"
  elif command -v steamos-readonly >/dev/null 2>&1; then
    # SteamOS: the system partition has ~870 MB free (measured on Valve's 3.8.14 image) and an update replaces it, so the
    # driver goes into a system extension on /home, built in a SteamOS build root there. Nothing is written to /usr.
    say "== SteamOS: building the patched NVIDIA driver into a system extension on /home (10-20 minutes the first time, mostly downloads)"
    sudo bash "$ROOT/packaging/nvidia-open-egpu/install-steamos-sysext.sh" || { DRIVER_FAILED=1; echo "warning: the driver extension was not built (see above); the rest is installed. Do NOT connect the eGPU until it is."; }
  elif command -v pacman >/dev/null; then say "== building the patched nvidia-open kernel modules (several minutes)"; EGPU_TARGET_USER="$USER_NAME" "$ROOT/packaging/nvidia-open-egpu/install-patched-nvidia.sh" || echo "warning: patched driver build failed; the stock driver stays (safe detach works, cable yank may hang)"; else echo "the patched driver package needs pacman (Arch-based distro); skipping"; fi
else
  say "== patched driver not installed. Without it a cable yank can hang the compositor (safe detach still works)."
fi

# ---- gamescope built on the device (only when no shipped build runs here; needs the SteamOS build root from the driver step)
if [ "${NEED_GAMESCOPE_BUILD:-0}" = 1 ]; then
  if [ -x /home/.egpu-buddy/buildroot/usr/bin/makepkg ]; then
    say "== building the GBM-scanout gamescope on this device (10-15 minutes, one time)"
    sudo bash "$ROOT/packaging/gamescope-gbm/build-steamos.sh" "$USER_NAME" || echo "warning: gamescope build failed; Game Mode on the eGPU will use the distro gamescope (picture corruption on NVIDIA above ~2560 px wide)"
  else echo "warning: no gamescope build for this system and no build environment; the distro gamescope is used (picture corruption on NVIDIA above ~2560 px wide)"; fi
fi

# ---- persistent payload + caches (what the self-heal service repairs from after an OS update) --------------
PERSIST="$USER_HOME/.local/share/steamos-egpu-buddy"
if [ "$(readlink -f "$ROOT")" != "$(readlink -f "$PERSIST")" ]; then
  say "== keeping a copy of this release in $PERSIST (self-heal source)"
  umkdir "$PERSIST"; rm -rf "$PERSIST"/{system,user,packaging,prebuilt,desktop-app,decky-plugin,docs,installer}
  cp -a "$ROOT"/{system,user,packaging,desktop-app,decky-plugin,docs,installer,install.sh,uninstall.sh,selfheal.sh,VERSION,README.md,TESTED.md,CREDITS.md,LICENSE} "$PERSIST"/ 2>/dev/null || true
  [ -d "$ROOT/prebuilt" ] && cp -a "$ROOT/prebuilt" "$PERSIST"/
fi
if command -v pacman >/dev/null 2>&1; then
  umkdir "$PERSIST/pkgcache" "$PERSIST/modcache/$(uname -r)"
  # cache the exact installed versions for an offline restore: pacman cache -> our build dir -> Arch Linux Archive
  for pk in nvidia-utils lib32-nvidia-utils bolt dkms nvidia-open-egpu-dkms; do v=$(pacman -Q "$pk" 2>/dev/null | awk '{print $2}' || true); [ -n "$v" ] || continue   # not installed (stock SteamOS) must not abort the install
    ls "$PERSIST"/pkgcache/"$pk"-"$v"-*.pkg.tar.* >/dev/null 2>&1 && continue
    f=$( { ls /var/cache/pacman/pkg/"$pk"-"$v"-*.pkg.tar.* "$USER_HOME"/.cache/egpu-buddy/driver-build/"$pk"-"$v"-*.pkg.tar.* 2>/dev/null || true; } | grep -v '\.sig$' | head -1 || true)
    if [ -n "$f" ]; then cp -n "$f" "$PERSIST/pkgcache/" 2>/dev/null || true
    else for arch in x86_64 any; do curl -fsSL -o "$PERSIST/pkgcache/$pk-$v-$arch.pkg.tar.zst" "https://archive.archlinux.org/packages/${pk:0:1}/$pk/$pk-$v-$arch.pkg.tar.zst" 2>/dev/null && break; rm -f "$PERSIST/pkgcache/$pk-$v-$arch.pkg.tar.zst"; done; fi
  done
  ls /usr/lib/modules/"$(uname -r)"/updates/dkms/nvidia*.ko* >/dev/null 2>&1 && cp -a /usr/lib/modules/"$(uname -r)"/updates/dkms/nvidia*.ko* "$PERSIST/modcache/$(uname -r)/" 2>/dev/null || true
fi
uown "$PERSIST"
if [ "${CMDLINE_MISSING:-0}" = 1 ]; then
  yes=${EGPU_AUTO_YES:-}; if [ -z "$yes" ] && [ -t 0 ]; then read -rp "Write the missing kernel parameters into the bootloader configuration now? (backup kept) [y/N] " r; [ "${r,,}" = y ] && yes=1; fi
  if [ "$yes" = 1 ]; then say "== writing the kernel parameters"; sudo /usr/local/sbin/egpu-kernel-cmdline --apply || echo "warning: could not write the kernel parameters; see README 'Kernel command line'"; fi
fi
# SteamOS has no NVIDIA driver of its own: without the extension the eGPU cannot work at all, so this is not a "done"
if [ "${DRIVER_FAILED:-0}" = 1 ]; then say "== NOT finished: the NVIDIA driver was not built. Keep the eGPU unplugged and run the install again (needs internet)."; exit 20; fi
say "== done. Reboot with the eGPU disconnected, then plug it in. Read TESTED.md before relying on any of this."
