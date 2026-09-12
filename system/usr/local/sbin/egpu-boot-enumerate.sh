#!/usr/bin/env bash
# egpu-boot-enumerate — LEAN eGPU bring-up that runs BEFORE the session dispatcher
# (egpu-session-preflight), so the eGPU + its displays are visible when the
# dispatcher picks Desktop vs Game Mode. Works on EITHER USB4 port.
#
# CRITICAL: this does NOT do FLR or ReBAR. ReBAR-to-16GB wedges the NVIDIA
# RmInitAdapter init on this Strix Halo + RTX 3080 setup (confirmed 2026-06-21:
# lean load inits clean; ReBAR load fails 0x24:0x72:1603 even on a cold boot).
# ReBAR is only a gaming-perf tweak the desktop doesn't need. It loads the driver
# (bypassing the nvidia autoload blacklist via the helper) + nvidia_drm so the
# dispatcher can read connectors. No display config, no compositor restart (that
# mid-boot flip is what black-screened). No-op with no dock = clean iGPU boot.
#
# Escape hatch: `touch /etc/nv-egpu-buddy/skip-boot-enumerate`, or unplug + reboot.
set -u
PRIV=/usr/local/sbin/nv-egpu-buddy-privileged
LOG=/var/log/egpu-boot-enumerate.log
log(){ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >>"$LOG" 2>&1; }

# --- BOOTLOOP-BREAKER (2026-08-20): never re-load a flooding eGPU at boot -------
if [ ! -e /run/egpu-rearmed ]; then
  if [ -e /var/lib/nvegpu/flood-lockout ]; then
    log "FLOOD LOCKOUT active — skipping boot-enumerate. Run: sudo egpu-rearm"; exit 0
  fi
  if dmesg 2>/dev/null | grep -qi 'data fabric sync flood'; then
    mkdir -p /var/lib/nvegpu 2>/dev/null; date '+%F %T' > /var/lib/nvegpu/flood-lockout 2>/dev/null
    log "PREVIOUS BOOT FLOODED — set lockout, skipping boot-enumerate to break the loop. Run: sudo egpu-rearm"
    exit 0
  fi
fi

find_gpu(){
  local d
  for d in /sys/bus/pci/devices/0000:*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*) basename "$d"; return 0 ;; esac
  done
  return 1
}
dock_present(){
  local d
  for d in /sys/bus/thunderbolt/devices/*-*; do [ -e "$d/device_name" ] && return 0; done
  return 1
}
clear_dpc_status(){   # clear any latched DPC containment status on the USB4 root ports
  local p off v id nxt
  for p in $(lspci -D -d 1022:150a -n 2>/dev/null | awk '{print $1}'); do
    off=0x100
    for _ in $(seq 1 48); do
      v=$(setpci -s "$p" "$off".l 2>/dev/null) || break
      id=$(( 0x$v & 0xffff )); nxt=$(( (0x$v >> 20) & 0xffc ))
      if [ "$id" -eq 29 ]; then setpci -s "$p" "$(printf 0x%x $((off+0x08)))".w=0001 2>/dev/null; break; fi
      [ "$nxt" -eq 0 ] && break; off=$(printf 0x%x "$nxt")
    done
  done
}

[ -e /etc/nv-egpu-buddy/skip-boot-enumerate ] && { log "skip flag present — bypassing"; exit 0; }
log "=== boot-enumerate (lean) start ==="
dock_present || { log "no TB dock — iGPU boot"; exit 0; }

gpu=$(find_gpu || true)
if [ -z "$gpu" ]; then
  log "eGPU not enumerated — clear DPC (trigger+status), reauth, rescan"
  "$PRIV" dpc-off >/dev/null 2>&1 || true
  clear_dpc_status
  echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
  for _ in $(seq 1 30); do gpu=$(find_gpu || true); [ -n "$gpu" ] && break; sleep 1; done
fi
[ -n "$gpu" ] || { log "eGPU did not enumerate within timeout — iGPU boot"; exit 0; }

# FLR while driverless — NOT ReBAR. The manual egpu-attach.sh (the path that produced the known-good
# June captures: sane 154W power reading, GPU boosting) always did this; the lean boot path skipped it.
# The helper documents FLR as clearing "host-side first-init residue". A GPU inited without it carries
# stale state — and a stale/garbage POWER CALIBRATION is exactly the fault we're chasing (driver reports
# a fixed ~425W offset -> permanent SW power cap -> core clock clamped to 210MHz minimum, 2026-07-12).
# FLR only. ReBAR stays OFF (it wedges RmInitAdapter on this Strix Halo + RTX 3080).
if [ ! -L "/sys/bus/pci/devices/$gpu/driver" ]; then
  if "$PRIV" reset-gpu >/dev/null 2>&1; then log "FLR done (clears first-init residue)"
  else log "FLR unavailable — continuing"; fi
fi

log "eGPU at $gpu — load driver (FLR done, no ReBAR)"
"$PRIV" load-nvidia >/dev/null 2>&1 || true
[ -L "/sys/bus/pci/devices/$gpu/driver" ] || "$PRIV" bind-nvidia >/dev/null 2>&1 || true
"$PRIV" load-modeset >/dev/null 2>&1 || true
"$PRIV" load-drm >/dev/null 2>&1 || true
for _ in $(seq 1 15); do compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null && break; sleep 1; done

if compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null 2>&1; then
  log "OK — eGPU $gpu up WITH DRM card (lean); dispatcher can route the session"
else
  log "eGPU $gpu enumerated but driver/DRM card not ready — dispatcher falls back to iGPU"
fi
exit 0
