#!/usr/bin/env bash
# SteamOS-EGPU-Buddy installer (Arch-based handheld distros: CachyOS Deckify tested; SteamOS untested).
#
#   ./install.sh                 install everything except the patched NVIDIA driver package
#   ./install.sh --with-driver   also build + install the patched nvidia-open kernel modules (surprise-unplug fix)
#   ./install.sh --check         only report what differs between this repo and the live system
#   ./install.sh --no-gamescope  skip building the GBM-scanout gamescope
#
# Every replaced file is backed up next to itself as <file>.bak-egpu-buddy-<timestamp>.
# Paths that say /home/deck are rewritten to the current user's home; the sudoers rule to the current user.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
MODE=install; WITH_DRIVER=0; WITH_GAMESCOPE=1
for a in "$@"; do case "$a" in --check) MODE=check;; --with-driver) WITH_DRIVER=1;; --no-gamescope) WITH_GAMESCOPE=0;; *) echo "unknown option $a"; exit 1;; esac; done
say(){ printf '\033[1m%s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] && { echo "run as the normal user; sudo is requested where needed"; exit 1; }

# ---- preflight -----------------------------------------------------------------------------------
say "== preflight"
for c in sudo systemctl udevadm lspci pacman; do command -v $c >/dev/null || { echo "missing $c"; exit 1; }; done
if ! lspci -Dn | grep -qE '0300: 10de:'; then echo "note: no NVIDIA GPU on the bus right now (fine, it is hot-pluggable)"; fi
grep -q 'gamescope-session' /usr/bin/gamescope-session /usr/lib/steamos/gamescope-session 2>/dev/null || echo "warning: no gamescope-session found; Game Mode pieces will be inert"
for k in nvidia-drm.modeset=1; do grep -qw "$k" /proc/cmdline || echo "warning: kernel cmdline lacks $k (see README 'Kernel command line')"; done

# ---- file map ------------------------------------------------------------------------------------
# repo path -> destination (destination derived from the repo layout; user/ maps to $USER_HOME)
map_dest(){ case "$1" in system/*) echo "/${1#system/}";; user/*) echo "$USER_HOME/${1#user/}";; esac; }
mapfile -t FILES < <(cd "$ROOT" && find system user -type f | sort)

templ(){ # stdin -> stdout with home/user templating
  sed -e "s|/home/deck|$USER_HOME|g" -e "s|^deck ALL=|$USER_NAME ALL=|"
}
differs(){ # $1 repo file, $2 dest
  [ -f "$2" ] || return 0
  ! cmp -s <(templ < "$ROOT/$1") "$2"
}

if [ "$MODE" = check ]; then
  say "== check (repo vs live)"
  n=0; for f in "${FILES[@]}"; do d=$(map_dest "$f"); if [ ! -r "$(dirname "$d")" ]; then echo "UNREADABLE $d (root-only dir; installed by sudo)"; elif [ ! -e "$d" ]; then echo "MISSING  $d"; n=$((n+1)); elif differs "$f" "$d"; then echo "DIFFERS  $d"; n=$((n+1)); fi; done
  echo "$n file(s) differ or are missing"; exit 0
fi

# ---- install files -------------------------------------------------------------------------------
say "== installing user files"
for f in "${FILES[@]}"; do case "$f" in user/*) ;; *) continue;; esac
  d=$(map_dest "$f"); mkdir -p "$(dirname "$d")"
  if [ -e "$d" ] && differs "$f" "$d"; then cp -a "$d" "$d.bak-egpu-buddy-$TS"; fi
  templ < "$ROOT/$f" > "$d"; chmod --reference="$ROOT/$f" "$d" 2>/dev/null || true
done
chmod +x "$USER_HOME"/.local/bin/* "$USER_HOME/.local/lib/nv-egpu-buddy/gamescope-shim/gamescope"

say "== installing system files (sudo)"
SYS_TMP=$(mktemp -d); for f in "${FILES[@]}"; do case "$f" in system/*) ;; *) continue;; esac
  d=$(map_dest "$f"); mkdir -p "$SYS_TMP/$(dirname "$d")"; templ < "$ROOT/$f" > "$SYS_TMP/$d"; chmod --reference="$ROOT/$f" "$SYS_TMP/$d" 2>/dev/null || true
done
sudo bash -c "
set -e; TS=$TS
cd '$SYS_TMP'; find . -type f | while read -r f; do d=\"\${f#.}\"; mkdir -p \"\$(dirname \"\$d\")\"; if [ -e \"\$d\" ] && ! cmp -s \"\$f\" \"\$d\"; then cp -a \"\$d\" \"\$d.bak-egpu-buddy-\$TS\"; fi; install -m \"\$(stat -c %a \"\$f\")\" \"\$f\" \"\$d\"; done
chmod 0440 /etc/sudoers.d/steamos-egpu-buddy; visudo -cf /etc/sudoers.d/steamos-egpu-buddy >/dev/null
chmod 0755 /usr/local/sbin/egpu-* /usr/local/sbin/nv-egpu-buddy-* /usr/local/bin/nv-egpu-offset-helper
mkdir -p /etc/nv-egpu-buddy /var/lib/nvegpu
udevadm control --reload; udevadm trigger --subsystem-match=pci --action=change >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable egpu-mount.service egpu-boot-enumerate.service egpu-conditional-session.service >/dev/null
# pacman must not replace the driver bits this project pins
grep -q '^IgnorePkg.*nvidia-utils' /etc/pacman.conf || sed -i 's/^#\\?IgnorePkg *=.*/IgnorePkg   = nvidia-utils lib32-nvidia-utils nvidia-open-dkms opencl-nvidia lib32-opencl-nvidia/' /etc/pacman.conf
"
rm -rf "$SYS_TMP"
systemctl --user daemon-reload
systemctl --user enable egpu-display-failover.service >/dev/null 2>&1 || true

# ---- gamescope with GBM scan-out (NVIDIA scan-out corruption fix) --------------------------------
if [ "$WITH_GAMESCOPE" = 1 ]; then
  say "== building GBM-scanout gamescope (takes a few minutes; needs meson/ninja/gcc/cmake and the gamescope build deps)"
  if ! HOME="$USER_HOME" "$ROOT/packaging/gamescope-gbm/build.sh"; then
    echo "gamescope-gbm build failed; the session shim falls back to /usr/bin/gamescope (UI corruption returns on NVIDIA)"
  fi
fi

# ---- Decky plugin --------------------------------------------------------------------------------
if [ -d "$USER_HOME/homebrew/plugins" ]; then
  say "== installing the EGPU Buddy Decky plugin"
  sudo rm -rf "$USER_HOME/homebrew/plugins/EGPU-Buddy"; sudo mkdir -p "$USER_HOME/homebrew/plugins/EGPU-Buddy"
  sudo cp -r "$ROOT/decky-plugin/egpu-buddy/dist" "$ROOT/decky-plugin/egpu-buddy/main.py" "$ROOT/decky-plugin/egpu-buddy/plugin.json" "$ROOT/decky-plugin/egpu-buddy/package.json" "$USER_HOME/homebrew/plugins/EGPU-Buddy/"
  sudo chown -R "$USER_NAME" "$USER_HOME/homebrew/plugins/EGPU-Buddy"; sudo systemctl restart plugin_loader.service 2>/dev/null || true
else
  echo "Decky Loader not found (no ~/homebrew/plugins); skipping the plugin"
fi

# ---- patched NVIDIA driver (optional) ------------------------------------------------------------
if [ "$WITH_DRIVER" = 1 ]; then
  say "== building the patched nvidia-open kernel modules (surprise-unplug + external-GPU patches)"
  "$ROOT/packaging/nvidia-open-egpu/install-patched-nvidia.sh"
else
  say "== patched driver NOT installed (re-run with --with-driver). Without it a cable yank can hang the compositor."
fi

say "== done. Reboot, or log out and back into Game Mode. Read TESTED.md before relying on any of this."
