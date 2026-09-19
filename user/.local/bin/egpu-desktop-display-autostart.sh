#!/usr/bin/env bash
# ============================================================================
# egpu-desktop-display-autostart.sh  —  *** TEST MODE (lifeline) ***
#
# Runs at KDE/Plasma login. Purpose: make the Game Mode -> Desktop transition
# SAFE to test while we prove it out. Instead of going TV-only (which can strand
# you on a black TV), it keeps the HANDHELD panel (eDP-1) ON as the PRIMARY
# lifeline and brings the TV (HDMI-A-1 on the 3080) up ALONGSIDE it. So:
#   * if the TV lights up  -> you have both screens, drag a game to the TV;
#   * if the TV stays black -> the desktop is still fully usable on the handheld,
#     you are NOT stranded.
#
# Retries for ~30s to catch a late KWin/output settle on the transition, and
# logs everything to ~/.egpu-desktop-display.log for post-mortem. No-op when the
# eGPU is absent; refuses to poke a zombie GPU; never restarts the compositor;
# loads no kernel modules.
#
# External-only is the normal docked desktop target. Set
# EGPU_KEEP_PANEL_LIFELINE=1 only for recovery testing.
# ============================================================================
printf desktop > "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/egpu-session-type" 2>/dev/null || true   # session type, read by egpu-surprise-recover
set -u
# Session-type marker for egpu-surprise-recover: written at EVERY Plasma login, before any early exit below
# (the Game Mode session wrapper writes "gamemode"; whichever session started last owns the marker).
printf desktop > "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/egpu-session-type" 2>/dev/null || true
# eGPU PCI address is NOT fixed — it depends which USB4 port it tunneled through (seen at both
# 62:00.0 and 03:00.0). Detect the NVIDIA-driven GPU (with a DRM node) dynamically; hardcoding it
# made this whole autostart no-op as "eGPU absent" whenever it landed on the other address.
GPU=""
for p in /sys/bus/pci/devices/*/; do
  [ "$(basename "$(readlink -f "$p/driver" 2>/dev/null)" 2>/dev/null)" = nvidia ] || continue
  [ -d "$p/drm" ] || continue
  GPU=$(basename "$p"); break
done
GDEV=/sys/bus/pci/devices/$GPU
# TV (the PRIMARY external display) is chosen dynamically after the eGPU-health
# guards below — prefer a connected DisplayPort (the desk ultrawide, e.g. DP-7)
# over HDMI-A-1 (the 4K TV, which reports 'connected' even when powered OFF).
PANEL=eDP-1
LOG="$HOME/.egpu-desktop-display.log"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Only run in KDE Plasma session.
if [ "${XDG_CURRENT_DESKTOP:-}" != "KDE" ] && [ "${XDG_SESSION_DESKTOP:-}" != "KDE" ]; then
  exit 0
fi

[ "${XDG_SESSION_TYPE:-}" = "wayland" ] || exit 0
command -v kscreen-doctor >/dev/null 2>&1 || exit 0

log "=== TEST-MODE autostart start (session=$XDG_SESSION_DESKTOP) ==="

# eGPU must be physically present + healthy, else this is a normal handheld
# desktop and we touch nothing.
[ -e "$GDEV" ] || { log "eGPU absent — no-op"; exit 0; }
w=$(cat "$GDEV/current_link_width" 2>/dev/null)
[ "$w" = "63" ] && { log "GPU link width=63 (zombie) — refusing to poke"; exit 0; }
cfg0=$(xxd -l4 "$GDEV/config" 2>/dev/null | awk '{print $2$3}')
case "$cfg0" in ffffffff|"") log "GPU config dead/unreadable ($cfg0) — refusing"; exit 0;; esac

# Pick the PRIMARY external display: prefer a connected DisplayPort (DP-7 ultrawide)
# over HDMI-A-1 (the TV, which can report 'connected' while powered off). Replaces the
# old hardcoded TV=HDMI-A-1 that wrongly made an OFF TV primary over the ultrawide.
# Falls back to HDMI only when no DP is connected. Mirrors egpu-display-profile.sh.
NVCARD=$(basename "$(ls -d "$GDEV"/drm/card* 2>/dev/null | head -1)" 2>/dev/null)
# Enable EVERY usable eGPU external (BOTH DP and HDMI), DP first = primary. "Usable" =
# status connected AND the connector exposes EDID modes (sysfs `modes` non-empty). That EDID
# gate is the "TV is on its HDMI input" check the user asked for: a TV that's powered but NOT
# on the HDMI input drops EDID/HPD -> no modes -> we leave it disabled. (True input-selection
# certainty needs CEC; EDID-present is the reliable proxy the kernel gives us.)
EXTS=""
for kind in DP HDMI; do
  for st in /sys/class/drm/"$NVCARD"/"$NVCARD"-"$kind"-*/status; do
    [ -r "$st" ] || continue
    [ "$(cat "$st" 2>/dev/null)" = "connected" ] || continue
    conn=$(basename "$(dirname "$st")"); name=${conn#"$NVCARD"-}
    modes="$(dirname "$st")/modes"
    if [ ! -s "$modes" ]; then log "skip $name — connected but NO EDID modes (display off / not on this input)"; continue; fi
    EXTS="$EXTS $name"
  done
done
EXTS=$(echo $EXTS | xargs)
[ -n "$EXTS" ] || { log "no usable eGPU external (connected + EDID) — no-op"; exit 0; }
TV=${EXTS%% *}                       # primary = first (DP preferred); kept for existing verify/log lines
log "usable eGPU externals: $EXTS (first = primary)"

# Wait until KWin/kscreen is actually RESPONSIVE (a non-empty output list) before
# touching anything. On the Game->Desktop handoff this autostart can fire a beat
# before the compositor is ready — seen on the failed transition as an EMPTY
# output list, which made every kscreen-doctor call a silent no-op so the lifeline
# was never actually applied. If KWin never becomes responsive (totally black,
# e.g. it failed to allocate the NVIDIA device), there is nothing we can drive —
# log and exit rather than thrash.
ready=0
for i in $(seq 1 25); do
  if kscreen-doctor -o 2>/dev/null | grep -q "Output"; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -eq 0 ]; then
  log "KWin/kscreen not responsive after 25s (no outputs) — compositor did not come up; exiting (see [env] lines above)"
  exit 0
fi
log "KWin/kscreen responsive (compositor up) — proceeding with TV bring-up"

# Enable each usable external: DP first (priority 1 = primary), then HDMI (priority 2). For each,
# pick its best 4K mode (prefer ~110-120Hz) if it advertises one, else leave preferred/current.
prio=1
for out in $EXTS; do
  MODE=$(kscreen-doctor -o 2>/dev/null | awk -v tv="$out" '
    $0 ~ ("Output:.* " tv "$") {f=1} f && /Modes:/{m=1}
    m && /3840x2160/ { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+:3840x2160@1(1|2)[0-9]/){print $i; exit} }')
  kscreen-doctor output.$out.enable output.$out.priority.$prio >/dev/null 2>&1
  [ -n "${MODE:-}" ] && kscreen-doctor output.$out.mode.${MODE%%:*} >/dev/null 2>&1
  log "enabled $out (priority $prio${MODE:+, mode ${MODE%%:*}})"
  prio=$((prio+1))
done

# Keep the handheld as an explicit recovery lifeline, or disable it for the docked layout.
if [ "${EGPU_KEEP_PANEL_LIFELINE:-0}" = "1" ]; then
  kscreen-doctor output.$PANEL.enable output.$PANEL.priority.2 output.$PANEL.scale.1.5 >/dev/null 2>&1
else
  kscreen-doctor output.$PANEL.disable >/dev/null 2>&1
  # kscreen can only switch off outputs the compositor OWNS, and in the NVIDIA-only desktop it does not own the panel's
  # card at all, so that call is a no-op there. The CRTC is then left on by whoever had it last (the previous session, or
  # the console) and the panel sits lit and black. Ask the privileged helper, which talks to DRM directly, as well.
  sudo -n /usr/local/sbin/nv-egpu-buddy-privileged panel-off >/dev/null 2>&1 || true
fi

# Verify that the TV is active; rescue to the handheld if the handoff failed.
if kscreen-doctor -o 2>/dev/null | grep -A3 "$TV" | grep -q enabled; then
  log "OK — $TV is active; handheld lifeline=${EGPU_KEEP_PANEL_LIFELINE:-0}"
else
  log "WARN — $TV not active after handoff; re-enabling handheld as rescue"
  kscreen-doctor output.$PANEL.enable output.$PANEL.priority.1 >/dev/null 2>&1
fi
exit 0
