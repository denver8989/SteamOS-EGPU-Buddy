#!/usr/bin/env bash
# egpu-hotplug-mount — auto-mount the eGPU when its Thunderbolt dock links AFTER
# boot. The dock on this hardware does not establish the TB link at cold boot; it
# only links on a physical replug, which happens after egpu-boot-enumerate has
# already run. A udev rule launches this on the dock's TB device add.
#
# Full mount: clear DPC (trigger + the LATCHED status — the bit that was containing
# the tunnel and causing zombies), reauth the dock to form the tunnel, rescan, lean
# load (NO FLR/ReBAR — ReBAR wedges RmInitAdapter on this Strix Halo + RTX 3080),
# then load the display stack so a session can use it.
set -u
PRIV=/usr/local/sbin/nv-egpu-buddy-privileged
LOG=/var/log/egpu-hotplug-mount.log
# fdatasync every line: a fabric flood is an instant reset, and it took the unflushed tail of this
# log with it every time — the lines that would have shown which step caused it
log(){ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >>"$LOG" 2>&1; sync -d "$LOG" 2>/dev/null || true; }

# kscreen-doctor is a Qt program. With no WAYLAND_DISPLAY (and no DISPLAY) it cannot create a
# platform plugin, Qt calls qFatal(), and the process ABORTS before doing anything at all:
#   Process 134846 (kscreen-doctor) of user 1000 dumped core.
#   QMessageLogger::fatal -> QGuiApplicationPrivate::createEventDispatcher
# Every call in this hook used to pass XDG_RUNTIME_DIR only, so on a DESKTOP hot-plug the external
# output was never enabled: the connector read "connected", KWin left it "enabled=disabled", and
# the monitor stayed dark while everything else looked healthy. egpu-reattach always passed the
# display variables, which is why a re-attach lit the screen and a hot-plug did not.
# The socket is discovered rather than assumed — it is usually wayland-0, but not always.
# It also refuses to run at all when there is no compositor socket yet. Calling it anyway does not
# fail gracefully — Qt aborts and dumps core, which is noise in the journal that looks like a crash
# in our own code, and is what the coredump after a surprise removal actually was (the yank took
# the session with it, then recovery called this with nothing to talk to).
ksd() {
  local _wd _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    _wd=$(basename "$(ls -1 /run/user/1000/wayland-[0-9] 2>/dev/null | head -1)" 2>/dev/null)
    [ -n "$_wd" ] && break
    sleep 1
  done
  [ -n "$_wd" ] || { log "no Wayland session socket — skipping kscreen-doctor $*"; return 1; }
  runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    WAYLAND_DISPLAY="$_wd" DISPLAY=:0 \
    kscreen-doctor "$@"
}
exec 9>/run/egpu-hotplug-mount.lock 2>/dev/null || true
flock -n 9 2>/dev/null || { log "another instance running — skip"; exit 0; }

find_gpu(){
  local d
  for d in /sys/bus/pci/devices/0000:*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*) basename "$d"; return 0 ;; esac
  done
  return 1
}
authorized_dock(){
  local tb
  for tb in /sys/bus/thunderbolt/devices/*-*; do
    [ -e "$tb/device_name" ] && [ "$(cat "$tb/authorized" 2>/dev/null)" = "1" ] && { printf '%s\n' "$tb"; return 0; }
  done
  return 1
}
# Root ports WITHOUT Downstream Port Containment (e.g. AMD Phoenix 1022:14ef, Legion Go 1): when the cable is pulled the
# port raises an uncorrectable error (Data Link Protocol is FATAL by default) and the platform answers with a data-fabric
# sync flood = instant reset ("Previous system reset reason: an uncorrected error caused a data fabric sync flood event",
# seen on a real device). A lost link on a hot-plug port is not an error worth a reset: mask every uncorrectable error the
# port LETS us mask and make them non-fatal, then read back what the hardware accepted (some bits are hardwired; on that
# port Surprise Down cannot even be generated: LnkCap Surprise-). By capability, never by device id; ports that have DPC
# (Legion Go 2) are left exactly as they are. The kernel runs with pci=noaer, so nothing consumes these reports anyway.
mask_surprise_down(){   # $1 = GPU BDF — the logic lives in the privileged helper so boot-enumerate can use it too
  "$PRIV" mask-surprise-down >/dev/null 2>&1 && log "surprise-removal protection applied to the eGPU's root port"
}
# USB4/Thunderbolt tunnel root ports, found by what they ARE, not by device id. This used to be
# gated to 1022:150a (Strix Halo), so on every other machine — including the Legion Go 1, which is
# Phoenix — the DPC clear silently did nothing. On Strix Halo the SECOND USB4 port needed exactly
# this to form a PCIe tunnel at all, so a device-id gate meant "works on one port of one machine".
_tunnel_root_ports(){
  local p
  # HOST root ports only (bus 00). Matching any tunnel bridge also caught the enclosure's own
  # Thunderbolt switch, which is not ours to poke.
  for p in $(lspci -Dn 2>/dev/null | awk '$1 ~ /^[0-9a-f]{4}:00:/ && $2 ~ /^0604:/ {print $1}'); do
    lspci -s "$p" 2>/dev/null | grep -qiE 'usb4|thunderbolt' || continue
    printf '%s\n' "$p"
  done
}
clear_dpc(){   # clear latched DPC status (write-1) + disable trigger on every USB4/TB tunnel root port
  local p off v id nxt c
  for p in $(_tunnel_root_ports); do
    off=0x100
    for _ in $(seq 1 48); do
      v=$(setpci -s "$p" "$off".l 2>/dev/null) || break
      id=$(( 0x$v & 0xffff )); nxt=$(( (0x$v >> 20) & 0xffc ))
      if [ "$id" -eq 29 ]; then
        setpci -s "$p" "$(printf 0x%x $((off+0x08)))".w=0001 2>/dev/null          # clear latched status
        c=$(setpci -s "$p" "$(printf 0x%x $((off+0x06)))".w 2>/dev/null)
        setpci -s "$p" "$(printf 0x%x $((off+0x06)))".w=$(printf %04x $(( 0x$c & ~0x3 ))) 2>/dev/null  # disable trigger
        log "DPC cleared on tunnel root port $p"
        break
      fi
      [ "$nxt" -eq 0 ] && break; off=$(printf 0x%x "$nxt")
    done
  done
}

# A hardware reset while the eGPU was connected (AMD "data fabric sync flood") used to set a
# persistent LOCKOUT that refused every later attach until the user ran egpu-rearm. That was
# removed: the loop it guarded against is escaped by unplugging the eGPU — one action, obvious
# to anyone holding the device — while the lockout itself caused silent non-attaches, a boot
# that stalled for two and a half minutes, and no way to tell what was wrong. It cost more than
# it prevented. The reset is still RECORDED, because that record is evidence this machine resets
# when the eGPU link drops, and the UI uses it to keep a standing "always Safe Detach" note.
rm -f /var/lib/nvegpu/flood-lockout 2>/dev/null   # stale state from the version that had a lockout
if dmesg 2>/dev/null | grep -qi 'data fabric sync flood'; then
  mkdir -p /var/lib/nvegpu 2>/dev/null
  date '+%F %T' >> /var/lib/nvegpu/flood-history 2>/dev/null
  log "note: the platform reset itself while the eGPU was connected on a previous boot (recorded; attach continues)"
fi

log "=== hotplug-mount triggered ==="
# A Thunderbolt/USB4 "add" is not an eGPU: docks, displays and storage enclosures
# fire the same event. We cannot tell them apart before the PCIe tunnel forms, so
# we try once per device and then remember the answer. A device that has already
# been through the full bring-up without ever producing a GPU is left completely
# alone from then on — no authorize, no de-authorize/re-authorize (which would
# drop a dock and any display on it), no DPC poke, no bus rescan.
# Three strikes, not one: a real enclosure can fail to produce its GPU on a given
# plug (the PCIe tunnel is slow and racy, and can take minutes), and writing one
# off after a single miss would silently stop the software working. Any successful
# attach clears the list entirely.
NOT_EGPU=/var/lib/nvegpu/not-egpu   # lines: "<thunderbolt unique_id> <failed bring-ups>"
STRIKES=3
tb_uids(){ local tb; for tb in /sys/bus/thunderbolt/devices/*-*; do
    [ -e "$tb/device_name" ] && cat "$tb/unique_id" 2>/dev/null; done; }
strikes_for(){   # awk cannot open a file that is not there, and would print nothing at all
  [ -s "$NOT_EGPU" ] || { printf '0\n'; return 0; }
  awk -v u="$1" '$1==u{print $2+0; found=1} END{if(!found) print 0}' "$NOT_EGPU" 2>/dev/null; }
known_not_egpu(){
  local uid any=1
  for uid in $(tb_uids); do
    any=0
    [ "$(strikes_for "$uid")" -ge "$STRIKES" ] || return 1
  done
  return $any   # no Thunderbolt device at all => not "known", let the normal path run
}
remember_not_egpu(){
  local uid n rest
  mkdir -p /var/lib/nvegpu 2>/dev/null || return 0
  for uid in $(tb_uids); do
    n=$(( $(strikes_for "$uid") + 1 ))
    rest=$(grep -v "^$uid " "$NOT_EGPU" 2>/dev/null || true)
    { [ -z "$rest" ] || printf '%s\n' "$rest"; printf '%s %s\n' "$uid" "$n"; } > "$NOT_EGPU" 2>/dev/null || true
    [ "$n" -lt "$STRIKES" ] || log "$uid produced no GPU $n times — treating it as a dock, not an enclosure (cleared by any successful attach, or: rm $NOT_EGPU)"
  done
}
# A deliberate press of Attach always tries, whatever we think we learned.
if [ "${1:-}" = "--manual" ]; then
  rm -f "$NOT_EGPU" 2>/dev/null || true
elif [ -z "$(find_gpu || true)" ] && known_not_egpu; then
  log "only known non-eGPU Thunderbolt devices are attached — nothing to do (press Attach to override)"
  exit 0
fi
gate_fail(){ log "NOT attaching: $1"; mkdir -p /run/nvegpu; printf '{"state":"FAILED","message":"%s"}\n' "$1" > /run/nvegpu/gm-status.json; exit 0; }
# wait for boltd to authorize the dock (udev add fires before authorization)
dock=""
for _ in $(seq 1 6); do dock=$(authorized_dock || true); [ -n "$dock" ] && break; sleep 1; done
if [ -z "$dock" ]; then
  # first-ever connection on a fresh machine: boltd only auto-authorizes with an IOMMU policy, and Game Mode has no
  # consent prompt. With security level "user" (or "none") root may authorize the device directly, as boltd would.
  sec=$(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null)
  for tb in /sys/bus/thunderbolt/devices/*-*; do
    [ -e "$tb/device_name" ] && [ "$(cat "$tb/authorized" 2>/dev/null)" = 0 ] || continue
    case "$sec" in user|none|dponly) echo 1 > "$tb/authorized" 2>/dev/null && log "authorized $(cat "$tb/device_name") ourselves (security=$sec)";;
      *) log "dock $(cat "$tb/device_name") is not authorized and security level is '$sec' (needs a key): authorize it once from the desktop (boltctl enroll)";; esac
  done
  command -v boltctl >/dev/null 2>&1 && for tb in /sys/bus/thunderbolt/devices/*-*; do [ -e "$tb/unique_id" ] && boltctl enroll --policy auto "$(cat "$tb/unique_id")" >/dev/null 2>&1 || true; done
  for _ in $(seq 1 14); do dock=$(authorized_dock || true); [ -n "$dock" ] && break; sleep 1; done
fi
[ -n "$dock" ] || { log "no authorized dock within 20s — exit"; remember_not_egpu; exit 0; }
log "dock authorized: $dock"

# Keep the tunnel ports awake BEFORE looking for the GPU (see pin-tunnel-ports in the helper).
"$PRIV" pin-tunnel-ports on 2>/dev/null | while read -r _l; do log "tunnel port: $_l"; done
"$PRIV" mask-tunnel-ports 2>/dev/null | while read -r _l; do log "tunnel port: $_l"; done
gpu=$(find_gpu || true)
if [ -z "$gpu" ]; then
  # Gentle first. A card that was just powered on needs longer to train its link than one that was
  # already warm, and the step below — de-authorizing the Thunderbolt device — is a cable pull done
  # in software, on a root port whose fatal-error bits cannot be masked. Doing that to a card in the
  # middle of link training is the most likely cause of the resets seen at plug-in. With the ports
  # pinned awake, a plain rescan is usually all that was missing. If the GPU is already there
  # (the normal case), none of this runs.
  log "no GPU yet — tunnel ports pinned awake; waiting up to 24s with gentle rescans before anything drastic"
  for _g in $(seq 1 8); do
    echo 1 > /sys/bus/pci/rescan 2>/dev/null; sleep 3
    gpu=$(find_gpu || true); [ -n "$gpu" ] && { log "GPU appeared after a gentle rescan (~$((_g*3))s) — no re-authorization needed"; break; }
  done
fi
if [ -z "$gpu" ]; then
  log "no GPU yet — clear DPC (status+trigger) + reauth + rescan"
  clear_dpc
  echo 0 > "$dock/authorized" 2>/dev/null; sleep 2; echo 1 > "$dock/authorized" 2>/dev/null; sleep 3
  echo 1 > /sys/bus/pci/rescan 2>/dev/null; sleep 3
  for _ in $(seq 1 20); do gpu=$(find_gpu || true); [ -n "$gpu" ] && break; sleep 1; done
fi
[ -n "$gpu" ] || { log "GPU did not enumerate — exit"; remember_not_egpu; exit 0; }
# Remember that a real eGPU has attached here: the boot path uses this to decide
# whether a Thunderbolt device is worth poking the bus for, so a dock-only machine
# never pays for that.
mkdir -p /var/lib/nvegpu 2>/dev/null && : > /var/lib/nvegpu/egpu-seen 2>/dev/null || true
# Sound should follow the picture: the monitor on the end of the cable is usually where you want it.
# Sets the default output only — it is not locked, and a later change anywhere else wins (see egpu-audio.sh).
egpu_audio_follow(){
  runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    /home/deck/.local/bin/egpu-audio.sh follow 2>&1 | while read -r _l; do log "audio: $_l"; done
}
rm -f "$NOT_EGPU" 2>/dev/null || true   # a GPU is here: whatever is plugged in deserves a fresh judgement
# SteamOS only: after an OS update the driver extension may still be rebuilding and the kernel parameters may not be
# active yet; bringing the eGPU up in that window is the unprotected first connection. No other system gets this gate.
if command -v steamos-readonly >/dev/null 2>&1; then
if ! modinfo -n nvidia >/dev/null 2>&1; then
  if pgrep -f install-steamos-sysext >/dev/null 2>&1; then gate_fail "The NVIDIA driver is being built right now. Unplug the eGPU and plug it in again when the build has finished."
  else gate_fail "The NVIDIA driver is not installed. Unplug the eGPU, then open EGPU Buddy and press Repair (needs internet)."; fi
fi
/usr/local/sbin/egpu-kernel-cmdline --check >/dev/null 2>&1 || gate_fail "The eGPU kernel parameters are not active. Reboot once, then plug the eGPU in."
fi

cfg=$(xxd -l4 "/sys/bus/pci/devices/$gpu/config" 2>/dev/null | awk '{print $2$3}')
if [ "$cfg" = "ffffffff" ] || [ "$(cat /sys/bus/pci/devices/$gpu/current_link_width 2>/dev/null)" = "63" ]; then
  log "GPU $gpu is a ZOMBIE (cfg=$cfg) — refusing to poke (needs a physical replug). exit"
  exit 0
fi
GDEV=/sys/bus/pci/devices/$gpu

# ---- per-card quirks ---------------------------------------------------------------------------
# SEGMENTED ON PURPOSE: this changes nothing for the card this project was built and tested with.
# The tuning below (ReBAR to 16GB, pinning the link to Gen3) was measured on an RTX 5060 Ti (0x2d04)
# in an AORUS TB5 box. On an RTX 3080 (GA102, 0x2206) the same steps killed the attach: the link
# pin dropped the link (width 63), and the driver then reported the GPU had "fallen off the bus and
# is not responding to commands". This project's own notes record the same wedge from the Ampere era.
#
# Matched by PCI device id, Ampere consumer range only (0x22xx-0x25xx = GA10x, the RTX 30 series).
# Ada (0x26xx-0x28xx) and Blackwell (0x2bxx-0x2dxx, including the 5060 Ti) do not match and keep the
# exact behaviour they were tested with.
egpu_is_ampere_consumer(){
  local id; id=$(cat "/sys/bus/pci/devices/$1/device" 2>/dev/null)
  case "$id" in 0x22??|0x23??|0x24??|0x25??) return 0 ;; esac
  return 1
}

# ---- ReBAR / BAR1 -> 16GB : GAMING fix, HOTPLUG PATH ONLY --------------------------------------
# WHY: with the default 256M BAR1 the CPU sees only a 256M window into ~10GB of VRAM. A game with
# ~6GB resident (measured: DOOM = 5932MB, BAR1 176/256MB pinned) re-maps that aperture constantly
# across the USB4 tunnel -> sustained ~1.3GB/s of PCIe churn and the user-visible bottleneck.
# STATE_SNAPSHOT.md:12 "Removing empty TB5 sibling ports permits BAR1 resize to the full 16GB."
#
# WHY HOTPLUG ONLY, NEVER BOOT: ReBAR can wedge NVIDIA RmInitAdapter (0x24:0x72:1603) on this Strix
# Halo + RTX 3080. Keeping egpu-boot-enumerate.sh LEAN means a wedge is ALWAYS recoverable by a plain
# reboot — the user can never be stranded. Opt out entirely: touch /etc/nv-egpu-buddy/no-rebar
# Order is load-bearing: free empty siblings -> FLR (clears init residue) -> resize -> bind.
# ---- FLR (ALWAYS) ------------------------------------------------------------------------------
# Separate from ReBAR. The manual egpu-attach.sh — the path that produced the known-good June captures
# (sane 154W power reading, GPU boosting) — always did a driverless FLR before loading the driver, and
# the helper documents it as clearing "host-side first-init residue". Without it the GPU inits with
# stale state, and a stale POWER CALIBRATION is exactly the fault: driver reports a fixed ~425W offset
# -> permanent SW power cap -> core clock clamped to its 210MHz minimum (2026-07-12).
# This MUST run before load-nvidia; the helper refuses on a bound or zombie GPU, so it cannot wedge.
# A surprise removal leaves the nvidia modules loaded (kernel-internal refs); the re-enumerated GPU then
# auto-binds before we can FLR it and nvkms display init fails (Xid 56, 2026-09-11). Unbind (GPU + audio fn)
# so the driverless FLR below runs, then the normal load/bind follows.
# ...but ONLY a GPU that is bound and NOT working. The marker never expires, and the display driver
# coming up fires this hook again through udev: with a marker left over from an earlier unplug, the
# hook unbound a healthy GPU 0.3s after nvidia-drm had initialised it (seen on an RTX 3080, and
# nothing about it is specific to that card). A GPU with a DRM card is not stale.
if [ -L "$GDEV/driver" ] && [ -e /run/nvegpu/surprise-pending ] && compgen -G "$GDEV/drm/card*" >/dev/null 2>&1; then
  log "driver is bound AND has a DRM card: the GPU is working — clearing the stale surprise marker, not unbinding"
  rm -f /run/nvegpu/surprise-pending
fi
if [ -L "$GDEV/driver" ] && [ -e /run/nvegpu/surprise-pending ]; then
  log "stale-bound after a surprise removal -> unbind for a driverless FLR"
  _aud="${gpu%.*}.1"; [ -L "/sys/bus/pci/devices/$_aud/driver" ] && echo "$_aud" > "/sys/bus/pci/devices/$_aud/driver/unbind" 2>/dev/null
  echo "$gpu" > "$GDEV/driver/unbind" 2>/dev/null; sleep 2; rm -f /run/nvegpu/surprise-pending
fi
# Decide the card's quirks before anything touches it (see egpu_is_ampere_consumer).
EGPU_SKIP_LINKPIN=0; EGPU_SKIP_REBAR=0; EGPU_SKIP_FLR=0
# say what was detected, every time: a quirk that silently does not fire is worse than no quirk,
# and this one logged nothing at all while the steps it was meant to skip ran anyway
log "card check: gpu='${gpu:-unset}' id=$(cat "/sys/bus/pci/devices/${gpu:-none}/device" 2>/dev/null || echo unreadable)"
if egpu_is_ampere_consumer "$gpu"; then
  # ReBAR is back ON for this card. It was disabled when a resize before the driver load left the
  # GPU rendering black, and the fix for that is already below (re-enumerate after a real resize).
  # The boot path now reaches a full 16GiB BAR1 on this same card, and a hot-plug is a BETTER case
  # than boot: the tunnel link is never reset, so the card keeps whatever BAR it is told to ask for.
  EGPU_SKIP_LINKPIN=0; EGPU_PIN_CORRECTED=1; EGPU_SKIP_REBAR=0; EGPU_SKIP_FLR=1
  log "RTX 30 series (GA10x): lean bring-up — no FLR, ReBAR attempted, corrected Gen3 link pin"
fi
if [ ! -L "$GDEV/driver" ] && [ "$EGPU_SKIP_FLR" = 1 ]; then
  # The FLR is what leaves this card decoding nothing: config space still reads, but every MMIO
  # read fails and the driver reports the GPU has "fallen off the bus". This project's own notes
  # from the Ampere era say the same thing — a lean load inits clean, FLR and ReBAR do not.
  log "FLR skipped for this card (it stops the card answering on MMIO)"
elif [ ! -L "$GDEV/driver" ]; then
  if "$PRIV" reset-gpu >/dev/null 2>&1; then log "FLR done (clears first-init residue)"
  else log "FLR unavailable — continuing"; fi
else
  log "FLR skipped — driver already bound (racing loader)"
fi

# ---- ReBAR (OFF by default: wedges RmInitAdapter on this Strix Halo + RTX 3080) ------------------
# 2026-09-18: a resize right before the driver load left the GPU in a state where the session came up but every game
# was black (Diablo IV, Cyberpunk; A/B-tested: resize -> black, same card re-enumerated with its 16G BAR kept -> fine).
# So: (1) skip the whole block when BAR1 already is 16G (a software re-attach keeps the size; only a cable pull resets
# it to 256M); (2) after a real resize, remove + rescan the GPU once and FLR it again, so the driver loads on a freshly
# enumerated device exactly like the working path. About two seconds, no session involved.
_bar1_bytes(){ stat -c %s "$GDEV/resource1" 2>/dev/null || echo 0; }
# Nothing may bind the card while its BAR is being changed. udev autoloads nvidia as soon as the
# device appears and it wins the race BETWEEN the steps below, which silently turns the resize and
# the re-enumeration into no-ops (the tell is kernel messages reading "nvidia 0000:..: BAR 1 ..."
# instead of "pci 0000:..."). Restored by trap as well as inline: leaving this at 0 would stop the
# kernel binding a driver to ANY pci device.
_autoprobe_was=$(cat /sys/bus/pci/drivers_autoprobe 2>/dev/null || echo 1)
trap 'echo "${_autoprobe_was:-1}" > /sys/bus/pci/drivers_autoprobe 2>/dev/null || true' EXIT HUP INT TERM
echo 0 > /sys/bus/pci/drivers_autoprobe 2>/dev/null || true
if [ "${EGPU_SKIP_REBAR:-0}" = 1 ]; then
  log "ReBAR skipped for this card"
elif [ ! -e /etc/nv-egpu-buddy/no-rebar ] && [ "$(_bar1_bytes)" -ge 17179869184 ]; then
  log "BAR1 already 16GB — resize block skipped"
elif [ ! -e /etc/nv-egpu-buddy/no-rebar ]; then
  cfg0(){ xxd -l4 "$1/config" 2>/dev/null | awk '{print $2$3}'; }
  dev_alive(){ local d=$1 w c
    [ -e "$d" ] || return 1
    w=$(cat "$d/current_link_width" 2>/dev/null); [ "$w" = "63" ] && return 1
    c=$(cfg0 "$d"); [ "$c" = "ffffffff" ] || [ -z "$c" ] && return 1
    return 0; }
  bridge_has_children(){ local br cr
    br=$(readlink -f "$1" 2>/dev/null) || return 1; [ -n "$br" ] || return 1
    for cr in /sys/bus/pci/devices/*; do
      case "$(readlink -f "$cr" 2>/dev/null || true)" in "$br"/*) return 0 ;; esac
    done; return 1; }
  empty_siblings(){ local gr gb sw cand
    gr=$(readlink -f "$GDEV" 2>/dev/null) || return 0; [ -n "$gr" ] || return 0
    gb=$(dirname "$gr"); sw=$(dirname "$gb")
    for cand in "$sw"/0000:*; do
      [ -e "$cand" ] || continue; [ "$cand" != "$gb" ] || continue
      [ "$(cat "$cand/class" 2>/dev/null)" = "0x060400" ] || continue
      bridge_has_children "$cand" && continue
      printf '%s\n' "${cand##*/}"
    done; }

  for p in $(empty_siblings); do
    dev_alive "/sys/bus/pci/devices/$p" || { log "sibling $p not alive — skip"; continue; }
    "$PRIV" remove-sibling "$p" >/dev/null 2>&1 && log "freed empty sibling port $p"
  done
  sleep 1
  if [ ! -L "$GDEV/driver" ] && [ -e "$GDEV/resource1_resize" ]; then
    if   "$PRIV" resize 14 >/dev/null 2>&1; then log "BAR1 -> 16GB (ReBAR on: gaming aperture)"
    elif "$PRIV" resize 13 >/dev/null 2>&1; then log "BAR1 -> 8GB (16G refused)"
    elif "$PRIV" resize 12 >/dev/null 2>&1; then log "BAR1 -> 4GB (8G refused)"
    else
      # The kernel refuses with ENOSPC when the bridge window above the card cannot hold the new
      # BAR, and it will not grow that window on its own: it sizes it around what the card is
      # CURRENTLY asking for. So tell the card to ask for its largest BAR (rebar-set writes the
      # Resizable BAR control register directly) and hand the switch's downstream ports back so the
      # kernel lays the whole range out in one pass with the big BAR in view. "port" mode keeps the
      # switch — and the tunnel link — up, which is what stops the card losing the request.
      log "BAR1 resize refused by the kernel — asking the card directly and re-enumerating the ports"
      _max=$("$PRIV" resize-max 2>/dev/null); _max=${_max:-14}
      if _rset=$("$PRIV" rebar-set "$_max" 2>&1); then
        log "  $_rset"
        if _rout=$("$PRIV" reenumerate-tunnel port 2>&1); then
          printf '%s\n' "$_rout" | while read -r _rl; do [ -n "$_rl" ] && log "  re-enum: $_rl"; done
          for _ in $(seq 1 20); do [ -e "$GDEV/config" ] && break; sleep 1; done
          for _ in $(seq 1 15); do [ "$(_bar1_bytes)" -gt 0 ] && break; sleep 1; done
          log "after re-enumeration: BAR1 $(( $(_bar1_bytes) / 1048576 ))MiB"
          # a BAR that could not be placed at all is worse than the stock one: put the request back
          if [ "$(_bar1_bytes)" -lt 536870912 ]; then
            log "the kernel could not place the large BAR — restoring the stock request"
            "$PRIV" rebar-set 8 >/dev/null 2>&1 || true
            "$PRIV" reenumerate-tunnel port >/dev/null 2>&1 || true
            for _ in $(seq 1 20); do [ -e "$GDEV/config" ] && break; sleep 1; done
            log "restored: BAR1 $(( $(_bar1_bytes) / 1048576 ))MiB"
          fi
        else
          log "port re-enumeration refused: ${_rout:-no reason given} — restoring the stock request"
          "$PRIV" rebar-set 8 >/dev/null 2>&1 || true
        fi
      else
        log "could not set the BAR1 request directly: ${_rset:-no reason given}"
      fi
    fi
    if [ "$(_bar1_bytes)" -ge 4294967296 ]; then
      log "re-enumerating the GPU after the resize (fresh device for the driver)"
      # the removal below is ours, not a cable yank: the surprise recovery honours this marker and stays out
      mkdir -p /run/nvegpu; date +%s > /run/nvegpu/gm-detach-pending
      _aud="/sys/bus/pci/devices/${gpu%.*}.1"; [ -e "$_aud/remove" ] && echo 1 > "$_aud/remove" 2>/dev/null
      echo 1 > "$GDEV/remove" 2>/dev/null; sleep 1
      echo 1 > /sys/bus/pci/rescan 2>/dev/null
      for _ in $(seq 1 20); do [ -e "$GDEV/config" ] && break; sleep 0.5; done
      sleep 2; rm -f /run/nvegpu/gm-detach-pending /run/nvegpu/surprise-pending
      if [ -e "$GDEV/config" ]; then
        log "GPU back, BAR1=$(( $(_bar1_bytes) / 1048576 ))MiB"
        [ -L "$GDEV/driver" ] || [ "${EGPU_SKIP_FLR:-0}" = 1 ] || { "$PRIV" reset-gpu >/dev/null 2>&1 && log "FLR done (after re-enumeration)"; }
      else log "GPU did not come back after the re-enumeration — exit"; exit 0; fi
    fi
  fi
fi


echo "${_autoprobe_was:-1}" > /sys/bus/pci/drivers_autoprobe 2>/dev/null || true
trap - EXIT HUP INT TERM

# --- ROOT-CAUSE FIX: PIN THE LINK SPEED (2026-08-20) --------------------------
# The tunnelled link's HARDWARE-AUTONOMOUS Gen3<->Gen4 renegotiation is what drops
# the link and cascades into the AMD data-fabric sync flood (NVIDIA #979, shown
# independent of GPU clocks -> it is the link, not the load). Pin the speed and
# DISABLE autonomous renegotiation on BOTH ends, then retrain once, BEFORE the
# driver loads, so no renegotiation can ever happen while the GPU is live.
# Tune: echo 2 > /etc/nv-egpu-buddy/link-gen   (Gen2 if Gen3 still floods)
pin_link_speed(){
  # skipped for the cards whose link does not survive it (see egpu_is_ampere_consumer)
  [ "${EGPU_SKIP_LINKPIN:-0}" = 1 ] && { log "LINK-PIN: skipped for this card"; return 0; }
  if [ "${EGPU_PIN_CORRECTED:-0}" = 1 ]; then
    # The legacy writes below put 0x003N into Link Control 2. Bit 4 of that register is ENTER
    # COMPLIANCE, set by mistake (the intent was bit 5 only = 0x002N). A card whose speed change does
    # not finish inside Recovery falls back through Polling, sees the bit and enters compliance test
    # mode: link dead, width 63. That is what "this card cannot take a link pin" really was.
    # Masked writes: touch target speed, CLEAR enter-compliance, set autonomous-speed-disable, and
    # retrain touching only the retrain bit. Verified on an RTX 3080: 16GT/s -> 8GT/s x4, link up.
    # (The legacy path is left exactly as it was tested on the RTX 5060 Ti.)
    local _b _g _gen; _g=${1:-$gpu}; _b=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$_g")")")
    _gen=$(cat /etc/nv-egpu-buddy/link-gen 2>/dev/null || echo 3); case "$_gen" in 1|2|3|4|5) ;; *) _gen=3 ;; esac
    setpci -s "${_b#0000:}" CAP_EXP+30.w=002${_gen}:003f 2>/dev/null || true
    setpci -s "${_g#0000:}" CAP_EXP+30.w=002${_gen}:003f 2>/dev/null || true
    setpci -s "${_b#0000:}" CAP_EXP+10.w=0020:0020 2>/dev/null || true
    sleep 2
    log "LINK-PIN (corrected): $(lspci -vv -s "${_g#0000:}" 2>/dev/null | grep -oE 'LnkSta:.*' | head -1)"
    return 0
  fi
  local gpu_full=$1 gen bridge gpu_s bridge_s
  gen=$(cat /etc/nv-egpu-buddy/link-gen 2>/dev/null || echo 3)
  case "$gen" in 1|2|3|4|5) ;; *) gen=3 ;; esac
  bridge=$(basename "$(readlink -f "/sys/bus/pci/devices/$gpu_full/.." 2>/dev/null)" 2>/dev/null)
  [ -n "$bridge" ] || { log "LINK-PIN: no parent bridge for $gpu_full"; return 0; }
  gpu_s=${gpu_full#0000:}; bridge_s=${bridge#0000:}

  # ASPM L0s/L1 off + L1 substates off on both ends (link-drop sources during bursts)
  setpci -s "$bridge_s" CAP_EXP+10.w=0000 2>/dev/null || true
  setpci -s "$gpu_s"    CAP_EXP+10.w=0000 2>/dev/null || true
  setpci -s "$bridge_s" ECAP_1E+04.l=00000000 2>/dev/null || true
  setpci -s "$gpu_s"    ECAP_1E+04.l=00000000 2>/dev/null || true

  # Target Link Speed = Gen$gen, plus bit5 Hardware Autonomous Speed Disable
  setpci -s "$bridge_s" CAP_EXP+30.w="003$gen" 2>/dev/null || true
  setpci -s "$gpu_s"    CAP_EXP+30.w="003$gen" 2>/dev/null || true
  # retrain once so the pin takes effect now
  setpci -s "$bridge_s" CAP_EXP+10.w=0020 2>/dev/null || true
  sleep 0.5
  log "LINK-PIN: $bridge_s + $gpu_s pinned to Gen$gen, autonomous speed change DISABLED, ASPM/L1SS off"
  log "LINK-PIN: $(lspci -vv -s "$gpu_s" 2>/dev/null | grep -oE 'LnkSta:.*' | head -1)"
  # Verify the link SURVIVED the pin. These settings were tuned for one card; on an RTX 3080 the same
  # retrain dropped the link (width reads 63 = down), the GPU then read as a zombie and every driver
  # step was refused — an attach that failed completely because of a tuning tweak. If the link is
  # gone, undo the pin, let the hardware negotiate freely and retrain again.
  _lp_w=$(cat "/sys/bus/pci/devices/$gpu_full/current_link_width" 2>/dev/null)
  if [ "$_lp_w" = "63" ] || [ -z "$_lp_w" ] || [ "$_lp_w" = "0" ]; then
    log "LINK-PIN: the link did not survive the pin (width=${_lp_w:-unreadable}) — reverting to hardware negotiation"
    setpci -s "$bridge_s" CAP_EXP+30.w=0000 2>/dev/null || true
    setpci -s "$gpu_s"    CAP_EXP+30.w=0000 2>/dev/null || true
    setpci -s "$bridge_s" CAP_EXP+10.w=0020 2>/dev/null || true
    for _lp_i in $(seq 1 10); do
      sleep 1
      _lp_w=$(cat "/sys/bus/pci/devices/$gpu_full/current_link_width" 2>/dev/null)
      case "$_lp_w" in 1|2|4|8|16) break ;; esac
    done
    log "LINK-PIN: after reverting, link width=${_lp_w:-unreadable} ($(lspci -vv -s "$gpu_s" 2>/dev/null | grep -oE 'LnkSta:.*' | head -1))"
  fi
}
pin_link_speed "$gpu"

# a Desktop safe-detach hides the NVIDIA userspace (ICD/EGL json, NVML) so nothing re-opens the card; a later hot-plug
# must un-hide it before the session is restaged, or the login env script leaves KWin on both GPUs (seen 2026-09-18)
/usr/local/sbin/egpu-safe-detach --restore >/dev/null 2>&1 || true
mask_surprise_down "$gpu"
# Debug hold: stop here, with the card enumerated and protected but NO driver loaded, so the link
# can be inspected and the bring-up done by hand one step at a time. Off unless the flag exists.
if [ -e /etc/nv-egpu-buddy/hold-before-driver ]; then
  log "HOLD: /etc/nv-egpu-buddy/hold-before-driver is set — stopping before the driver load"
  exit 0
fi
log "GPU $gpu healthy (cfg=$cfg) — load driver + display stack"
# Config space answering is not proof the card can be driven: the driver talks to it through BAR0,
# and a BAR that the kernel has assigned but the HARDWARE register does not hold (lspci marks it
# "[virtual]") decodes nothing — every read fails and the driver reports the GPU has "fallen off
# the bus". Seen on an RTX 3080. Compare the two and say so, so the cause is in the log.
_bar_hw=$(setpci -s "${gpu#0000:}" BASE_ADDRESS_0 2>/dev/null)
_bar_kn=$(awk 'NR==1{print $1}' "$GDEV/resource" 2>/dev/null)
_bar_hw_addr=$(( 0x${_bar_hw:-0} & ~0xf ))
if [ -n "$_bar_kn" ] && [ "$_bar_hw_addr" -ne "$(( _bar_kn ))" ]; then
  log "BAR0 MISMATCH: hardware holds 0x$(printf %x "$_bar_hw_addr"), the kernel assigned $_bar_kn — the card cannot decode MMIO like this"
  log "re-enumerating the GPU function so the kernel programs its BARs again"
  # (a link retrain can bounce the link, and a bounce resets the card's config space: the BARs go
  #  back to zero while the kernel still believes its own assignment — measured on an RTX 3080)
  mkdir -p /run/nvegpu; date +%s > /run/nvegpu/deliberate-removal
  _aud="${gpu%.*}.1"; [ -e "/sys/bus/pci/devices/$_aud" ] && echo 1 > "/sys/bus/pci/devices/$_aud/remove" 2>/dev/null
  echo 1 > "$GDEV/remove" 2>/dev/null; sleep 1; echo 1 > /sys/bus/pci/rescan 2>/dev/null
  for _ in $(seq 1 15); do [ -e "$GDEV" ] && break; sleep 1; done; sleep 2
  rm -f /run/nvegpu/deliberate-removal
  "$PRIV" mask-surprise-down >/dev/null 2>&1 || true
  _bar_hw=$(setpci -s "${gpu#0000:}" BASE_ADDRESS_0 2>/dev/null)
  log "after re-enumeration: hardware BAR0=0x${_bar_hw:-?} kernel=$(awk 'NR==1{print $1}' "$GDEV/resource" 2>/dev/null)"
else
  log "BAR0 programmed in hardware (0x$(printf %x "$_bar_hw_addr")) — MMIO should decode"
fi
# a refusal or a failed load must be visible in the log (it used to be discarded, which hid a refused display stack)
_pv(){ local o; o=$("$PRIV" "$@" 2>&1) || log "helper $*: ${o:-failed}"; }
_pv load-nvidia
[ -L "$GDEV/driver" ] || _pv bind-nvidia
_aud="${gpu%.*}.1"; [ -e "/sys/bus/pci/devices/$_aud" ] && [ ! -L "/sys/bus/pci/devices/$_aud/driver" ] && echo "$_aud" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null   # re-bind audio fn after an unbind+FLR
_pv load-modeset
_pv load-drm
for _ in $(seq 1 15); do compgen -G "$GDEV/drm/card*" >/dev/null && break; sleep 1; done
# see card_for_pci in nv-egpu-gamescope-session: a stale DRM card has no connectors, and
# aiming the session at it crash-loops Game Mode into a black screen. Take a card WITH outputs.
egpu_card=""
for _cd in "$GDEV"/drm/card[0-9]*; do
  [ -e "$_cd" ] || continue
  [ -n "$egpu_card" ] || egpu_card=${_cd##*/}
  compgen -G "/sys/class/drm/${_cd##*/}-*" >/dev/null 2>&1 && { egpu_card=${_cd##*/}; break; }
done
if [ -z "$egpu_card" ]; then   # no DRM card = no display to move a session to: say so instead of "staging anyway"
  log "NVIDIA display driver did not create a DRM card (nvidia_drm loaded: $([ -d /sys/module/nvidia_drm ] && echo yes || echo NO)) — stopping"
  mkdir -p /run/nvegpu; printf '{"state":"FAILED","message":"%s"}\n' "The eGPU is connected but its display driver did not start. Details: /var/log/egpu-hotplug-mount.log" > /run/nvegpu/gm-status.json 2>/dev/null
  wait; exit 0
fi
log "mounted $gpu + display stack ready (DRM card: $egpu_card)"

# ---- display-aware session completion: land the eGPU display on a NVIDIA-ONLY session ----
egpu_has_output=0
for s in /sys/class/drm/"$egpu_card"-*/status; do
  [ "$(cat "$s" 2>/dev/null)" = connected ] && egpu_has_output=1
done
# Route KWin to the eGPU, NVIDIA-only, masking the AMD iGPU.
#
# WHY NOT a re-login: KWin is a systemd USER service (user@1000.service/plasma-kwin_wayland.service),
# NOT a child of the login session. So `systemctl restart plasmalogin.service` (greeter bounce) and
# even `loginctl terminate-session` both leave KWin running -> the plasma env hook never re-applies
# and the session stays on both GPUs = extended desktop / crosstalk (found 2026-07-12; KWin had
# survived 1d3h of "relogins"). The ONLY thing that re-executes KWin with new env is restarting its
# user service, which inherits the systemd user-manager environment. So: push the NVIDIA-only env
# into the user manager, then restart the KWin unit.
relogin_session(){
  local uid=1000 nvcard runenv
  nvcard=$(ls -d "$GDEV"/drm/card[0-9] 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null)
  [ -n "$nvcard" ] || { log "no NVIDIA DRM card — cannot route KWin"; return 1; }
  runenv="XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"

  # (2026-09-18) A boot_vga bind-mount step used to be called here; its functions were defined after `exit 0`, so it
  # never ran. The NVIDIA-only session works on KWIN_DRM_DEVICES alone; the step is gone rather than switched on.

  log "routing KWin to NVIDIA-only: KWIN_DRM_DEVICES=/dev/dri/$nvcard (AMD masked)"
  runuser -u deck -- env $runenv systemctl --user set-environment \
      "KWIN_DRM_DEVICES=/dev/dri/$nvcard" \
      "KWIN_RENDER_NODES=/dev/dri/$(ls /sys/class/drm/$nvcard/device/drm 2>/dev/null | grep -m1 renderD)" \
      "VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json" \
      "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json" \
      "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json" \
      "__GLX_VENDOR_LIBRARY_NAME=nvidia" 2>/dev/null || { log "set-environment failed"; return 1; }

  # 2026-08-20 FULL SESSION CYCLE instead of a bare KWin service restart.
  # Restarting plasma-kwin_wayland.service only bounces the compositor: it does
  # NOT re-run startplasma-wayland, so ~/.config/plasma-workspace/env/
  # 00-egpu-free-nvidia-modeset.sh (the NVIDIA staging hook) never re-executes
  # and KWin comes back half-configured -- observed as "Failed to open drm node"
  # with zero card fds, i.e. a frozen desktop.
  # A clean KDE logout tears the session down completely (KWin exits, DRM master
  # released); plasmalogin's Relogin=true immediately logs back in, re-running
  # the full startup path with boot_vga already pointing at the eGPU.
  # Same primitive steamos-session-select uses for its session switch.
  if runuser -u deck -- env $runenv qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null; then
    log "session logout issued — autologin will restart Plasma NVIDIA-first"
  elif runuser -u deck -- env $runenv qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout 2>/dev/null; then
    log "session logout issued (qdbus) — autologin will restart Plasma NVIDIA-first"
  else
    log "logout failed — falling back to KWin service restart"
    runuser -u deck -- env $runenv systemctl --user restart plasma-kwin_wayland.service 2>/dev/null \
      && log "KWin restarted on NVIDIA-only" || log "KWin restart failed"
  fi

  # 2026-08-20 EXTERNAL-ONLY. Leaving eDP-1 enabled makes KWin composite two
  # outputs across two GPUs (panel on AMD + external on NVIDIA); that multi-GPU
  # compositing is what trips the nvidia-drm pageflip timeout and loses the GPU.
  # Enable the eGPU output as primary FIRST, then drop the panel (never zero
  # displays) -- same order as the proven egpu_display_tv.sh, and the
  # external-display-only default from V2_PLAN.md.
  egpu_external_only &
}

egpu_external_only(){
  local ext="" t k
  # wait for the NVIDIA-only KWin of the relogin (up to 60s); before that kscreen talks to the dying session
  for t in $(seq 1 30); do
    k=$(pgrep -x kwin_wayland | head -1)
    [ -n "$k" ] && tr '\0' '\n' </proc/"$k"/environ 2>/dev/null | grep -q "KWIN_DRM_DEVICES=/dev/dri/$nvcard\$" && break
    sleep 2
  done
  # The session pin has done its job (it only had to survive THIS relogin). Release it immediately: it sorts last and would
  # otherwise outrank the system's own choice, so "Return to Gaming Mode" just re-loaded the desktop (seen on a real device).
  /usr/local/sbin/egpu-dm-session unpin >/dev/null 2>&1 || true
  # ...but then NOTHING tells the login manager to come back to the desktop if this session dies.
  # KWin is pinned NVIDIA-only (that is what keeps rendering off the AMD card and out of the
  # tunnel), so a cable pull kills it and the login manager auto-logs in to ITS default. On SteamOS
  # that default is Game Mode - measured: kwin dies and sddm selects gamescope-wayland.desktop in
  # the SAME SECOND, long before any recovery hook can run. On CachyOS this never happened because
  # the default there was already plasma; that is the whole difference between the two systems.
  # steamosctl set-default-login-mode is NOT usable for this: it errors out with
  #   Error: I/O error: No such file or directory (os error 2)
  # and leaves the sddm config untouched. So re-pin instead, which does work - the drop-in just has
  # to out-sort SteamOS's own zz-steamos-autologin.conf (see egpu-dm-session).
  /usr/local/sbin/egpu-dm-session pin plasma >/dev/null 2>&1 &&
    log "login fallback -> plasma (losing the card now returns to the desktop, not Game Mode)"
  sleep 4
  for t in 1 2 3 4 5 6 7 8; do
    ext=$(ksd -o 2>/dev/null \
            | grep -oE '\b(DP|HDMI-A)-[0-9]+' | grep -vx eDP-1 | head -1)
    [ -n "$ext" ] && break
    sleep 2
  done
  if [ -z "$ext" ]; then
    # The monitor went away between the connector check and this relogin. NEVER darken the
    # panel here: that is the difference between "the external display took over" and "the
    # user has no screen at all". Put the built-in panel back and say so.
    log "EXTERNAL-ONLY: no eGPU output found via kscreen — restoring the built-in panel instead of darkening it"
    /usr/local/sbin/egpu-panel on >/dev/null 2>&1 || true
    ksd output.eDP-1.enable output.eDP-1.priority.1 >/dev/null 2>&1 || true
    ksd --dpms on >/dev/null 2>&1 || true
    mkdir -p /run/nvegpu; printf '{"state":"FAILED","message":"%s"}\n' "The eGPU monitor stopped responding during the switch. You are back on the built-in screen." > /run/nvegpu/gm-status.json 2>/dev/null
    return 0
  fi
  ksd output."$ext".enable output."$ext".priority.1 >/dev/null 2>&1
  sleep 1
  if ksd output.eDP-1.disable >/dev/null 2>&1; then
    log "EXTERNAL-ONLY: $ext primary, eDP-1 disabled"
  else
    log "EXTERNAL-ONLY: failed to disable eDP-1 -> DPMS off via egpu-panel"; /usr/local/sbin/egpu-panel off >/dev/null 2>&1
  fi
  # KWin pinned to the NVIDIA card never lists eDP-1, so kscreen cannot turn it off: the panel keeps the previous
  # compositor's last frame. egpu-panel is a no-op when a compositor owns card1.
  /usr/local/sbin/egpu-panel off >/dev/null 2>&1 && log "EXTERNAL-ONLY: eDP-1 CRTC off (panel unowned after NVIDIA-only relogin)"
  egpu_audio_follow
}
set_autologin_plasma(){ /usr/local/sbin/egpu-dm-session pin plasma >/dev/null 2>&1 || true; }
# 2026-09-10: a monitor that is asleep / still training its link is NOT a reason to skip the
# NVIDIA-only session. Wait up to 90s for any eGPU connector to report connected; if none does,
# stage anyway (the monitor is connected even if asleep; the resume/DPMS path lights it later).
# A monitor that dropped into deep standby (no signal yet, because we are waiting for IT) can stop asserting hot-plug, and
# then nothing ever changes by itself. So do not just wait: force a probe of every eGPU connector each cycle ("detect"
# makes the driver query the monitor over DisplayPort AUX / DDC), and say in the UI what is being waited for.
if [ "$egpu_has_output" != 1 ]; then
  mkdir -p /run/nvegpu; printf '{"state":"SWITCHING","message":"%s"}\n' "The eGPU is ready. Waiting for the monitor: switch it on or wake it (up to 90 seconds)." > /run/nvegpu/gm-status.json 2>/dev/null
  for _w in $(seq 1 45); do
    for _s in /sys/class/drm/"$egpu_card"-*/status; do echo detect > "$_s" 2>/dev/null || true; done
    for _s in /sys/class/drm/"$egpu_card"-*/status; do [ "$(cat "$_s" 2>/dev/null)" = connected ] && egpu_has_output=1; done
    [ "$egpu_has_output" = 1 ] && { log "eGPU output appeared after $((_w*2))s"; break; }; sleep 2
  done
  # Asking is not always enough: on many displays the SIGNAL is what brings the panel out
  # of standby, and until something drives one they answer nothing. So stop asking and
  # drive it — force the connector on, which makes the kernel report it connected and the
  # compositor put a mode on it. That is the signal that wakes the monitor.
  if [ "$egpu_has_output" != 1 ]; then
    log "no answer to the probe — forcing the eGPU connectors ON so a signal is driven at the monitor"
    for _s in /sys/class/drm/"$egpu_card"-*/status; do
      case "$_s" in *eDP-*|*Writeback-*) continue ;; esac
      echo on > "$_s" 2>/dev/null || true
    done
    # A forced connector reports connected whether or not anything is really there, so take
    # the monitor's own answer as proof: EDID appears once it has woken and replied.
    for _w in $(seq 1 10); do
      for _c in /sys/class/drm/"$egpu_card"-*; do
        [ -s "$_c/edid" ] 2>/dev/null && { egpu_has_output=1; log "monitor woke and replied on ${_c##*/} after the forced signal"; break 2; }
      done
      sleep 2
    done
    if [ "$egpu_has_output" != 1 ]; then
      log "nothing replied after 20s of driven signal — releasing the force and staying on the built-in screen"
      for _s in /sys/class/drm/"$egpu_card"-*/status; do
        case "$_s" in *eDP-*|*Writeback-*) continue ;; esac
        echo detect > "$_s" 2>/dev/null || true
      done
    fi
  fi
fi
if [ "$egpu_has_output" != 1 ]; then
  mkdir -p /run/nvegpu; printf '{"state":"IDLE","message":"%s"}\n' "The eGPU is ready, but its monitor is not responding. Staying on the built-in screen — switch the monitor on and it will take over by itself." > /run/nvegpu/gm-status.json 2>/dev/null
  log "eGPU has no connected output — leaving session as-is"; exit 0
fi
# Crosstalk = KWin has the AMD GPU open at all. The old check only looked for the AMD *render* node
# (renderD*), but KWin holds the AMD *card* node (card1) WITHOUT opening its render node -> every
# hotplug was mis-declared "already NVIDIA-only" and skipped the relogin, leaving an extended desktop
# across both GPUs (found 2026-07-12). Check BOTH node types.
kw=$(pgrep -x kwin_wayland | head -1)
amd_nodes=$(for d in /sys/class/drm/card[0-9] /sys/class/drm/renderD*; do
  [ -e "$d" ] || continue
  [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null || true)")" = amdgpu ] && basename "$d"
done)
crosstalk=0
if [ -n "$kw" ]; then
  for n in $amd_nodes; do
    if ls -l "/proc/$kw/fd" 2>/dev/null | grep -qE "/dev/dri/$n\$"; then crosstalk=1; break; fi
  done
fi
log "session check: kwin=$kw amd_nodes='$amd_nodes' crosstalk=$crosstalk"
# ---- FREEZE-PREVENTION GATE ----------------------------------------------------
# Only switch the compositor to NVIDIA-only if the GPU is PROVEN alive: NVML must
# respond (== RmInitAdapter succeeded == not wedged) and BAR1 must have actually
# resized. A ReBAR/init wedge MUST leave the user on the working iGPU+eDP session,
# never relogin onto a dead card (that is the black-screen we recovered from).
# Recovery from a wedge is a plain reboot; the user is never stranded.
gpu_healthy(){
  timeout 6 nvidia-smi -i "$gpu" --query-gpu=name --format=csv,noheader >/dev/null 2>&1 || {
    log "HEALTH GATE FAIL: NVML not responding on $gpu (GPU init wedged) - staying on iGPU, NO compositor switch, NO freeze. Reboot to retry."
    return 1; }
  local bar1; bar1=$(timeout 6 nvidia-smi -i "$gpu" -q 2>/dev/null | awk '/BAR1 Memory/{getline; print $(NF-1); exit}')
  log "HEALTH GATE OK: NVML responds on $gpu, BAR1=${bar1:-?}MiB"
  return 0
}

if pgrep -x 'gamescope(-wl)?' >/dev/null 2>&1; then
  # GAME MODE: keep the gamescope autologin; restart gamescope onto the eGPU output (the
  # nv-egpu-gamescope-session wrapper does the routing). Deferred while a game runs.
  log "eGPU display up + Game Mode -> gamescope switch onto the eGPU"; sleep 2
  gpu_healthy && { /usr/local/sbin/egpu-gamemode-switch >/dev/null 2>&1; log "gamemode-switch rc=$?"; egpu_audio_follow; }
  exit 0
fi
# Only a running desktop session may pin the autologin to the desktop (the NVIDIA-only re-login must come back to
# it). At boot, before any session exists, the boot policy (egpu-conditional-session: Game Mode) decides. 2026-09-16.
pgrep -x kwin_wayland >/dev/null 2>&1 && set_autologin_plasma
if [ "$crosstalk" = 1 ]; then
  log "eGPU display up + iGPU desktop (crosstalk) -> re-login for NVIDIA-only"; sleep 2; gpu_healthy && relogin_session
else
  log "eGPU display up + already NVIDIA-only desktop -> leave as-is"
fi
# egpu_external_only runs in the background; this script is a transient systemd unit, and when its main process exits
# systemd kills the rest of the cgroup. Wait for it, or the panel stays on next to the eGPU display (2026-09-18).
wait
exit 0
