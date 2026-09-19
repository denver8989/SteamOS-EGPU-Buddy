#!/bin/bash
# ~/.config/plasma-workspace/env/00-egpu-free-nvidia-modeset.sh
# Sourced by startplasma(-wayland) BEFORE the compositor (kwin_wayland) starts.
#
# THIS FILE IS WHAT MAKES THE DESKTOP RUN ON THE eGPU ALONE. A session restart cannot inherit the routing any other way:
# KWin reads KWIN_DRM_DEVICES at startup, and the user manager's environment does not reliably survive a logout (on SteamOS
# it did not, and the desktop came back extended across both GPUs). Everything below is detected - GPUs by PCI vendor,
# cards and render nodes by sysfs, the panel connector via EGPU_PANEL_CONNECTOR - so it is not tied to one machine.
#
# GAME MODE -> DESKTOP BLACK-SCREEN FIX
# On the gamescope -> Plasma handoff with the eGPU attached, Steam
# (steamwebhelper) can still be ALIVE holding /dev/nvidia-modeset when KWin tries
# to start on the RTX 3080 -> "Failed to allocate NvKmsKapiDevice" -> black
# desktop -> SDDM timeout -> bounce back to Game Mode (user then had to reboot
# WITHOUT the eGPU to reach Desktop). steamos-session-select's `plasma` branch
# only fires an ASYNC `steam -shutdown` and does not wait, so the modeset device
# may not be free in time.
#
# Here, in the pre-compositor phase of EVERY Plasma start, we make sure Steam is
# fully gone (modeset released) BEFORE KWin starts. Strictly gated + time-capped:
#   * no-op unless the eGPU is physically present AND Steam is actually alive
#   * caps the blocking wait so it can never hang the session
#   * logs to the same file as the display autostart for one-shot post-mortem
# Steam is relaunched after login by ~/.config/autostart/steam.desktop, so this
# only moves its shutdown earlier in the handoff — it does not remove Steam.
# Only run in KDE Plasma session.
if [ "${XDG_CURRENT_DESKTOP:-}" != "KDE" ] && [ "${XDG_SESSION_DESKTOP:-}" != "KDE" ]; then
  exit 0
fi

_egpu_log="$HOME/.egpu-desktop-display.log"
_egpu_emlog() { printf '%s [env] %s\n' "$(date '+%F %T')" "$*" >> "$_egpu_log"; }

_egpu_detect_nvidia_gpu_bdf() {
  local dev vendor class card
  for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/vendor" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null || true)
    [ "$vendor" = "0x10de" ] || continue
    class=$(cat "$dev/class" 2>/dev/null || true)
    case "$class" in
      0x030000|0x030200)
        for card in "$dev"/drm/card*; do
          [ -e "$card" ] || continue
          basename "$dev"
          break
        done
        ;;
    esac
  done | sort -V | head -n 1
}

_egpu_card_for_pci() {
  local pci=$1 card
  [ -n "$pci" ] || return 1
  for card in /sys/bus/pci/devices/"$pci"/drm/card*; do
    [ -e "$card" ] || continue
    printf '/dev/dri/%s\n' "${card##*/}"
    return 0
  done
  return 1
}

_egpu_render_for_card() {
  local card=${1##*/} r
  for r in /sys/class/drm/"$card"/device/drm/renderD*; do [ -e "$r" ] && { printf '/dev/dri/%s\n' "${r##*/}"; return 0; }; done
  return 1
}
_egpu_panel_pci() {
  local panel=${EGPU_PANEL_CONNECTOR:-eDP-1} node dev
  for node in /sys/class/drm/card*-"$panel"; do
    [ -e "$node/status" ] || continue
    dev=$(readlink -f "$node/device/device" 2>/dev/null || true)
    [ -n "$dev" ] || continue
    basename "$dev"
    return 0
  done
  return 1
}

_egpu_detect_amd_gpu_bdf() {
  local dev vendor class card
  for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/vendor" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null || true)
    [ "$vendor" = "0x1002" ] || continue
    class=$(cat "$dev/class" 2>/dev/null || true)
    case "$class" in
      0x030000|0x030200)
        for card in "$dev"/drm/card*; do
          [ -e "$card" ] || continue
          basename "$dev"
          break
        done
        ;;
    esac
  done | sort -V | head -n 1
}

_egpu_connected_outputs_for_pci() {
  local pci=$1 panel=${EGPU_PANEL_CONNECTOR:-eDP-1} node base output device
  [ -n "$pci" ] || return 1
  for node in /sys/class/drm/card*-*; do
    [ -e "$node/status" ] || continue
    [ "$(cat "$node/status" 2>/dev/null)" = "connected" ] || continue
    [ -s "$node/modes" ] || continue
    base=${node##*/}
    output=$(printf '%s\n' "$base" | sed -E 's/^card[0-9]+-//')
    [ -n "$output" ] || continue
    [ "$output" != "$panel" ] || continue
    case "$output" in
      Writeback-*) continue ;;
    esac
    device=$(readlink -f "$node/device/device" 2>/dev/null || true)
    case "$device" in
      */"$pci") printf '%s\n' "$output" ;;
    esac
  done | sort -u
}

_egpu_stage_desktop_kwin() {
  local egpu_pci egpu_card igpu_pci igpu_card outputs kwin_devices

  if [ -e "$HOME/.config/nv-egpu-buddy/disable-desktop-kwin-routing" ]; then
    _egpu_emlog "Plasma pre-compositor: NVIDIA-first KWin disabled by user flag"
    return 0
  fi
  # DETACH MODE: pin KWin to the iGPU ONLY so it never opens the eGPU card.
  # egpu-noauto alone is NOT enough: "KWin default" still enumerates every DRM
  # device and mmaps card0, which makes egpu_detach.sh's gate-b guard refuse the
  # PCI-remove. egpu-safe-detach sets this flag, restarts the session, then removes.
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -e "$XDG_RUNTIME_DIR/egpu-detach-mode" ]; then
    local _dm_pci _dm_card
    _dm_pci=${IGPU_PCI:-$(_egpu_panel_pci || _egpu_detect_amd_gpu_bdf)}
    _dm_card=$(_egpu_card_for_pci "$_dm_pci" || true)
    if [ -n "$_dm_card" ]; then
      export KWIN_DRM_DEVICES="$_dm_card"
      export KWIN_RENDER_NODES="$(_egpu_render_for_card "$_dm_card")"   # KWin 6.7: never open the NVIDIA render node on the iGPU session
      # Also move RENDERING off NVIDIA. Without this KWin still opens /dev/nvidia0 and
      # /dev/nvidia-modeset via the NVIDIA EGL/Vulkan stack, pinning nvidia_drm's
      # refcount so the display modules cannot be unloaded and removal is refused.
      export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      for _dm_icd in /usr/share/vulkan/icd.d/radeon_icd.json /usr/share/vulkan/icd.d/radeon_icd.x86_64.json \
                     /usr/share/vulkan/icd.d/radeon_icd.i686.json; do
        [ -r "$_dm_icd" ] && { export VK_DRIVER_FILES="$_dm_icd" VK_ICD_FILENAMES="$_dm_icd"; break; }
      done
      unset PROTON_ENABLE_NVAPI DXVK_ENABLE_NVAPI PROTON_HIDE_NVIDIA_GPU
      _egpu_emlog "Plasma pre-compositor: DETACH MODE -> KWin pinned to iGPU only ($_dm_card), render stack = mesa"
    else
      _egpu_emlog "Plasma pre-compositor: DETACH MODE set but no iGPU card resolved"
    fi
    return 0
  fi

  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -e "$XDG_RUNTIME_DIR/egpu-noauto" ]; then
    _egpu_emlog "Plasma pre-compositor: egpu-noauto is set; leaving KWin default"
    return 0
  fi
  if [ ! -r /usr/share/vulkan/icd.d/nvidia_icd.json ] || [ ! -r /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
    _egpu_emlog "Plasma pre-compositor: NVIDIA userspace files missing; leaving KWin default"
    return 0
  fi

  egpu_pci=${EGPU_PCI_BDF:-$(_egpu_detect_nvidia_gpu_bdf)}
  egpu_card=$(_egpu_card_for_pci "$egpu_pci" || true)
  outputs=$(_egpu_connected_outputs_for_pci "$egpu_pci" | paste -sd, -)

  # eGPU outputs (or their DRM modes) can enumerate a few seconds AFTER this
  # pre-compositor phase when booting WITH the eGPU attached, so we'd otherwise
  # bail and KWin would start on AMD -> the USB4 cross-GPU crosstalk. If the NVIDIA
  # GPU is physically present but no output is ready yet, wait a bounded few
  # seconds for one. (Does NOT help hotplug-AFTER-login: the compositor is already
  # up on AMD by then and can't be rerouted live -> that case needs a re-login.)
  # Dockless boot is unchanged: no NVIDIA GPU -> no wait -> bails immediately.
  # Wait if the NVIDIA GPU is present but EITHER its DRM card node OR a connected output
  # isn't ready yet (both enumerate a few seconds after this phase on hotplug/boot-with-eGPU).
  # Previously only waited on outputs, so a not-yet-ready card node bailed instantly -> KWin on AMD.
  if [ -n "$egpu_pci" ] && { [ -z "$egpu_card" ] || [ -z "$outputs" ]; }; then
    local _waited=0 _max=${EGPU_KWIN_STAGE_WAIT:-8}
    while [ "$_waited" -lt "$_max" ]; do
      sleep 1; _waited=$((_waited + 1))
      egpu_card=$(_egpu_card_for_pci "$egpu_pci" || true)
      outputs=$(_egpu_connected_outputs_for_pci "$egpu_pci" | paste -sd, -)
      if [ -n "$egpu_card" ] && [ -n "$outputs" ]; then
        _egpu_emlog "Plasma pre-compositor: NVIDIA card+output ready after ${_waited}s wait"
        break
      fi
    done
  fi

  if [ -z "$egpu_pci" ] || [ -z "$egpu_card" ]; then
    # NVIDIA card ABSENT (never attached, safe-detached, or SURPRISE-yanked): the user-manager env may still
    # carry the last NVIDIA-first staging (KWIN_DRM_DEVICES=cardN + nvidia EGL) -> KWin would fail to open the
    # node and the relaunched session goes black. Pin explicitly to the iGPU + mesa instead.
    local _ab_pci _ab_card
    _ab_pci=${IGPU_PCI:-$(_egpu_panel_pci || _egpu_detect_amd_gpu_bdf)}
    _ab_card=$(_egpu_card_for_pci "$_ab_pci" || true)
    if [ -n "$_ab_card" ]; then
      export KWIN_DRM_DEVICES="$_ab_card"
      export KWIN_RENDER_NODES="$(_egpu_render_for_card "$_ab_card")"   # KWin 6.7: never open the NVIDIA render node on the iGPU session
      export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      for _ab_icd in /usr/share/vulkan/icd.d/radeon_icd.json /usr/share/vulkan/icd.d/radeon_icd.x86_64.json /usr/share/vulkan/icd.d/radeon_icd.i686.json; do
        [ -r "$_ab_icd" ] && { export VK_DRIVER_FILES="$_ab_icd" VK_ICD_FILENAMES="$_ab_icd"; break; }
      done
      unset PROTON_ENABLE_NVAPI DXVK_ENABLE_NVAPI PROTON_HIDE_NVIDIA_GPU
      _egpu_emlog "Plasma pre-compositor: NVIDIA card absent -> KWin pinned to iGPU only ($_ab_card), render stack = mesa"
    else
      _egpu_emlog "Plasma pre-compositor: NVIDIA card absent and no iGPU card resolved; leaving KWin default"
    fi
    return 0
  fi
  if [ -z "$outputs" ]; then
    _egpu_emlog "Plasma pre-compositor: NVIDIA card present but no connected external output; leaving KWin default"
    return 0
  fi

  igpu_pci=${IGPU_PCI:-$(_egpu_panel_pci || _egpu_detect_amd_gpu_bdf)}
  igpu_card=$(_egpu_card_for_pci "$igpu_pci" || true)
  kwin_devices="$egpu_card"
  # NVIDIA-ONLY by default (2026-07-02): appending the iGPU put AMD inside the session -> multi-GPU
  # sync overhead + USB4 copyback (the user-visible degradation), AND a KWin-mastered AMD card blocks
  # the fbcon VT-lifeboat on surprise removal. AMD now stays UNMASTERED: zero crosstalk + the kernel
  # console (getty@tty3 / emergency-console) remains available on eDP as the yank escape hatch.
  # Legacy NVIDIA-first-with-AMD: touch ~/.config/nv-egpu-buddy/kwin-include-igpu
  if [ -e "$HOME/.config/nv-egpu-buddy/kwin-include-igpu" ] && [ -n "$igpu_card" ]; then
    kwin_devices="$kwin_devices:$igpu_card"
    _egpu_emlog "Plasma pre-compositor: kwin-include-igpu flag set -> appending $igpu_card"
  fi

  export KWIN_DRM_DEVICES="$kwin_devices"
  export KWIN_RENDER_NODES="$(_egpu_render_for_card "$egpu_card")"   # NVIDIA render node only (no AMD crosstalk, no stale iGPU pin)
  export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
  export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  export PROTON_ENABLE_NVAPI=1
  export DXVK_ENABLE_NVAPI=1
  export PROTON_HIDE_NVIDIA_GPU=0
  export DXVK_HDR=0  # 2026-08-21 was re-enabling HDR on eGPU desktop -> gamescope HDR corruption (NVIDIA bug 5240452)
  unset __NV_PRIME_RENDER_OFFLOAD __VK_LAYER_NV_optimus DRI_PRIME

  _egpu_emlog "Plasma pre-compositor: NVIDIA-first KWin staged for $outputs using KWIN_DRM_DEVICES=$KWIN_DRM_DEVICES"
}

_egpu_pci=${EGPU_PCI_BDF:-$(_egpu_detect_nvidia_gpu_bdf)}
_egpu_stage_desktop_kwin

if [ -n "$_egpu_pci" ] && [ -e "/sys/bus/pci/devices/$_egpu_pci" ] && { pgrep -x steamwebhelper >/dev/null 2>&1 || pgrep -x steam >/dev/null 2>&1; }; then
  _egpu_emlog "Plasma pre-compositor: eGPU present + Steam alive -> freeing /dev/nvidia-modeset before KWin"
  /usr/bin/steam -shutdown >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    pgrep -x steamwebhelper >/dev/null 2>&1 || pgrep -x steam >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x steamwebhelper >/dev/null 2>&1 || pgrep -x steam >/dev/null 2>&1; then
    _egpu_emlog "Steam still alive after ~15s -> SIGKILL backstop"
    pkill -9 -x steamwebhelper 2>/dev/null || true
    pkill -9 -x steam 2>/dev/null || true
    sleep 1
  fi
  _egpu_emlog "Steam down; /dev/nvidia-modeset should now be free for KWin"
fi
unset _egpu_pci _egpu_log
unset -f _egpu_render_for_card _egpu_emlog _egpu_detect_nvidia_gpu_bdf _egpu_card_for_pci _egpu_panel_pci _egpu_detect_amd_gpu_bdf _egpu_connected_outputs_for_pci _egpu_stage_desktop_kwin 2>/dev/null || true
