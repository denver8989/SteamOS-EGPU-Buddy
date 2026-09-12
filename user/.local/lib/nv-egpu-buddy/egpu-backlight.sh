#!/bin/bash
# Shared handheld-panel darkening for the external-primary research policy.
#
# To keep eDP-1 (the AMD iGPU panel) as a live compositor scanout anchor while the
# eGPU TV output is primary, we turn the panel's BACKLIGHT off rather than disabling
# the output. The CRTC stays active, but a later live test proved this alone does
# not guarantee recovery when the eGPU vanishes. Undarken restores the saved
# brightness (the failover promoter and safe-detach both call it).
#
# Pure selection logic (egpu_pick_backlight) is split out so it is testable offline
# without any /sys access. Override EGPU_BL_SYS to point at a fixture in tests.

EGPU_BL_SYS=${EGPU_BL_SYS:-/sys/class/backlight}

egpu_bl_state_file() {
  printf '%s/egpu-edp-backlight' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
}

# Choose the AMD panel backlight from a newline-separated list of candidate names
# on stdin. Prefer an `amdgpu_bl*` device; otherwise fall back to the first entry.
egpu_pick_backlight() {
  awk '
    /^amdgpu_bl/ { print; found = 1; exit }
    { cand[NR] = $0 }
    END { if (!found && NR > 0) print cand[1] }
  '
}

egpu_backlight_dir() {
  [ -d "$EGPU_BL_SYS" ] || return 1
  local name
  name=$(ls -1 "$EGPU_BL_SYS" 2>/dev/null | egpu_pick_backlight)
  [ -n "$name" ] || return 1
  printf '%s/%s' "$EGPU_BL_SYS" "$name"
}

# Save the current brightness and turn the backlight off. Idempotent: if the panel
# is already dark we keep the previously saved (non-zero) value so undarken can
# still restore a sensible level.
egpu_darken_handheld() {
  local dir cur state; dir=$(egpu_backlight_dir) || return 1
  cur=$(cat "$dir/brightness" 2>/dev/null) || return 1
  state=$(egpu_bl_state_file)
  if [ "$cur" != "0" ]; then
    printf '%s' "$cur" > "$state" 2>/dev/null || true
  fi
  echo 0 > "$dir/brightness" 2>/dev/null
}

# Restore the saved brightness (or max if no sane saved value exists) and clear the
# saved-state file.
egpu_undarken_handheld() {
  local dir saved max state; dir=$(egpu_backlight_dir) || return 1
  state=$(egpu_bl_state_file)
  [ -r "$state" ] && saved=$(cat "$state" 2>/dev/null)
  if [ -z "${saved:-}" ] || [ "$saved" = "0" ]; then
    max=$(cat "$dir/max_brightness" 2>/dev/null)
    saved=${max:-1}
  fi
  echo "$saved" > "$dir/brightness" 2>/dev/null
  rm -f "$state" 2>/dev/null || true
}
