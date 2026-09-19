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
# Written the first time a real NVIDIA eGPU is seen on this machine; gates the
# bus-poking recovery below so it can never run on someone's plain dock.
SEEN=/var/lib/nvegpu/egpu-seen
log(){ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >>"$LOG" 2>&1; }

# The flood lockout that used to live here is gone: it refused to bring the eGPU up at boot
# until the user ran egpu-rearm, which read as "the eGPU just stopped working". Unplugging the
# eGPU is the simple escape from a reset loop. The reset is still recorded in flood-history.
if [ ! -e /run/egpu-rearmed ] && dmesg 2>/dev/null | grep -qi 'data fabric sync flood'; then
  mkdir -p /var/lib/nvegpu 2>/dev/null; date '+%F %T' >> /var/lib/nvegpu/flood-history 2>/dev/null
  log "note: the platform reset itself while the eGPU was connected on a previous boot (recorded; continuing)"
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
# A Thunderbolt device is not an eGPU: docks, displays and storage enclosures all
# look the same here. Only poke the bus (DPC clear + rescan) and spend 30s waiting
# if an eGPU has actually attached on this machine before. A dock-only machine
# then boots straight through instead of paying that wait at every boot.
if [ -z "$gpu" ] && [ ! -e "$SEEN" ]; then
  log "TB device present but no eGPU has ever attached on this machine — not poking the bus (a dock is not an enclosure)"
  exit 0
fi
if [ -z "$gpu" ]; then
  log "eGPU not enumerated — clear DPC (trigger+status), reauth, rescan"
  "$PRIV" dpc-off >/dev/null 2>&1 || true
  clear_dpc_status
  echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
  for _ in $(seq 1 30); do gpu=$(find_gpu || true); [ -n "$gpu" ] && break; sleep 1; done
fi
[ -n "$gpu" ] || { log "eGPU did not enumerate within timeout — iGPU boot"; exit 0; }
mkdir -p "$(dirname "$SEEN")" 2>/dev/null && : > "$SEEN" 2>/dev/null || true

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

# BAR1 can ONLY be resized while the GPU is driverless, which at boot means here. Skipping
# it used to leave BAR1 at 256MB for the whole boot — and Game Mode's readiness gate requires
# the resized BAR, so booting WITH the eGPU attached could never route the session to it: the
# wrapper waited 25s and fell back to the handheld screen. Found on a Legion Go 1 + RTX 5060 Ti.
# The old "no ReBAR at boot" rule came from one platform where a large BAR wedges the driver's
# init; that is handled below by DETECTION (if the driver does not come up, the BAR is backed
# down and reloaded) instead of by denying every machine the resize.
bar1_mib(){ python3 - "$1" <<'EOF' 2>/dev/null || echo 0
import sys
try:
    l=open("/sys/bus/pci/devices/%s/resource"%sys.argv[1]).read().splitlines()[1].split()
    s,e=int(l[0],16),int(l[1],16); print((e-s+1)//(1024*1024))
except Exception: print(0)
EOF
}
if [ ! -L "/sys/bus/pci/devices/$gpu/driver" ] && [ -e "/sys/bus/pci/devices/$gpu/resource1_resize" ]; then
  # A device that has just had an FLR reads as a zombie (config space all-ones) until it
  # finishes resetting, and the privileged helper refuses to resize a device in that state.
  # Resizing immediately after the FLR therefore failed EVERY time — silently, because the
  # first version of this loop threw the error away. Wait for it to come back, and log why
  # if it still will not resize.
  for _ in $(seq 1 15); do [ "$("$PRIV" status 2>/dev/null)" = "ALIVE" ] && break; sleep 1; done
  _rc=1
  for _c in 14 13 12; do
    if _out=$("$PRIV" resize "$_c" 2>&1); then
      log "BAR1 resized while driverless (size code $_c) -> $(bar1_mib "$gpu")MiB"; _rc=0; break
    fi
    log "BAR1 resize to size code $_c refused: ${_out:-no reason given}"
  done
  [ "$_rc" = 0 ] || log "BAR1 stays at $(bar1_mib "$gpu")MiB — the eGPU is used anyway, at lower bandwidth over Thunderbolt"
fi

log "eGPU at $gpu — load driver (FLR done, BAR1 $(bar1_mib "$gpu")MiB)"
"$PRIV" load-nvidia >/dev/null 2>&1 || true
[ -L "/sys/bus/pci/devices/$gpu/driver" ] || "$PRIV" bind-nvidia >/dev/null 2>&1 || true
"$PRIV" load-modeset >/dev/null 2>&1 || true
"$PRIV" load-drm >/dev/null 2>&1 || true
for _ in $(seq 1 15); do compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null && break; sleep 1; done

# Wedge protection for the resize above: on some platforms a large BAR stops the driver
# initialising at all. If no DRM card appeared, back the BAR down and load again, so those
# machines end up exactly where they were before rather than with no eGPU.
if ! compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null 2>&1 &&
   [ "$(bar1_mib "$gpu")" -gt 256 ]; then
  log "driver did not create a DRM card with the resized BAR — backing BAR1 down and retrying"
  "$PRIV" unbind-nvidia >/dev/null 2>&1 || true
  "$PRIV" resize 8 >/dev/null 2>&1 || "$PRIV" resize 12 >/dev/null 2>&1 || true
  "$PRIV" load-nvidia >/dev/null 2>&1 || true
  [ -L "/sys/bus/pci/devices/$gpu/driver" ] || "$PRIV" bind-nvidia >/dev/null 2>&1 || true
  "$PRIV" load-modeset >/dev/null 2>&1 || true
  "$PRIV" load-drm >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null && break; sleep 1; done
  log "after backing down: BAR1 $(bar1_mib "$gpu")MiB, DRM card $(compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null 2>&1 && echo yes || echo no)"
fi

if compgen -G "/sys/bus/pci/devices/$gpu/drm/card*" >/dev/null 2>&1; then
  # A monitor left in standby does not assert hot-plug, so its connector reads
  # "disconnected" and the dispatcher routes the session to the built-in screen —
  # which is not what someone who booted with the eGPU plugged in expects. Force a
  # probe ("detect" makes the driver ask the monitor over DisplayPort AUX / DDC): a
  # sleeping-but-powered monitor answers and the eGPU gets the session. A monitor
  # that is genuinely off still answers nothing, we boot on the built-in screen, and
  # switching it on fires a DRM hotplug that moves the session over by itself.
  _c=$(basename "$(ls -d "/sys/bus/pci/devices/$gpu"/drm/card[0-9]* 2>/dev/null | head -1)" 2>/dev/null)
  if [ -n "$_c" ]; then
    for _ in 1 2 3; do
      for _s in /sys/class/drm/"$_c"-*/status; do echo detect > "$_s" 2>/dev/null || true; done
      for _s in /sys/class/drm/"$_c"-*/status; do
        [ "$(cat "$_s" 2>/dev/null)" = connected ] && { log "eGPU output $(basename "$(dirname "$_s")") answered the probe"; break 2; }
      done
      sleep 2
    done
  fi
  log "OK — eGPU $gpu up WITH DRM card (lean); dispatcher can route the session"
else
  log "eGPU $gpu enumerated but driver/DRM card not ready — dispatcher falls back to iGPU"
fi
exit 0
