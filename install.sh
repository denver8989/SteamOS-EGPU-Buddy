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
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
COMPONENTS=${EGPU_COMPONENTS:-core,session,gamescope,decky,bootpolicy,desktopapp}
MODE=install
for a in "$@"; do case "$a" in --check) MODE=check;; --with-driver) COMPONENTS="$COMPONENTS,driver";; --no-gamescope) COMPONENTS=${COMPONENTS//gamescope/};; *) echo "unknown option $a"; exit 1;; esac; done
want(){ case ",$COMPONENTS," in *",$1,"*) return 0;; *) return 1;; esac; }
say(){ printf '\033[1m%s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] && { echo "run as the normal user; sudo is requested where needed"; exit 1; }

# ---- preflight -----------------------------------------------------------------------------------
say "== preflight ($COMPONENTS)"
for c in sudo systemctl udevadm lspci; do command -v $c >/dev/null || { echo "missing $c"; exit 1; }; done
lspci -Dn | grep -qE '0300: 10de:' || echo "note: no NVIDIA GPU on the bus right now (fine, it is hot-pluggable)"
# runtime tools the scripts call (package names are Arch/SteamOS; Bazzite equivalents are similar)
miss=""; for c in setpci:pciutils modetest:libdrm fuser:psmisc jq:jq xxd:vim perl:perl python3:python qdbus6:qt6-tools kscreen-doctor:libkscreen xprop:xorg-xprop boltctl:bolt nvidia-smi:nvidia-utils; do
  command -v "${c%%:*}" >/dev/null 2>&1 || miss="$miss ${c%%:*}(${c#*:})"; done
[ -z "$miss" ] || echo "warning: missing tools, some paths will degrade:$miss"
STOCK=${STOCK_GAMESCOPE_SESSION:-}; [ -n "$STOCK" ] || for s in /usr/lib/steamos/gamescope-session /usr/bin/gamescope-session /usr/bin/gamescope-session-plus; do [ -f "$s" ] && { STOCK=$s; break; }; done
[ -n "$STOCK" ] || echo "warning: no gamescope-session script found; Game Mode pieces will be inert"
grep -qw nvidia-drm.modeset=1 /proc/cmdline || echo "warning: kernel cmdline lacks nvidia-drm.modeset=1 (see README 'Kernel command line')"

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

# ---- user files ----------------------------------------------------------------------------------
say "== installing user files"
for f in "${FILES[@]}"; do case "$f" in user/*) ;; *) continue;; esac
  d=$(map_dest "$f"); mkdir -p "$(dirname "$d")"
  if [ -e "$d" ] && differs "$f" "$d"; then cp -a "$d" "$d.bak-egpu-buddy-$TS"; fi
  templ < "$ROOT/$f" > "$d"; chmod --reference="$ROOT/$f" "$d" 2>/dev/null || true
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
mkdir -p /etc/nv-egpu-buddy /var/lib/nvegpu
udevadm control --reload; udevadm trigger --subsystem-match=pci --action=change >/dev/null 2>&1 || true
systemctl daemon-reload
for u in egpu-mount egpu-boot-enumerate egpu-conditional-session; do [ -f /etc/systemd/system/\$u.service ] && systemctl enable \$u.service >/dev/null; done
if [ -f /etc/pacman.conf ]; then grep -q '^IgnorePkg.*nvidia-utils' /etc/pacman.conf || sed -i 's/^#\\?IgnorePkg *=.*/IgnorePkg   = nvidia-utils lib32-nvidia-utils nvidia-open-dkms opencl-nvidia lib32-opencl-nvidia/' /etc/pacman.conf; fi
true
"
fi
rm -rf "$SYS_TMP"
systemctl --user daemon-reload
want core && systemctl --user enable egpu-display-failover.service >/dev/null 2>&1 || true

# ---- gamescope with GBM scan-out (NVIDIA scan-out corruption fix) --------------------------------
if want gamescope; then
  PRE=${EGPU_PREBUILT_GAMESCOPE:-$ROOT/prebuilt/gamescope-gbm}
  if command -v meson >/dev/null && command -v ninja >/dev/null && command -v cc >/dev/null && command -v cmake >/dev/null; then
    say "== building GBM-scanout gamescope from source (a few minutes)"
    HOME="$USER_HOME" "$ROOT/packaging/gamescope-gbm/build.sh" || echo "build failed; the session shim falls back to /usr/bin/gamescope"
  elif [ -d "$PRE/usr/bin" ]; then
    say "== no build toolchain; installing the prebuilt GBM-scanout gamescope (falls back to the distro gamescope if it cannot run here)"
    mkdir -p "$USER_HOME/.local/gamescope-gbm" && cp -a "$PRE/usr" "$USER_HOME/.local/gamescope-gbm/"
    ldd "$USER_HOME/.local/gamescope-gbm/usr/bin/gamescope" | grep -q 'not found' && echo "warning: prebuilt gamescope has missing libraries on this distro; the shim will fall back" || true
  else
    echo "no toolchain and no prebuilt gamescope; skipping (UI corruption stays on NVIDIA)"
  fi
fi

# ---- desktop app ----------------------------------------------------------------------------------
if want desktopapp; then
  say "== installing the EGPU Buddy desktop app"
  D="$USER_HOME/.local/share/egpu-buddy"; mkdir -p "$D" "$USER_HOME/.local/bin" "$USER_HOME/.local/share/applications"
  cp "$ROOT"/desktop-app/egpu-buddy "$ROOT"/desktop-app/egpu-buddy-server.py "$ROOT"/desktop-app/egpu-buddy-window.py "$ROOT"/desktop-app/index.html "$ROOT"/desktop-app/egpu-buddy.png "$D/"
  chmod +x "$D/egpu-buddy" "$D"/*.py; ln -sf "$D/egpu-buddy" "$USER_HOME/.local/bin/egpu-buddy"
  sed "s#/home/deck#$USER_HOME#g" "$ROOT/desktop-app/egpu-buddy.desktop" > "$USER_HOME/.local/share/applications/egpu-buddy.desktop"
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

# ---- patched NVIDIA driver (optional, Arch-based) ------------------------------------------------
if want driver; then
  if command -v pacman >/dev/null; then say "== building the patched nvidia-open kernel modules"; "$ROOT/packaging/nvidia-open-egpu/install-patched-nvidia.sh"; else echo "the patched driver package needs pacman (Arch-based distro); skipping"; fi
else
  say "== patched driver not installed. Without it a cable yank can hang the compositor (safe detach still works)."
fi

say "== done. Reboot, or log out and back into Game Mode. Read TESTED.md before relying on any of this."
