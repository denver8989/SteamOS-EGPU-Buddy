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
B=$(getent passwd "$U" | cut -d: -f6)/.cache/egpu-buddy/driver-build
rm -rf "$B"; mkdir -p "$B"; cp "$HERE"/PKGBUILD "$HERE"/*.patch "$HERE"/nvidia-egpu-hotplug.* "$B"/; [ "$(id -u)" = 0 ] && chown -R "$U" "$B"
if [ "$(id -u)" = 0 ]; then runuser -u "$U" -- bash -c "cd '$B' && makepkg -f --noconfirm"; else (cd "$B" && makepkg -f --noconfirm); fi
PKG=$(ls -t "$B"/nvidia-open-egpu-dkms-*.pkg.tar.* | head -1)
# --ask 4 answers "yes" to removing the conflicting stock nvidia-open / nvidia-open-dkms package
$R pacman -U --noconfirm --ask 4 "$PKG"
echo "installed: $(pacman -Q nvidia-open-egpu-dkms 2>/dev/null); dkms: $(dkms status 2>/dev/null | grep -i nvidia | head -1)"
echo "reboot to load the patched modules"
