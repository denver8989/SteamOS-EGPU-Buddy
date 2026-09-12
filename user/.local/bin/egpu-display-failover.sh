#!/bin/bash
# Best-effort eGPU display failover.
#
# This watcher promotes eDP-1 to the usable foreground when the eGPU disappears.
# It handles both an enabled/darkened secondary panel and a fully disabled panel,
# but only while KWin remains responsive. A later live cycle froze even with the
# internal panel available, so this is not considered proven surprise-unplug
# recovery.
# Read-only on the eGPU (sysfs attribute reads only — NEVER pokes config space).
set -u
# shellcheck source=scripts/lib/egpu-backlight.sh
RUNTIME_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BACKLIGHT_LIB=${EGPU_BACKLIGHT_LIB:-$RUNTIME_DIR/../lib/egpu-backlight.sh}
[ -r "$BACKLIGHT_LIB" ] ||
  BACKLIGHT_LIB="${HOME:-/home/deck}/.local/lib/nv-egpu-buddy/egpu-backlight.sh"
[ -r "$BACKLIGHT_LIB" ] || {
  echo "Missing required eGPU backlight helper: $BACKLIGHT_LIB" >&2
  exit 1
}
. "$BACKLIGHT_LIB"
PCI_DEVICES=${EGPU_PCI_DEVICES:-/sys/bus/pci/devices}
DEFAULT_GPU=0000:62:00.0
GPU_OVERRIDE=${EGPU_GPU_BDF:-${EGPU_PCI_BDF:-}}
GPU=${GPU_OVERRIDE:-}
EGPU=

detect_nvidia_gpu_bdf() {
  local dev vendor class
  for dev in "$PCI_DEVICES"/*; do
    [ -r "$dev/vendor" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null || true)
    [ "$vendor" = "0x10de" ] || continue
    class=$(cat "$dev/class" 2>/dev/null || true)
    case "$class" in
      0x030000|0x030200) basename "$dev" ;;
    esac
  done | sort -V | head -n 1
}

refresh_gpu_target() {
  local detected
  if [ -n "$GPU_OVERRIDE" ]; then
    GPU=$GPU_OVERRIDE
  else
    detected=$(detect_nvidia_gpu_bdf || true)
    [ -z "$detected" ] || GPU=$detected
    [ -n "$GPU" ] || GPU=$DEFAULT_GPU
  fi
  EGPU=$PCI_DEVICES/$GPU
}

egpu_alive() {
  refresh_gpu_target
  [ -e "$EGPU" ] || return 1
  local w; w=$(cat "$EGPU/current_link_width" 2>/dev/null)
  case "$w" in 4|8|16) return 0 ;; *) return 1 ;; esac
}

kwin_ready() {
  local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -n "${WAYLAND_DISPLAY:-}" ] || return 1
  [ -S "$runtime/$WAYLAND_DISPLAY" ] || return 1
  command -v qdbus6 >/dev/null 2>&1 || return 1
  timeout 2 qdbus6 org.kde.KWin /KWin org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
}

edp_disabled_from_json() {
  jq -e '.outputs[] | select(.name == "eDP-1") | .enabled == false' \
    >/dev/null
}

# eDP-1 needs to be promoted to the usable foreground when it is present in the
# layout but is NOT both enabled and primary. This covers two cases:
#   * legacy: eDP-1 fully disabled (the old external-only teardown), and
#   * external-primary: eDP-1 enabled as the darkened anchor but still secondary
#     (HDMI-A-1 held primary and has now gone away).
# A missing eDP-1 entry returns non-zero (no action): KWin does not see the panel,
# so there is nothing safe to promote. Accept either the Plasma 6 `priority == 1`
# primary marker or a legacy `primary == true` boolean.
edp_needs_foreground_from_json() {
  jq -e '
    [.outputs[] | select(.name == "eDP-1")] as $e
    | if ($e | length) == 0 then false
      else ($e[0].enabled == true
             and (($e[0].priority == 1) or ($e[0].primary == true))) | not
      end
  ' >/dev/null
}

edp_needs_foreground() {
  # Parse the exact output state. Text output also contains unrelated features
  # such as "Automatic brightness: disabled".
  local output
  output=$(timeout 6 kscreen-doctor -j 2>/dev/null) || return 1
  edp_needs_foreground_from_json <<< "$output"
}

ksd() { timeout 8 kscreen-doctor "$@" >/dev/null 2>&1; }

main() {
  local waiting_logged=0 failure_logged=0
  logger -t egpu-failover "failover watcher started"
  while true; do
    # Do not compete with the deliberate Safe Detach panel/KWin handoff.
    if [ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/nv-egpu-buddy/detach-handoff-active" ]; then
      sleep 2
      continue
    fi
    if ! kwin_ready; then
      if [ "$waiting_logged" -eq 0 ]; then
        logger -t egpu-failover "waiting for a responsive Wayland/KWin session; not calling kscreen-doctor"
        waiting_logged=1
      fi
      sleep 5
      continue
    fi
    if [ "$waiting_logged" -eq 1 ]; then
      logger -t egpu-failover "Wayland/KWin session ready"
      waiting_logged=0
    fi

    if ! egpu_alive && edp_needs_foreground; then
      # Promote the handheld panel to the foreground: enable (no-op if already
      # enabled), make primary, restore scale, and DPMS on to undarken it. The
      # sequence is idempotent and converges, so the predicate stops matching once
      # eDP-1 is the usable primary output.
      if ksd output.eDP-1.enable output.eDP-1.priority.1 output.eDP-1.scale.1.5 &&
         ksd --dpms on; then
        # Undarken: the anchor was backlight-off while the eGPU was primary.
        egpu_undarken_handheld
        logger -t egpu-failover "eGPU absent/dead while eDP-1 was not foreground -> promoted handheld panel to primary"
        failure_logged=0
      elif [ "$failure_logged" -eq 0 ]; then
        logger -t egpu-failover "KWin did not accept handheld-panel recovery"
        failure_logged=1
      fi
      sleep 5
    fi
    sleep 2
  done
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main
