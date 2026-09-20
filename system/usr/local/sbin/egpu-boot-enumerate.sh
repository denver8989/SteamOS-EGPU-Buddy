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
log(){ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >>"$LOG" 2>&1; sync -d "$LOG" 2>/dev/null || true; }

# The flood lockout that used to live here is gone: it refused to bring the eGPU up at boot
# until the user ran egpu-rearm, which read as "the eGPU just stopped working". Unplugging the
# eGPU is the simple escape from a reset loop. The reset is still recorded in flood-history.
if [ ! -e /run/egpu-rearmed ] && dmesg 2>/dev/null | grep -qi 'data fabric sync flood'; then
  mkdir -p /var/lib/nvegpu 2>/dev/null; date '+%F %T' >> /var/lib/nvegpu/flood-history 2>/dev/null
  # THIS BOOT ONLY. The old flood lockout was persistent and needed a command to clear, which cost
  # more than it prevented and was removed. But a card that floods the fabric on bring-up takes the
  # machine down again the moment we touch it, and the result is a boot loop the user can only
  # escape by unplugging — which happened on an RTX 3080. So: skip the eGPU for one boot after a
  # flood, say so, and clear automatically. The next boot tries again with no intervention.
  log "the platform reset itself with the eGPU connected on the previous boot: skipping eGPU bring-up for THIS boot only"
  log "nothing to clear — the next boot tries again by itself. Press Attach to bring it up now."
  mkdir -p /run/nvegpu 2>/dev/null
  printf '{"state":"IDLE","message":"%s"}\n' "The system reset itself with the eGPU connected on the last boot, so the eGPU was left alone this boot. Press Attach to bring it up now, or just reboot — it tries again by itself." > /run/nvegpu/gm-status.json 2>/dev/null
  exit 0
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
  # by capability, not device id: see the note in egpu-hotplug-mount.sh
  for p in $(lspci -Dn 2>/dev/null | awk '$1 ~ /^[0-9a-f]{4}:00:/ && $2 ~ /^0604:/ {print $1}'); do
    lspci -s "$p" 2>/dev/null | grep -qiE 'usb4|thunderbolt' || continue
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
"$PRIV" pin-tunnel-ports on 2>/dev/null | while read -r _l; do log "tunnel port: $_l"; done
"$PRIV" mask-tunnel-ports 2>/dev/null | while read -r _l; do log "tunnel port: $_l"; done

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

# Protect against a cable pull BEFORE anything else happens. A machine that boots with the eGPU
# attached never ran the attach hook, so this was never applied — and unplugging reset the whole
# machine (a data-fabric sync flood, which looks like an instant power-off and reboot). Do it as
# soon as the eGPU is known to be there, so an unplug is survivable from that moment on.
"$PRIV" mask-surprise-down 2>/dev/null | while read -r _l; do log "$_l"; done

# ---- per-card quirks (same gate as the attach hook) --------------------------------------------
# Scoped to Ampere consumer ids (0x22xx-0x25xx = GA10x, RTX 30 series). Blackwell (the 5060 Ti this
# was built with, 0x2d04), Ada and Turing do not match and keep exactly the behaviour they were
# tested with. On a 3080 the FLR and the BAR resize leave the card answering config space but
# nothing on MMIO — the driver then reports it has "fallen off the bus".
egpu_is_ampere_consumer(){
  local id; id=$(cat "/sys/bus/pci/devices/$1/device" 2>/dev/null)
  case "$id" in 0x22??|0x23??|0x24??|0x25??) return 0 ;; esac
  return 1
}
EGPU_SKIP_FLR=0; EGPU_SKIP_RESIZE=0
log "card check: gpu='${gpu:-unset}' id=$(cat "/sys/bus/pci/devices/${gpu:-none}/device" 2>/dev/null || echo unreadable)"
if egpu_is_ampere_consumer "$gpu"; then
  # No FLR (it stops this card answering on MMIO), but DO try the bar: boot is the only moment the
  # kernel sizes bridge windows around what the card asks for. A hot-plugged card cannot grow an
  # already-assigned window — measured: "can't assign; no space" every time, however it was asked.
  # The back-down below covers the case where a big bar stops the driver initialising.
  EGPU_SKIP_FLR=1; EGPU_SKIP_RESIZE=0
  log "RTX 30 series (GA10x): lean boot bring-up — no FLR, BAR resize attempted (backs down if the driver refuses)"
fi

# FLR while driverless — NOT ReBAR. The manual egpu-attach.sh (the path that produced the known-good
# June captures: sane 154W power reading, GPU boosting) always did this; the lean boot path skipped it.
# The helper documents FLR as clearing "host-side first-init residue". A GPU inited without it carries
# stale state — and a stale/garbage POWER CALIBRATION is exactly the fault we're chasing (driver reports
# a fixed ~425W offset -> permanent SW power cap -> core clock clamped to 210MHz minimum, 2026-07-12).
# FLR only. ReBAR stays OFF (it wedges RmInitAdapter on this Strix Halo + RTX 3080).
if [ "$EGPU_SKIP_FLR" = 1 ]; then
  log "FLR skipped for this card"
elif [ ! -L "/sys/bus/pci/devices/$gpu/driver" ]; then
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
# Stop the kernel binding a driver behind our back for the whole of the BAR work. udev autoloads
# nvidia the moment the device appears and it kept winning the race between the steps below — the
# register write would land and the re-enumeration a fraction of a second later was refused with
# "GPU has a bound driver". Unbinding after the fact is worse than not binding at all, because the
# driver's own remove path can reset the card and take the BAR request with it. Restored to 1
# immediately after, and the driver is then loaded deliberately.
# Restored by a trap as well as inline, because leaving this at 0 would stop the kernel binding a
# driver to ANY pci device for the rest of the boot. Nothing may leave it off, including a failure
# part-way through the block below.
_autoprobe_was=$(cat /sys/bus/pci/drivers_autoprobe 2>/dev/null || echo 1)
trap 'echo "${_autoprobe_was:-1}" > /sys/bus/pci/drivers_autoprobe 2>/dev/null || true' EXIT HUP INT TERM
echo 0 > /sys/bus/pci/drivers_autoprobe 2>/dev/null || true
if [ "$EGPU_SKIP_RESIZE" = 1 ]; then
  log "BAR resize skipped for this card (BAR1 left as the firmware set it)"
elif [ -e "/sys/bus/pci/devices/$gpu/resource1_resize" ]; then
  # udev autoloads nvidia the moment the device appears, and it often wins the race to bind before
  # this point — especially on the cards where the FLR is skipped, because the FLR was what used to
  # keep the device busy long enough. A bound driver makes the kernel refuse the resize AND makes
  # the tunnel re-enumeration refuse outright, so the card silently keeps its firmware BAR and the
  # whole block used to be skipped without a word. Measured on an RTX 3080:
  #   nvidia 0000:65:00.0: BAR 1 [mem size 0x20000000 64bit pref]: can't assign; no space
  # the "nvidia" prefix instead of "pci" is the tell that the driver had already claimed it.
  # Take the card back here; it is bound again deliberately a few lines further down.
  # It is not enough to check once at the top: the resize retries below take several seconds and
  # udev binds the driver DURING them, so the re-enumeration that follows was refused every time
  # while the log showed a clean card at the start. Take the card back immediately before each step
  # that needs it.
  take_card_back() {
    [ -L "/sys/bus/pci/devices/$gpu/driver" ] || return 0
    log "the driver claimed the card — unbinding it before the BAR work"
    "$PRIV" unbind-nvidia >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do [ -L "/sys/bus/pci/devices/$gpu/driver" ] || break; sleep 1; done
    [ -L "/sys/bus/pci/devices/$gpu/driver" ] && { log "could not unbind it; BAR stays as the firmware set it"; return 1; }
    return 0
  }
  take_card_back || true
  # 16GiB or nothing. A PARTIAL resize is worse than none: on a real machine 4GiB was accepted and
  # then the driver would not create a DRM card at all, so a boot that used to work at 256MiB
  # ended with no eGPU. The sizes in between buy little and cost that risk.
  #
  # A device that has just had an FLR reads as a zombie until it finishes resetting and the helper
  # refuses to resize it, so wait for it to come back first. If 16GiB is refused (ENOSPC: the
  # bridge windows were sized at boot for the BARs the device already had), re-enumerate the
  # tunnel so the kernel sizes them again the way it does for a hot-plug, and ask once more.
  for _ in $(seq 1 15); do [ "$("$PRIV" status 2>/dev/null)" = "ALIVE" ] && break; sleep 1; done
  # the largest bar THIS card offers: 16GiB suits a 16GB card and does not exist on a 10GB one
  _max=$("$PRIV" resize-max 2>/dev/null); _max=${_max:-14}
  _first=0
  for _try in 1 2 3; do
    if _out=$("$PRIV" resize "$_max" 2>&1); then _first=1; break; fi
    sleep 2
  done
  if [ "$_first" = 1 ]; then
    log "BAR1 resized while driverless -> $(bar1_mib "$gpu")MiB"
  else
    log "BAR1 resize refused: ${_out:-no reason given}"
    # The kernel will not grow the bridge window directly above the card, and re-enumerating alone
    # does not help because on rescan the card still asks for the small BAR. So make the CARD ask
    # for its largest BAR first, then re-enumerate: the window is then sized around that request out
    # of the reserve above it (pci=hpmemprefsize). See rebar-set in the privileged helper.
    take_card_back || true
    if _rset=$("$PRIV" rebar-set "$_max" 2>&1); then
      log "asked the card directly for its largest BAR1 — $_rset"
      # endpoint mode: remove only the GPU, leave the switch and the tunnel LINK up, so the card
      # keeps the big BAR request it was just given. Removing the switch resets the link and the
      # request with it.
      if _rout=$("$PRIV" reenumerate-tunnel port 2>&1); then
        # log what it actually did, not just that it returned 0: the parking of the empty ports and
        # the removal are the steps that decide whether the big BAR can be placed
        printf '%s\n' "$_rout" | while read -r _rl; do [ -n "$_rl" ] && log "  re-enum: $_rl"; done
        for _ in $(seq 1 20); do [ -e "/sys/bus/pci/devices/$gpu" ] && break; sleep 1; done
        # The device node appears while the kernel is still assigning resources, so reading the BAR
        # straight away reports 0 and the back-down below then throws away a resize that was about
        # to succeed. Wait for the BAR to actually be placed.
        for _ in $(seq 1 15); do [ "$(bar1_mib "$gpu")" -gt 0 ] 2>/dev/null && break; sleep 1; done
        _mib_now=$(bar1_mib "$gpu")
        journalctl -k --since "-90 seconds" --no-pager 2>/dev/null |
          grep -iE "can.t assign|failed to assign|cannot fit|bridge window .*(pref|63:00|64:00)" |
          tail -8 | sed 's/^.*kernel: //' | while read -r _kl; do log "  kernel: $_kl"; done
        log "after re-enumeration: BAR1 ${_mib_now}MiB, window above the card $(cat /sys/bus/pci/devices/$gpu/resource 2>/dev/null | sed -n 2p | cut -c1-40)"
        # 0MiB means the kernel could not place it at all and the card has no usable BAR1: that is
        # worse than the stock size, so put the request back and re-enumerate once more.
        if [ "${_mib_now:-0}" -lt 512 ]; then
          log "the kernel still could not place the large BAR — restoring the stock request"
          take_card_back || true
          "$PRIV" rebar-set 8 >/dev/null 2>&1 || true
          "$PRIV" reenumerate-tunnel >/dev/null 2>&1 || true
          for _ in $(seq 1 20); do [ -e "/sys/bus/pci/devices/$gpu" ] && break; sleep 1; done
          log "restored: BAR1 $(bar1_mib "$gpu")MiB"
        fi
      else
        log "tunnel re-enumeration refused: ${_rout:-no reason given} — restoring the stock request"
        "$PRIV" rebar-set 8 >/dev/null 2>&1 || true
      fi
    else
      log "could not set the BAR1 request directly: ${_rset:-no reason given}"
    fi
  fi
  # never leave a partially resized BAR behind: it is the size that wedges the driver
  _mib=$(bar1_mib "$gpu")
  _full=$(( 1 << (_max > 20 ? 20 : _max) ))   # MiB the card's largest bar would give
  if [ "$_mib" -gt 256 ] && [ "$_mib" -lt "$_full" ]; then
    log "BAR1 ended at ${_mib}MiB — neither full nor stock, and that size wedges driver init: backing it down"
    "$PRIV" resize 8 >/dev/null 2>&1 || true
  fi
fi

echo "${_autoprobe_was:-1}" > /sys/bus/pci/drivers_autoprobe 2>/dev/null || true
trap - EXIT HUP INT TERM
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
  # stock size only: 4GiB is one of the sizes that wedges init, so falling back to it is no fallback
  "$PRIV" resize 8 >/dev/null 2>&1 || true
  # the failed init leaves residue behind; without clearing it the reload fails the same way, which
  # is how a machine ended up with no eGPU at all instead of the 256MiB one it would have had
  for _ in $(seq 1 10); do [ "$("$PRIV" status 2>/dev/null)" = "ALIVE" ] && break; sleep 1; done
  "$PRIV" reset-gpu >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do [ "$("$PRIV" status 2>/dev/null)" = "ALIVE" ] && break; sleep 1; done
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
