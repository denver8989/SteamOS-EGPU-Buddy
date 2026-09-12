#!/usr/bin/env bash
set -euo pipefail

# Stage KDE/KWin to render on the NVIDIA eGPU when the desktop is using one or
# more NVIDIA-owned external outputs. This deliberately does not choose outputs;
# KScreen/display-profile owns layout, including DP-only, HDMI-only, and DP+HDMI.

PANEL=${EGPU_PANEL_CONNECTOR:-eDP-1}
LOG=${EGPU_DISPLAY_LOG:-$HOME/.egpu-desktop-display.log}

log() {
  printf '%s [kwin-route] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true
}

detect_gpu_bdf() {
  local vendor_id=$1 dev vendor class card
  for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/vendor" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null || true)
    [ "$vendor" = "$vendor_id" ] || continue
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

panel_gpu_bdf() {
  local node dev
  for node in /sys/class/drm/card*-"$PANEL"; do
    [ -e "$node/status" ] || continue
    dev=$(readlink -f "$node/device/device" 2>/dev/null || true)
    [ -n "$dev" ] || continue
    basename "$dev"
    return 0
  done
  return 1
}

card_for_pci() {
  local pci=$1 card
  [ -n "$pci" ] || return 1
  for card in /sys/bus/pci/devices/"$pci"/drm/card*; do
    [ -e "$card" ] || continue
    printf '/dev/dri/%s\n' "${card##*/}"
    return 0
  done
  return 1
}

connected_outputs_for_pci() {
  local pci=$1 node base output device
  [ -n "$pci" ] || return 1
  for node in /sys/class/drm/card*-*; do
    [ -e "$node/status" ] || continue
    [ "$(cat "$node/status" 2>/dev/null)" = connected ] || continue
    base=${node##*/}
    output=$(printf '%s\n' "$base" | sed -E 's/^card[0-9]+-//')
    [ -n "$output" ] || continue
    [ "$output" != "$PANEL" ] || continue
    case "$output" in Writeback-*) continue ;; esac
    device=$(readlink -f "$node/device/device" 2>/dev/null || true)
    case "$device" in */"$pci") printf '%s\n' "$output" ;; esac
  done | sort -u
}

active_kscreen_outputs_for_pci() {
  local pci=$1 output device
  command -v kscreen-doctor >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  for output in $(kscreen-doctor --json 2>/dev/null | jq -r '.outputs[] | select(.connected == true and .enabled == true) | .name'); do
    [ "$output" != "$PANEL" ] || continue
    device=$(readlink -f /sys/class/drm/card*-"$output"/device/device 2>/dev/null | head -n 1 || true)
    case "$device" in */"$pci") printf '%s\n' "$output" ;; esac
  done | sort -u
}

kwin_renderer() {
  qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation 2>/dev/null |
    awk -F': ' '/OpenGL renderer string:/ { print $2; exit }'
}

stage() {
  local egpu_pci egpu_card igpu_pci igpu_card outputs active_outputs kwin_devices

  if [ -e "$HOME/.config/nv-egpu-buddy/disable-desktop-kwin-routing" ]; then
    log "disabled by user flag"
    return 0
  fi

  egpu_pci=${EGPU_PCI_BDF:-$(detect_gpu_bdf 0x10de)}
  egpu_card=$(card_for_pci "$egpu_pci" 2>/dev/null || true)
  outputs=$(connected_outputs_for_pci "$egpu_pci" | paste -sd, -)
  active_outputs=$(active_kscreen_outputs_for_pci "$egpu_pci" | paste -sd, -)

  if [ -z "$egpu_pci" ] || [ -z "$egpu_card" ] || [ -z "$outputs" ]; then
    log "no connected NVIDIA-owned external output; leaving KWin default"
    return 1
  fi

  igpu_pci=${IGPU_PCI:-$(panel_gpu_bdf || detect_gpu_bdf 0x1002)}
  igpu_card=$(card_for_pci "$igpu_pci" 2>/dev/null || true)
  kwin_devices="$egpu_card"
  [ -z "$igpu_card" ] || kwin_devices="$kwin_devices:$igpu_card"

  systemctl --user set-environment \
    KWIN_DRM_DEVICES="$kwin_devices" \
    VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json \
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json \
    __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json \
    __GLX_VENDOR_LIBRARY_NAME=nvidia \
    PROTON_ENABLE_NVAPI=1 \
    DXVK_ENABLE_NVAPI=1 \
    PROTON_HIDE_NVIDIA_GPU=0 >/dev/null 2>&1 || true

  log "staged NVIDIA-first KWin for connected=[$outputs] active=[${active_outputs:-none}] KWIN_DRM_DEVICES=$kwin_devices"
  printf 'KWIN_DRM_DEVICES=%s connected=%s active=%s renderer=%s\n' \
    "$kwin_devices" "$outputs" "${active_outputs:-none}" "$(kwin_renderer || true)"
}

clear() {
  systemctl --user unset-environment \
    KWIN_DRM_DEVICES VK_DRIVER_FILES VK_ICD_FILENAMES \
    __EGL_VENDOR_LIBRARY_FILENAMES __GLX_VENDOR_LIBRARY_NAME \
    PROTON_ENABLE_NVAPI DXVK_ENABLE_NVAPI PROTON_HIDE_NVIDIA_GPU >/dev/null 2>&1 || true
  log "cleared KWin routing environment"
}

status() {
  local egpu_pci outputs active_outputs
  egpu_pci=${EGPU_PCI_BDF:-$(detect_gpu_bdf 0x10de)}
  outputs=$(connected_outputs_for_pci "$egpu_pci" | paste -sd, -)
  active_outputs=$(active_kscreen_outputs_for_pci "$egpu_pci" | paste -sd, -)
  printf 'connected_nvidia_outputs=%s\n' "${outputs:-none}"
  printf 'active_nvidia_outputs=%s\n' "${active_outputs:-none}"
  printf 'kwin_renderer=%s\n' "$(kwin_renderer || true)"
  systemctl --user show-environment | grep -E '^(KWIN_DRM_DEVICES|VK_DRIVER_FILES|VK_ICD_FILENAMES|__EGL_VENDOR_LIBRARY_FILENAMES|__GLX_VENDOR_LIBRARY_NAME)=' || true
}

case "${1:-status}" in
  stage) stage ;;
  clear) clear ;;
  status) status ;;
  *)
    echo "Usage: $(basename "$0") stage|clear|status" >&2
    exit 2
    ;;
esac
