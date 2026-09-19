#!/usr/bin/env bash
# Build gamescope with GBM-allocated scanout buffers (NVIDIA scanout-corruption fix) into a private
# prefix that pacman never touches. Source: NightHammer1000/gamescope poc/gamescope-gbm-route, pinned.
# Why: NVIDIA backs Vulkan-allocated scanout dmabufs with scattered vidmem and nvidia-drm scans them
# out anyway (NVIDIA bug 5240452) -> striping/flicker above ~2560 px wide. GBM scanout allocations are
# forced contiguous by NVKMS, so routing gamescope's scanout through GBM avoids it. Gate at runtime with
# gamescope_drm_gbm_scanout=1 (env -> convar). Refs: forums.developer.nvidia.com/t/295314 posts 27-37.
set -euo pipefail
REPO=${GAMESCOPE_GBM_REPO:-https://github.com/NightHammer1000/gamescope.git}
BRANCH=${GAMESCOPE_GBM_BRANCH:-poc/gamescope-gbm-route}
COMMIT=${GAMESCOPE_GBM_COMMIT:-2bfc18c}          # 2026-08-20 "drm, rendervulkan: apply final review findings"
SRC=${GAMESCOPE_GBM_SRC:-$HOME/build/gamescope-gbm}
PREFIX=${GAMESCOPE_GBM_PREFIX:-$HOME/.local/gamescope-gbm/usr}   # SCRIPT_DIR is compiled in: prefix must be real
if [ ! -d "$SRC/.git" ]; then
  git clone --recursive --shallow-submodules --depth 100 -b "$BRANCH" "$REPO" "$SRC"
fi
git -C "$SRC" checkout -q "$COMMIT"
git -C "$SRC" submodule update --init --recursive --depth 1 >/dev/null 2>&1 || git -C "$SRC" submodule update --init --recursive
# local patches (always composite when GBM scanout is active; Steam's GAMESCOPE_COMPOSITE_FORCE=0 must not
# re-enable direct scanout of client Vulkan buffers -> that is the scattered-vidmem corruption again)
HERE=$(cd "$(dirname "$0")" && pwd)
for pf in "$HERE"/0*.patch; do
  [ -f "$pf" ] || continue
  git -C "$SRC" apply --check "$pf" >/dev/null 2>&1 && git -C "$SRC" apply "$pf" && echo "applied $(basename "$pf")" || echo "skip $(basename "$pf") (already applied or no longer applies)"
done
if [ ! -f "$SRC/build/build.ninja" ]; then
  meson setup "$SRC/build" "$SRC" --buildtype=release -Dprefix="$PREFIX" -Dpipewire=disabled -Davif_screenshots=disabled
else
  meson configure "$SRC/build" -Dprefix="$PREFIX" >/dev/null
fi
ninja -C "$SRC/build"
# a bundled subproject (v4l-utils, used where the system has no libv4l development files, e.g. the SteamOS build root)
# installs udev keymaps to an ABSOLUTE /usr path and fails without root: gamescope itself needs none of the subprojects' files
ninja -C "$SRC/build" install >/dev/null 2>&1 || meson install -C "$SRC/build" --skip-subprojects >/dev/null
"$PREFIX/bin/gamescope" --version 2>&1 | grep -o 'gamescope version [^ ]*'
grep -q "$PREFIX/share/gamescope/scripts" "$PREFIX/bin/gamescope" || { echo "SCRIPT_DIR mismatch" >&2; exit 1; }
echo "installed: $PREFIX/bin/gamescope (select via NV_EGPU_BUDDY_GAMESCOPE_BIN, enable with gamescope_drm_gbm_scanout=1)"
