#!/usr/bin/env bash
# egpu-audio.sh follow | restore | status
#
# Move sound to the eGPU's HDMI/DisplayPort output when it attaches, and back when it goes away.
#
# This SETS the default output; it does not lock it. Nothing is written to any configuration file,
# no other sink is removed or suspended, and a change made afterwards (Steam's audio menu, KDE's
# sound settings) simply wins and stays. That matters: an eGPU is not always where you want sound,
# and software that insists is worse than software that does nothing.
#
# The sink is found by the PCI address of the eGPU's own audio function and by the port being
# AVAILABLE — not by the port's name. NVIDIA calls DisplayPort audio "hdmi-output-N" too, so a name
# match would work on one cable and fail on the other.
set -u
PREV_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/egpu-audio-previous-sink"
command -v pactl >/dev/null 2>&1 || { echo "pactl not available" >&2; exit 0; }

# The eGPU: a display-class PCI device that does not drive the built-in panel (the definition
# egpu-detect uses). Vendor-neutral on purpose.
internal_gpu_bdf() {
  local c dev
  for c in /sys/class/drm/card*-eDP-*; do
    [ -e "$c" ] || continue
    dev=$(readlink -f "${c%-eDP-*}/device" 2>/dev/null) && { basename "$dev"; return 0; }
  done
  return 1
}
egpu_bdf() {
  local d igpu; igpu=$(internal_gpu_bdf || true)
  for d in /sys/bus/pci/devices/*; do
    case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
    [ "$(basename "$d")" != "$igpu" ] || continue
    basename "$d"; return 0
  done
  return 1
}
# every audio function that sits at the same PCI slot as the eGPU (usually <slot>.1)
egpu_audio_bdfs() {
  local gpu slot d; gpu=$(egpu_bdf) || return 1; slot=${gpu%.*}
  for d in /sys/bus/pci/devices/"$slot".*; do
    [ -e "$d/class" ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x0403*) basename "$d" ;; esac
  done
}

# Pick the eGPU sink whose port is available. Prefer one that is already available over one that is
# merely present, so a monitor that is awake wins over a second, dark output on the same card.
egpu_sink() {
  local bdfs; bdfs=$(egpu_audio_bdfs) || return 1
  [ -n "$bdfs" ] || return 1
  pactl -f json list sinks 2>/dev/null | BDFS="$bdfs" python3 -c '
import json, os, sys
want = {b.strip().replace(":", "_") for b in os.environ["BDFS"].split() if b.strip()}
try:
    sinks = json.load(sys.stdin)
except Exception:
    sys.exit(1)
best = None
for s in sinks:
    props = s.get("properties") or {}
    path = (props.get("device.bus_path") or "").replace(":", "_")
    name = s.get("name") or ""
    if not any(w in path or w in name.replace(":", "_") for w in want):
        continue
    ports = s.get("ports") or []
    avail = [p for p in ports if str(p.get("availability", "")).lower().startswith("available")]
    # an available port beats anything else; among those, keep the first
    rank = 0 if avail else 1
    if best is None or rank < best[0]:
        best = (rank, name)
if best and best[0] == 0:
    print(best[1])
' 2>/dev/null
}

move_streams() {   # follow the default: existing streams should not be left behind on the old sink
  local target=$1 id
  for id in $(pactl list sink-inputs short 2>/dev/null | awk '{print $1}'); do
    pactl move-sink-input "$id" "$target" >/dev/null 2>&1 || true
  done
}

case "${1:-follow}" in
  follow)
    sink=$(egpu_sink || true)
    [ -n "${sink:-}" ] || { echo "no eGPU audio output with an available port; leaving sound as it is"; exit 0; }
    current=$(pactl get-default-sink 2>/dev/null || true)
    [ "$current" = "$sink" ] && { echo "sound is already on the eGPU output"; exit 0; }
    # remember where sound was, so detaching can put it back rather than guessing
    [ -n "$current" ] && printf '%s\n' "$current" > "$PREV_FILE" 2>/dev/null || true
    pactl set-default-sink "$sink" >/dev/null 2>&1 || { echo "could not set the default output" >&2; exit 1; }
    move_streams "$sink"
    echo "sound follows the eGPU: $sink (change it anywhere you like; it will stay changed)"
    ;;
  restore)
    prev=$(cat "$PREV_FILE" 2>/dev/null || true)
    [ -n "$prev" ] || exit 0
    # only put it back if sound is still pointing at an eGPU output that is going away
    current=$(pactl get-default-sink 2>/dev/null || true)
    sink=$(egpu_sink || true)
    if [ -z "$current" ] || [ "$current" = "${sink:-}" ] || ! pactl list sinks short 2>/dev/null | grep -q "	$current	"; then
      pactl set-default-sink "$prev" >/dev/null 2>&1 && move_streams "$prev" && echo "sound back on $prev"
    fi
    rm -f "$PREV_FILE" 2>/dev/null || true
    ;;
  status)
    echo "default: $(pactl get-default-sink 2>/dev/null)"
    echo "eGPU sink: $(egpu_sink || echo 'none with an available port')"
    ;;
  *) echo "usage: $0 follow|restore|status" >&2; exit 2 ;;
esac
