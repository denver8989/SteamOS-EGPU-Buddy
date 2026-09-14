#!/bin/bash
# Build the patched nvidia-open-egpu-dkms package from this directory's PKGBUILD (stock source + the nine patches)
# and install it with pacman. Arch-based distros only. Works as root (Decky plugin / EGPU_TARGET_USER) or as a user
# with sudo; makepkg itself always runs as the login user. Needs the -headers package matching the running kernel.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "$(id -u)" = 0 ]; then U=${EGPU_TARGET_USER:-${SUDO_USER:-}}; [ -n "$U" ] && [ "$U" != root ] || { echo "running as root: set EGPU_TARGET_USER=<login user>"; exit 1; }; R=""; else U=$USER; R=sudo; fi
command -v makepkg >/dev/null && command -v pacman >/dev/null || { echo "makepkg/pacman not found: the patched driver is Arch-based only"; exit 1; }
K=$(uname -r); [ -f "/usr/lib/modules/$K/build/Makefile" ] || echo "warning: no kernel headers for $K; install the matching -headers package or the DKMS build will fail"
$R pacman -S --needed --noconfirm dkms base-devel >/dev/null
# the kernel modules and the userspace must be the same version: pin nvidia-utils (+lib32 if present) to the
# version this package is built for, from the Arch Linux Archive, and IgnorePkg (set by install.sh) keeps it there
PV=$(sed -n 's/^pkgver=//p' "$HERE/PKGBUILD"); ALA=https://archive.archlinux.org/packages
pin=""; for pkg in nvidia-utils lib32-nvidia-utils; do
  cur=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'); [ "$pkg" = lib32-nvidia-utils ] && [ -z "$cur" ] && continue   # lib32 only if already present
  [ "$cur" = "$PV-1" ] || pin="$pin $ALA/${pkg:0:1}/$pkg/$pkg-$PV-1-x86_64.pkg.tar.zst"
done
[ -z "$pin" ] || { echo "pinning NVIDIA userspace to $PV:$pin"; $R pacman -U --noconfirm --ask 4 $pin; }
UH=$(getent passwd "$U" | cut -d: -f6); B=$UH/.cache/egpu-buddy/driver-build
PERSIST=$UH/.local/share/steamos-egpu-buddy; mkdir -p "$PERSIST/pkgcache" "$PERSIST/srccache"; [ "$(id -u)" = 0 ] && chown -R "$U" "$PERSIST/pkgcache" "$PERSIST/srccache"
export SRCDEST=$PERSIST/srccache   # makepkg keeps the downloaded NVIDIA source tarball here (offline rebuilds)
rm -rf "$B"; mkdir -p "$B"; cp "$HERE"/PKGBUILD "$HERE"/*.patch "$HERE"/nvidia-egpu-hotplug.* "$B"/; [ "$(id -u)" = 0 ] && chown -R "$U" "$B"
if [ "$(id -u)" = 0 ]; then runuser -u "$U" -- bash -c "cd '$B' && makepkg -f --noconfirm"; else (cd "$B" && makepkg -f --noconfirm); fi
PKG=$(ls -t "$B"/nvidia-open-egpu-dkms-*.pkg.tar.* | head -1); cp -f "$PKG" "$PERSIST/pkgcache/" 2>/dev/null || true
# --ask 4 answers "yes" to removing the conflicting stock nvidia-open / nvidia-open-dkms package
$R pacman -U --noconfirm --ask 4 "$PKG"
echo "installed: $(pacman -Q nvidia-open-egpu-dkms 2>/dev/null); dkms: $(dkms status 2>/dev/null | grep -i nvidia | head -1)"
echo "reboot to load the patched modules"
