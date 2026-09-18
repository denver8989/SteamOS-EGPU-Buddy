#!/bin/bash
# Build the patched nvidia-open-egpu-dkms package from this directory's PKGBUILD (stock source + the nine patches)
# and install it with pacman. Arch-based distros only. Works as root (Decky plugin / EGPU_TARGET_USER) or as a user
# with sudo; makepkg itself always runs as the login user. Needs the -headers package matching the running kernel.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "$(id -u)" = 0 ]; then U=${EGPU_TARGET_USER:-${SUDO_USER:-}}; [ -n "$U" ] && [ "$U" != root ] || { echo "running as root: set EGPU_TARGET_USER=<login user>"; exit 1; }; R=""; else U=$USER; R=sudo; fi
command -v makepkg >/dev/null && command -v pacman >/dev/null || { echo "makepkg/pacman not found: the patched driver is Arch-based only"; exit 1; }
PV=$(sed -n 's/^pkgver=//p' "$HERE/PKGBUILD"); ALA=https://archive.archlinux.org/packages
UH=$(getent passwd "$U" | cut -d: -f6); PERSIST=$UH/.local/share/steamos-egpu-buddy; mkdir -p "$PERSIST/pkgcache"
free_mb(){ df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# space: the userspace alone unpacks to ~930 MB and SteamOS's system partition is 5 GB. Refuse BEFORE touching anything.
need=1700; pacman -Q nvidia-utils 2>/dev/null | grep -q " $PV-1\$" && need=500   # userspace already in place: only toolchain + modules
have=$(free_mb /usr); have=${have:-0}
if [ "$have" -lt "$need" ]; then
  echo "NOT ENOUGH SPACE on the system partition for the NVIDIA driver: ${have} MB free on /usr, about ${need} MB needed."
  echo "Nothing was changed. (On SteamOS the system partition is fixed at 5 GB; the rest of EGPU Buddy is installed.)"; exit 3
fi

K=$(uname -r)
if [ ! -f "/usr/lib/modules/$K/build/Makefile" ]; then
  # no headers for the running kernel (stock SteamOS): the package that owns the kernel names its -headers sibling
  kp=$(pacman -Qqo "/usr/lib/modules/$K/vmlinuz" 2>/dev/null || pacman -Qqo "/usr/lib/modules/$K" 2>/dev/null | head -1 || true)
  [ -n "$kp" ] && { echo "installing kernel headers: ${kp}-headers"; $R pacman -S --needed --noconfirm "${kp}-headers" >/dev/null 2>&1 || true; }
  [ -f "/usr/lib/modules/$K/build/Makefile" ] || echo "warning: no kernel headers for $K; install the matching -headers package or the DKMS build will fail"
fi
$R pacman -S --needed --noconfirm dkms base-devel >/dev/null
# DKMS builds under /var/lib/dkms. On SteamOS /var is a 256 MB partition and the NVIDIA build peaks far above that.
# With an empty DKMS tree and less than 3 GB there, move the tree to the big partition (dkms >= 3.0 reads the drop-in).
dt=/var/lib/dkms; $R mkdir -p "$dt"
if [ "$(free_mb "$dt")" -lt 3000 ] && [ -z "$(ls -A "$dt" 2>/dev/null | grep -v '^dkms_dbversion$')" ]; then
  nt=/home/.egpu-buddy/dkms; [ -d /home/.steamos/offload ] && nt=/home/.steamos/offload/var/lib/egpu-buddy-dkms
  if [ "$(free_mb "$(dirname "$(dirname "$nt")")")" -ge 3000 ]; then
    $R mkdir -p "$nt" /etc/dkms/framework.conf.d
    printf '# SteamOS EGPU Buddy: /var is too small for the NVIDIA DKMS build\ndkms_tree="%s"\n' "$nt" | $R tee /etc/dkms/framework.conf.d/egpu-buddy.conf >/dev/null
    echo "DKMS tree moved to $nt (only $(free_mb "$dt") MB free under $dt)"
  else echo "warning: little space for the DKMS build under $dt and nowhere larger to move it"; fi
fi
# the kernel modules and the userspace must be the same version: pin nvidia-utils (+lib32 if present) to the
# version this package is built for, from the Arch Linux Archive, and IgnorePkg (set by install.sh) keeps it there
# The userspace must be exactly the patched modules' version. It comes from the Arch archive as CHECKSUMMED LOCAL FILES:
# installing by URL makes pacman verify the packager's signature against the local keyring, and an older distro
# snapshot (SteamOS 3.8) does not know 2026 packagers. Checksums were taken from the archive on 2026-09-19.
declare -A SHA=(
  [nvidia-utils-610.57.04-1-x86_64.pkg.tar.zst]=2ea5a57afc5104edd40dc4f4b1160f067f09ff1dad7e1bc588408087d1f7c0d0
  [lib32-nvidia-utils-610.57.04-1-x86_64.pkg.tar.zst]=9b87faccff1006fc14a10fadc91e3f1dba47ac2d60e31d354bc0eb938d0567e1
  [egl-wayland2-1.0.2-1-x86_64.pkg.tar.zst]=a891ac3f6c459185a54d463b87fc8924600893fd78d08b6e8bcd4a6b778c8d01
)
fetch_pinned(){ # <package name> <file name> -> path on stdout
  local f="$PERSIST/pkgcache/$2" want=${SHA[$2]:-}
  [ -n "$want" ] || { echo "no checksum recorded for $2" >&2; return 1; }
  [ -s "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ] || { rm -f "$f"; curl -fL --retry 3 -o "$f" "$ALA/${1:0:1}/$1/$2" >&2 || return 1; }
  [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ] || { echo "checksum mismatch on $2" >&2; rm -f "$f"; return 1; }
  echo "$f"; }

pin=()
cur=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}')
[ "$cur" = "$PV-1" ] || pin+=("$(fetch_pinned nvidia-utils "nvidia-utils-$PV-1-x86_64.pkg.tar.zst")")
# Arch's nvidia-utils 610 depends on egl-wayland2; SteamOS 3.8 has no such package. The archive build needs glibc 2.38
# and links only libdrm/libgbm/libwayland-client (checked), so it is installed alongside where the distro lacks it.
if ! pacman -Q egl-wayland2 >/dev/null 2>&1 && ! pacman -Si egl-wayland2 >/dev/null 2>&1; then
  pin+=("$(fetch_pinned egl-wayland2 egl-wayland2-1.0.2-1-x86_64.pkg.tar.zst)")
fi
# 32-bit userspace (32-bit games): when already present, or when there is room for its ~570 MB
l32=$(pacman -Q lib32-nvidia-utils 2>/dev/null | awk '{print $2}')
if [ "$l32" != "$PV-1" ] && { [ -n "$l32" ] || [ "$have" -ge $((need + 900)) ]; }; then
  pin+=("$(fetch_pinned lib32-nvidia-utils "lib32-nvidia-utils-$PV-1-x86_64.pkg.tar.zst")")
elif [ -z "$l32" ]; then echo "note: lib32-nvidia-utils left out (not enough room); 32-bit games will not see the NVIDIA GPU"; fi
for f in "${pin[@]}"; do [ -n "$f" ] && [ -s "$f" ] || { echo "could not fetch the pinned NVIDIA userspace; nothing was changed"; exit 4; }; done
# unsigned local files need LocalFileSigLevel=Optional (the default); a stricter pacman.conf gets a temporary copy
PCONF=(); if command -v pacman-conf >/dev/null && ! pacman-conf LocalFileSigLevel 2>/dev/null | grep -qiE 'Optional|Never'; then
  tc=$(mktemp); sed 's/^\[options\]/[options]\nLocalFileSigLevel = Optional/' /etc/pacman.conf > "$tc"; PCONF=(--config "$tc"); fi
[ ${#pin[@]} -eq 0 ] || { echo "pinning NVIDIA userspace to $PV: ${pin[*]##*/}"; $R pacman "${PCONF[@]}" -U --noconfirm --ask 4 "${pin[@]}"; }
B=$UH/.cache/egpu-buddy/driver-build
mkdir -p "$PERSIST/pkgcache" "$PERSIST/srccache"; [ "$(id -u)" = 0 ] && chown -R "$U" "$PERSIST/pkgcache" "$PERSIST/srccache"
export SRCDEST=$PERSIST/srccache   # makepkg keeps the downloaded NVIDIA source tarball here (offline rebuilds)
rm -rf "$B"; mkdir -p "$B"; cp "$HERE"/PKGBUILD "$HERE"/*.patch "$HERE"/nvidia-egpu-hotplug.* "$B"/; [ "$(id -u)" = 0 ] && chown -R "$U" "$B"
if [ "$(id -u)" = 0 ]; then runuser -u "$U" -- bash -c "cd '$B' && makepkg -f --noconfirm"; else (cd "$B" && makepkg -f --noconfirm); fi
PKG=$(ls -t "$B"/nvidia-open-egpu-dkms-*.pkg.tar.* | head -1); cp -f "$PKG" "$PERSIST/pkgcache/" 2>/dev/null || true
# --ask 4 answers "yes" to removing the conflicting stock nvidia-open / nvidia-open-dkms package
$R pacman "${PCONF[@]}" -U --noconfirm --ask 4 "$PKG"
echo "installed: $(pacman -Q nvidia-open-egpu-dkms 2>/dev/null); dkms: $(dkms status 2>/dev/null | grep -i nvidia | head -1)"
echo "reboot to load the patched modules"
