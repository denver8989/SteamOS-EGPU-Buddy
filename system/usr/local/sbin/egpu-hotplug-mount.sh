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
log(){ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >>"$LOG" 2>&1; }
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
clear_dpc(){   # clear latched DPC status (write-1) + disable trigger, on both USB4 root ports
  local p off v id nxt c
  for p in $(lspci -D -d 1022:150a -n 2>/dev/null | awk '{print $1}'); do
    off=0x100
    for _ in $(seq 1 48); do
      v=$(setpci -s "$p" "$off".l 2>/dev/null) || break
      id=$(( 0x$v & 0xffff )); nxt=$(( (0x$v >> 20) & 0xffc ))
      if [ "$id" -eq 29 ]; then
        setpci -s "$p" "$(printf 0x%x $((off+0x08)))".w=0001 2>/dev/null          # clear latched status
        c=$(setpci -s "$p" "$(printf 0x%x $((off+0x06)))".w 2>/dev/null)
        setpci -s "$p" "$(printf 0x%x $((off+0x06)))".w=$(printf %04x $(( 0x$c & ~0x3 ))) 2>/dev/null  # disable trigger
        break
      fi
      [ "$nxt" -eq 0 ] && break; off=$(printf 0x%x "$nxt")
    done
  done
}

# --- BOOTLOOP-BREAKER (2026-08-20) -------------------------------------------
# A flooding eGPU auto-loaded every boot = infinite reboot loop (only a physical
# unplug escaped it). Persistent lockout + previous-boot flood detection stop that.
# Override for an intentional test: sudo egpu-rearm  (clears lockout + /run flag).
LOCKOUT=/var/lib/nvegpu/flood-lockout
if [ ! -e /run/egpu-rearmed ]; then
  if [ -e "$LOCKOUT" ]; then
    log "FLOOD LOCKOUT active — eGPU auto-load disabled to prevent bootloop. Run: sudo egpu-rearm"
    exit 0
  fi
  if dmesg 2>/dev/null | grep -qi 'data fabric sync flood'; then
    mkdir -p /var/lib/nvegpu 2>/dev/null
    date '+%F %T' > "$LOCKOUT" 2>/dev/null
    log "PREVIOUS BOOT FLOODED (data fabric sync flood) — set lockout, skipping eGPU auto-load to break the loop. Run: sudo egpu-rearm to retry."
    exit 0
  fi
fi

log "=== hotplug-mount triggered ==="
# wait for boltd to authorize the dock (udev add fires before authorization)
dock=""
for _ in $(seq 1 20); do dock=$(authorized_dock || true); [ -n "$dock" ] && break; sleep 1; done
[ -n "$dock" ] || { log "no authorized dock within 20s — exit"; exit 0; }
log "dock authorized: $dock"

gpu=$(find_gpu || true)
if [ -z "$gpu" ]; then
  log "no GPU yet — clear DPC (status+trigger) + reauth + rescan"
  clear_dpc
  echo 0 > "$dock/authorized" 2>/dev/null; sleep 2; echo 1 > "$dock/authorized" 2>/dev/null; sleep 3
  echo 1 > /sys/bus/pci/rescan 2>/dev/null; sleep 3
  for _ in $(seq 1 20); do gpu=$(find_gpu || true); [ -n "$gpu" ] && break; sleep 1; done
fi
[ -n "$gpu" ] || { log "GPU did not enumerate — exit"; exit 0; }

cfg=$(xxd -l4 "/sys/bus/pci/devices/$gpu/config" 2>/dev/null | awk '{print $2$3}')
if [ "$cfg" = "ffffffff" ] || [ "$(cat /sys/bus/pci/devices/$gpu/current_link_width 2>/dev/null)" = "63" ]; then
  log "GPU $gpu is a ZOMBIE (cfg=$cfg) — refusing to poke (needs a physical replug). exit"
  exit 0
fi
GDEV=/sys/bus/pci/devices/$gpu

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
if [ -L "$GDEV/driver" ] && [ -e /run/nvegpu/surprise-pending ]; then
  log "stale-bound after a surprise removal -> unbind for a driverless FLR"
  _aud="${gpu%.*}.1"; [ -L "/sys/bus/pci/devices/$_aud/driver" ] && echo "$_aud" > "/sys/bus/pci/devices/$_aud/driver/unbind" 2>/dev/null
  echo "$gpu" > "$GDEV/driver/unbind" 2>/dev/null; sleep 2; rm -f /run/nvegpu/surprise-pending
fi
if [ ! -L "$GDEV/driver" ]; then
  if "$PRIV" reset-gpu >/dev/null 2>&1; then log "FLR done (clears first-init residue)"
  else log "FLR unavailable — continuing"; fi
else
  log "FLR skipped — driver already bound (racing loader)"
fi

# ---- ReBAR (OFF by default: wedges RmInitAdapter on this Strix Halo + RTX 3080) ------------------
if [ ! -e /etc/nv-egpu-buddy/no-rebar ]; then
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
    else log "BAR1 resize failed — staying 256M (siblings may not have freed)"; fi
  fi
fi


# --- ROOT-CAUSE FIX: PIN THE LINK SPEED (2026-08-20) --------------------------
# The tunnelled link's HARDWARE-AUTONOMOUS Gen3<->Gen4 renegotiation is what drops
# the link and cascades into the AMD data-fabric sync flood (NVIDIA #979, shown
# independent of GPU clocks -> it is the link, not the load). Pin the speed and
# DISABLE autonomous renegotiation on BOTH ends, then retrain once, BEFORE the
# driver loads, so no renegotiation can ever happen while the GPU is live.
# Tune: echo 2 > /etc/nv-egpu-buddy/link-gen   (Gen2 if Gen3 still floods)
pin_link_speed(){
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
}
pin_link_speed "$gpu"

log "GPU $gpu healthy (cfg=$cfg) — load driver + display stack"
"$PRIV" load-nvidia >/dev/null 2>&1 || true
[ -L "$GDEV/driver" ] || "$PRIV" bind-nvidia >/dev/null 2>&1 || true
_aud="${gpu%.*}.1"; [ -e "/sys/bus/pci/devices/$_aud" ] && [ ! -L "/sys/bus/pci/devices/$_aud/driver" ] && echo "$_aud" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null   # re-bind audio fn after an unbind+FLR
"$PRIV" load-modeset >/dev/null 2>&1 || true
"$PRIV" load-drm >/dev/null 2>&1 || true
for _ in $(seq 1 15); do compgen -G "$GDEV/drm/card*" >/dev/null && break; sleep 1; done
egpu_card=$(ls -d "$GDEV"/drm/card* 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null)
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

  # 2026-08-20 BOOT_VGA PRIMARY (technique learned from ewagner12/all-ways-egpu
  # Method 2, reimplemented here so we keep one automount and no extra tooling).
  # Wayland compositors (KWin/mutter/wlroots) choose their PRIMARY GPU from the
  # read-only sysfs flag boot_vga (and drm/cardN/boot_display). It cannot be
  # written, so bind-mount a file containing "1" over the eGPU's flag and "0"
  # over the iGPU's. Without this KWin treats NVIDIA as SECONDARY and composites
  # its outputs (NATIVE_PRESENT_PATH_PLAN.md:50-52) -- the crosstalk, and the
  # multi-GPU compositing that trips the nvidia-drm pageflip timeout.
  # MUST run BEFORE the compositor (re)starts, so it is ordered above the
  # set-environment + KWin restart below.
  egpu_set_boot_vga_primary "$(basename "$GDEV")"

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
  sleep 4
  for t in 1 2 3 4 5 6 7 8; do
    ext=$(runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 kscreen-doctor -o 2>/dev/null \
            | grep -oE '\b(DP|HDMI-A)-[0-9]+' | grep -vx eDP-1 | head -1)
    [ -n "$ext" ] && break
    sleep 2
  done
  if [ -z "$ext" ]; then
    log "EXTERNAL-ONLY: no eGPU output found via kscreen"
    /usr/local/sbin/egpu-panel off >/dev/null 2>&1 && log "EXTERNAL-ONLY: eDP-1 CRTC off (panel unowned)"
    return 0
  fi
  runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 kscreen-doctor \
    output."$ext".enable output."$ext".priority.1 >/dev/null 2>&1
  sleep 1
  if runuser -u deck -- env XDG_RUNTIME_DIR=/run/user/1000 kscreen-doctor \
       output.eDP-1.disable >/dev/null 2>&1; then
    log "EXTERNAL-ONLY: $ext primary, eDP-1 disabled"
  else
    log "EXTERNAL-ONLY: failed to disable eDP-1 -> DPMS off via egpu-panel"; /usr/local/sbin/egpu-panel off >/dev/null 2>&1
  fi
  # KWin pinned to the NVIDIA card never lists eDP-1, so kscreen cannot turn it off: the panel keeps the previous
  # compositor's last frame. egpu-panel is a no-op when a compositor owns card1.
  /usr/local/sbin/egpu-panel off >/dev/null 2>&1 && log "EXTERNAL-ONLY: eDP-1 CRTC off (panel unowned after NVIDIA-only relogin)"
}
set_autologin_plasma(){
  printf '[Autologin]\nRelogin=true\nSession=plasma.desktop\nUser=deck\n' > /etc/plasmalogin.conf 2>/dev/null || true
  install -d -m 0755 /etc/plasmalogin.conf.d
  printf '[Autologin]\nSession=plasma.desktop\n' > /etc/plasmalogin.conf.d/zz-steamos-autologin.conf 2>/dev/null || true
}
# 2026-09-10: a monitor that is asleep / still training its link is NOT a reason to skip the
# NVIDIA-only session. Wait up to 90s for any eGPU connector to report connected; if none does,
# stage anyway (the monitor is connected even if asleep; the resume/DPMS path lights it later).
if [ "$egpu_has_output" != 1 ]; then
  for _w in $(seq 1 45); do
    for _s in /sys/class/drm/"$egpu_card"-*/status; do [ "$(cat "$_s" 2>/dev/null)" = connected ] && egpu_has_output=1; done
    [ "$egpu_has_output" = 1 ] && { log "eGPU output appeared after $((_w*2))s"; break; }; sleep 2
  done
  [ "$egpu_has_output" = 1 ] || { log "no eGPU output detected after 90s — staging NVIDIA-only anyway (monitor may be asleep)"; egpu_has_output=1; }
fi
if [ "$egpu_has_output" != 1 ]; then
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
  gpu_healthy && { /usr/local/sbin/egpu-gamemode-switch >/dev/null 2>&1; log "gamemode-switch rc=$?"; }
  exit 0
fi
set_autologin_plasma
if [ "$crosstalk" = 1 ]; then
  log "eGPU display up + iGPU desktop (crosstalk) -> re-login for NVIDIA-only"; sleep 2; gpu_healthy && relogin_session
else
  log "eGPU display up + already NVIDIA-only desktop -> leave as-is"
fi
exit 0

# --- boot_vga primary (see egpu_set_boot_vga_primary call site above) ---------
EGPU_BINDDIR=/run/egpu-bootvga

egpu_clear_boot_vga(){
  # Unmount in reverse order; ignore anything already gone.
  if [ -r "$EGPU_BINDDIR/bind-paths" ]; then
    tac "$EGPU_BINDDIR/bind-paths" 2>/dev/null | while read -r bp; do
      [ -n "$bp" ] && umount -l "$bp" 2>/dev/null
    done
    rm -f "$EGPU_BINDDIR/bind-paths"
  fi
}

egpu_set_boot_vga_primary(){
  local gpu=$1 card path found=0
  [ -n "$gpu" ] || return 0
  mkdir -p "$EGPU_BINDDIR" 2>/dev/null
  printf '1\n' > "$EGPU_BINDDIR/1" 2>/dev/null
  printf '0\n' > "$EGPU_BINDDIR/0" 2>/dev/null
  egpu_clear_boot_vga

  # Every display-class PCI device: 0300 (VGA), 0302 (3D), 0380 (other display).
  for card in $( (lspci -D -d ::0300 -n; lspci -D -d ::0302 -n; lspci -D -d ::0380 -n) 2>/dev/null \
                 | awk '{print $1}' | sort -u); do
    for path in $(find /sys/bus/pci/devices/"$card"/ -maxdepth 3 -name 'boot_*' 2>/dev/null); do
      if [ "$card" = "$gpu" ]; then
        if mount -n --bind -o ro "$EGPU_BINDDIR/1" "$path" 2>/dev/null; then
          echo "$path" >> "$EGPU_BINDDIR/bind-paths"; found=1
        fi
      elif grep -q 1 "$path" 2>/dev/null; then
        if mount -n --bind -o ro "$EGPU_BINDDIR/0" "$path" 2>/dev/null; then
          echo "$path" >> "$EGPU_BINDDIR/bind-paths"
        fi
      fi
    done
  done

  if [ "$found" = 1 ]; then
    log "BOOT_VGA: $gpu is now primary (iGPU masked to 0) — KWin will pick the eGPU"
  else
    log "BOOT_VGA: no boot_* flag found for $gpu; primary unchanged"
  fi
}
