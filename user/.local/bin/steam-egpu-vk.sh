#!/usr/bin/env bash
# ============================================================================
# steam-egpu-vk.sh - launch Desktop Steam in the direct NVIDIA eGPU render path,
# but never with global gamescope/display-routing overrides.
#
# DXVK (D3D9/10/11) and vkd3d-proton (D3D12) read these env vars to pick which
# Vulkan adapter to render on. Games inherit them from the Steam client process,
# so this takes effect for games launched by a Steam client that was STARTED
# while the eGPU was present -> start/restart Steam AFTER docking.
#
# Do not set OUTPUT_CONNECTOR or KWIN_DRM_DEVICES here. Desktop eGPU gaming
# still needs NVIDIA-only Vulkan/EGL/GLX masking; otherwise Proton can fall back
# into an AMD/display copy path and reintroduce the USB4 bandwidth bottleneck.
# ============================================================================
unset OUTPUT_CONNECTOR KWIN_DRM_DEVICES

detect_nvidia_gpu() {
    local dev vendor class
    for dev in /sys/bus/pci/devices/*; do
        [ -r "$dev/vendor" ] || continue
        vendor=$(cat "$dev/vendor" 2>/dev/null || true)
        [ "$vendor" = "0x10de" ] || continue
        class=$(cat "$dev/class" 2>/dev/null || true)
        case "$class" in
            0x030000|0x030200) return 0 ;;
        esac
    done
    return 1
}

if detect_nvidia_gpu; then
    for _ in $(seq 1 20); do
        nvidia-smi -L 2>/dev/null | grep -q 'GPU ' && break
        sleep 1
    done
fi

if nvidia-smi -L 2>/dev/null | grep -q 'GPU '; then
    unset __NV_PRIME_RENDER_OFFLOAD __VK_LAYER_NV_optimus DRI_PRIME
    export DXVK_FILTER_DEVICE_NAME="NVIDIA"
    export VKD3D_FILTER_DEVICE_NAME="NVIDIA"
    export PROTON_ENABLE_NVAPI=1
    export DXVK_ENABLE_NVAPI=1
    export PROTON_HIDE_NVIDIA_GPU=0
    export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
    export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
    export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
fi
# -cef-force-gpu: Big Picture / client UI is CEF; Steam had latched it to software rendering
# (--disable-gpu + swiftshader = CPU-drawn UI = laggy BPM) after old GPU-process crashes.
# Forcing GPU puts the UI on the NVIDIA render node; on crash CEF just falls back to software.
exec /usr/lib/steam/steam -cef-force-gpu "$@"
