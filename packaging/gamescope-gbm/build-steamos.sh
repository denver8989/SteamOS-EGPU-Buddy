#!/usr/bin/env bash
# SteamOS: build the GBM-scanout gamescope INSIDE the SteamOS build root on /home (the one the driver build created), so it
# links against SteamOS's own libraries. Why: the prebuilt tree is compiled on CachyOS and needs a newer libstdc++
# (GLIBCXX_3.4.35) than SteamOS 3.8 has, so the session fell back to Valve's gamescope = no GBM scanout = the NVIDIA
# scanout corruption on the monitor (seen on a real device). Nothing is installed into the system: build dependencies go
# into the build root, the result goes to ~/.local/gamescope-gbm/usr (where the session shim looks).
#   build-steamos.sh <login user>
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
U=${1:?login user}; UH=$(getent passwd "$U" | cut -d: -f6); HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${EGPU_SYSEXT_BASE:-/home/.egpu-buddy}; BR=$BASE/buildroot; CACHE=$BASE/pkgcache
[ -x "$BR/usr/bin/makepkg" ] || { echo "no SteamOS build root at $BR (the driver step creates it)"; exit 2; }
P(){ pacman --root "$BR" --dbpath "$BR/var/lib/pacman" --cachedir "$CACHE" --gpgdir /etc/pacman.d/gnupg --config "$BASE/pacman.conf" --noconfirm "$@"; }
echo "== gamescope build dependencies into the build root"
P -Sy --needed git meson ninja cmake pkgconf glslang glm benchmark vulkan-headers vulkan-icd-loader wayland wayland-protocols \
  libdrm libx11 libxcb libxcomposite libxdamage libxext libxfixes libxkbcommon libxmu libxrender libxres libxtst libxxf86vm libxcursor \
  libinput libcap libdecor lcms2 luajit seatd sdl2 xcb-util-wm xcb-util-errors xorg-xwayland hwdata libei catch2 libdisplay-info >/dev/null
G="$UH/.local/gamescope-gbm"; S="$BASE/gamescope-src"; mkdir -p "$G" "$S" "$BR/opt/gs"; cp -a "$HERE"/. "$BR/opt/gs/"; chown -R "$U" "$G" "$S"
id -u builder >/dev/null 2>&1 || true
cat > "$BR/opt/gs/run.sh" <<EOS
#!/bin/bash
set -e; id builder >/dev/null 2>&1 || useradd -m -u 1000 builder
chown -R builder /src /prefix
runuser -u builder -- env HOME=/home/builder GAMESCOPE_GBM_SRC=/src GAMESCOPE_GBM_PREFIX=$G/usr bash /opt/gs/build.sh
EOS
chmod +x "$BR/opt/gs/run.sh"
echo "== compiling gamescope (GBM scanout) — several minutes"
# the prefix is compiled into the binary (script directory), so it is bind-mounted at its REAL path
systemd-nspawn -q --register=no --keep-unit --resolv-conf=copy-host -D "$BR" --bind="$S:/src" --bind="$G:/prefix" --bind="$G:$G" /bin/bash /opt/gs/run.sh
chown -R "$U" "$G"
if ldd "$G/usr/bin/gamescope" | grep -q 'not found'; then echo "the built gamescope still has unresolved libraries on the host:"; ldd "$G/usr/bin/gamescope" | grep 'not found'; exit 3; fi
echo "== $("$G/usr/bin/gamescope" --version 2>&1 | grep -o 'gamescope version [^ ]*' | head -1) installed in $G/usr"
