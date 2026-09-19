#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}
if [ -S "${XDG_RUNTIME_DIR}/wayland-0" ]; then
  export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
fi
export DISPLAY=${DISPLAY:-:0}

# Apply desktop display profiles without persisting gamescope/Game Mode routing.
# Profiles:
#   external-direct  external display only, external primary, best native mode.
#                    Auto mode prefers non-HDMI outputs; HDMI sinks often keep
#                    EDID alive while the TV is on another input.
#                    keeps handheld only when EGPU_KEEP_PANEL_LIFELINE=1 is set
#   auto             DP primary; HDMI secondary only when EGPU_HDMI_ACTIVE=1.
#                    If HDMI is the only eGPU output, use HDMI.
#   hdmi/tv          HDMI display only, explicit TV mode
#   hybrid           external primary, handheld enabled as secondary
#   mirror           both displays cloned at 1080p when available
#   handheld         handheld only

PANEL=${EGPU_PANEL_CONNECTOR:-eDP-1}
detect_nvidia_gpu_bdf() {
  local dev vendor class
  for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/vendor" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null || true)
    [ "$vendor" = "0x10de" ] || continue
    class=$(cat "$dev/class" 2>/dev/null || true)
    case "$class" in
      0x030000|0x030200) basename "$dev" ;;
    esac
  done | sort -V | head -n 1
}

nvidia_at_bdf() { [ "$(cat "/sys/bus/pci/devices/${1:-}/vendor" 2>/dev/null)" = "0x10de" ]; }
EGPU_PCI=${EGPU_PCI_BDF:-$(detect_nvidia_gpu_bdf)}
# The fallback address is the development handheld's slot. Take it only when it
# really holds an NVIDIA GPU — elsewhere that slot may be an unrelated device
# and must not be mistaken for an eGPU.
if [ -z "$EGPU_PCI" ] && nvidia_at_bdf 0000:62:00.0; then EGPU_PCI=0000:62:00.0; fi
KSCREEN=${KSCREEN_DOCTOR:-kscreen-doctor}

strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

ks_out() {
  "$KSCREEN" -o 2>/dev/null | strip_ansi
}

output_block() {
  local name=$1
  ks_out | awk -v name="$name" '
    /^Output:/ {
      in_block = ($3 == name)
    }
    in_block { print }
  '
}

external_connector() {
  local candidates candidate
  for candidate in $(auto_egpu_connectors); do
    if output_block "$candidate" | grep -q '^Output:'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidates=$(ks_out | awk -v panel="$PANEL" '
    /^Output:/ {
      name = $3
      is_panel = (name == panel)
      connected = 0
    }
    /connected/ && !/disconnected/ {
      connected = 1
    }
    /^Output:/ && NR > 1 {
      if (prev_name != "" && prev_connected && prev_name != panel) {
        print prev_name
        exit
      }
    }
    {
      prev_name = name
      prev_connected = connected
    }
    END {
      if (prev_name != "" && prev_connected && prev_name != panel) {
        print prev_name
      }
    }
  ')
  for candidate in $candidates; do
    if drm_output_on_egpu "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

is_hdmi_output() {
  case "$1" in HDMI-*) return 0 ;; *) return 1 ;; esac
}

connected_egpu_connectors() {
  local node base output device
  # A display belongs to an eGPU only if the card driving it is an NVIDIA GPU.
  # Enforced here as well as at resolution time, so a wrong address can never
  # hand an ordinary external display (USB-C monitor, XR glasses) to the eGPU.
  nvidia_at_bdf "$EGPU_PCI" || return 0
  for node in /sys/class/drm/card*-*; do
    [ -e "$node/status" ] || continue
    [ "$(cat "$node/status" 2>/dev/null)" = "connected" ] || continue
    base=${node##*/}
    output=$(printf '%s\n' "$base" | sed -E 's/^card[0-9]+-//')
    [ -n "$output" ] || continue
    [ "$output" != "$PANEL" ] || continue
    case "$output" in
      Writeback-*) continue ;;
    esac
    device=$(readlink -f "$node/device/device" 2>/dev/null || true)
    case "$device" in
      */"$EGPU_PCI") printf '%s\n' "$output" ;;
    esac
  done | sort -u
}

auto_egpu_connectors() {
  local output
  for output in $(connected_egpu_connectors); do
    if is_hdmi_output "$output" && [ "${EGPU_AUTO_ENABLE_HDMI:-0}" != "1" ]; then
      continue
    fi
    printf '%s\n' "$output"
  done
}

hdmi_egpu_connector() {
  local output
  for output in $(connected_egpu_connectors); do
    is_hdmi_output "$output" || continue
    printf '%s\n' "$output"
    return 0
  done
  return 1
}

dp_egpu_connector() {
  local output
  for output in $(connected_egpu_connectors); do
    is_hdmi_output "$output" && continue
    printf '%s\n' "$output"
    return 0
  done
  return 1
}

first_connected_egpu_connector() {
  local output
  for output in $(connected_egpu_connectors); do
    printf '%s\n' "$output"
    return 0
  done
  return 1
}

stage_desktop_kwin_route() {
  local helper=${EGPU_KWIN_ROUTE_HELPER:-/home/deck/.local/bin/egpu-kwin-route.sh}
  [ -x "$helper" ] || helper="$(dirname "$0")/egpu-kwin-route.sh"
  [ -x "$helper" ] && "$helper" stage >/dev/null 2>&1 || true
}

clear_desktop_kwin_route() {
  local helper=${EGPU_KWIN_ROUTE_HELPER:-/home/deck/.local/bin/egpu-kwin-route.sh}
  [ -x "$helper" ] || helper="$(dirname "$0")/egpu-kwin-route.sh"
  [ -x "$helper" ] && "$helper" clear >/dev/null 2>&1 || true
}

disable_unselected_egpu_connectors() {
  local selected=" $* " output
  for output in $(connected_egpu_connectors); do
    case "$selected" in
      *" $output "*) continue ;;
    esac
    "$KSCREEN" output."$output".disable >/dev/null 2>&1 || true
  done
}

disable_other_egpu_connectors() {
  local selected=$1 output
  for output in $(connected_egpu_connectors); do
    [ "$output" = "$selected" ] && continue
    "$KSCREEN" output."$output".disable >/dev/null 2>&1 || true
  done
}

bar1_size_bytes() {
  local start end _flags resource="/sys/bus/pci/devices/$EGPU_PCI/resource"
  [ -r "$resource" ] || { printf '0\n'; return; }
  read -r start end _flags < <(sed -n '2p' "$resource" 2>/dev/null)
  case "$start:$end" in
    0x*:0x*) ;;
    *) printf '0\n'; return ;;
  esac
  [ "$end" != "0x0000000000000000" ] || { printf '0\n'; return; }
  [ $((end)) -ge $((start)) ] || { printf '0\n'; return; }
  printf '%s\n' $((end - start + 1))
}

bar1_size_human() {
  local bytes=$1
  if [ "$bytes" -ge 1073741824 ]; then
    printf '%sGB\n' $((bytes / 1073741824))
  elif [ "$bytes" -ge 1048576 ]; then
    printf '%sMB\n' $((bytes / 1048576))
  else
    printf '%sB\n' "$bytes"
  fi
}

bar1_full() {
  [ "$(bar1_size_bytes)" -ge 17179869184 ]
}

pcie_link_state() {
  local dev="/sys/bus/pci/devices/$EGPU_PCI" speed width
  speed=$(cat "$dev/current_link_speed" 2>/dev/null || true)
  width=$(cat "$dev/current_link_width" 2>/dev/null || true)
  printf '%s x%s\n' "$speed" "$width"
}

egpu_output_connector_order() {
  local output first=1
  for output in $(auto_egpu_connectors); do
    if [ "$first" -eq 1 ]; then
      printf '%s' "$output"
      first=0
    else
      printf ',%s' "$output"
    fi
  done
  if [ "$first" -eq 1 ]; then
    for output in $(connected_egpu_connectors); do
      if [ "$first" -eq 1 ]; then
        printf '%s' "$output"
        first=0
      else
        printf ',%s' "$output"
      fi
    done
  fi
  if [ "$first" -eq 1 ]; then
    printf '*,%s\n' "$PANEL"
  else
    printf ',*,%s\n' "$PANEL"
  fi
}

sysfs_output_node() {
  local output=$1 node
  for node in /sys/class/drm/card*-"$output"; do
    [ -e "$node/status" ] || continue
    printf '%s\n' "$node"
    return 0
  done
  return 1
}

find_card_node() {
  local pci=$1 card
  for card in /sys/bus/pci/devices/"$pci"/drm/card*; do
    [ -e "$card" ] || continue
    printf '/dev/dri/%s\n' "${card##*/}"
    return 0
  done
  return 1
}

unique_existing_files() {
  local seen="" path real
  for path in "$@"; do
    [ -f "$path" ] || continue
    real=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    printf '%s\n' "$path"
  done
}

sanitize_steam_gamescope_display_config() {
  local config=$1 ts=$2 tmp
  [ -f "$config" ] || return 0
  grep -q 'External: gamescope' "$config" || return 0

  tmp=$(mktemp)
  cp "$config" "$tmp"
  NV_EGPU_STEAM_UI_MIN_SCALE=${NV_EGPU_STEAM_UI_MIN_SCALE:-0.711512446403503418} \
  NV_EGPU_STEAM_UI_MAX_SCALE=${NV_EGPU_STEAM_UI_MAX_SCALE:-3.40971922874450684} \
  NV_EGPU_STEAM_UI_SCALE=${NV_EGPU_STEAM_UI_SCALE:-1.27981042861938477} \
  perl -0pi -e '
    my $min = $ENV{"NV_EGPU_STEAM_UI_MIN_SCALE"};
    my $max = $ENV{"NV_EGPU_STEAM_UI_MAX_SCALE"};
    my $scale = $ENV{"NV_EGPU_STEAM_UI_SCALE"};

    sub set_key {
      my ($body, $key, $value, $indent) = @_;
      if ($body =~ s/(\n[ \t]*"\Q$key\E"[ \t]*")[^"]*(")/$1$value$2/s) {
        return $body;
      }
      return $body . "\n" . $indent . "\"" . $key . "\"\t\t\"" . $value . "\"";
    }

    s{(\n([ \t]*)"Current"[ \t]*\n\2\{)(.*?)(\n\2\})}{
      my ($open, $indent, $body, $close) = ($1, $2, $3, $4);
      if ($body =~ /"name"[ \t]*"External: gamescope .*?\|\|\|Windowed"/s) {
        my $key_indent = $indent . "\t";
        $body = set_key($body, "MinScaleFactor", $min, $key_indent);
        $body = set_key($body, "MaxScaleFactor", $max, $key_indent);
        $body = set_key($body, "AutoScaleFactor", $scale, $key_indent);
        $body = set_key($body, "ScaleFactor", $scale, $key_indent);
      }
      $open . $body . $close;
    }egs;
  ' "$tmp"

  if ! cmp -s "$tmp" "$config"; then
    cp "$config" "$config.bak-nv-egpu-gamescope-display-$ts"
    cat "$tmp" > "$config"
    chown deck:deck "$config" 2>/dev/null || true
  fi
  rm -f "$tmp"
}

sanitize_steam_gamescope_display_settings() {
  local registry config ts tmp
  ts=$(date +%Y%m%d_%H%M%S)

  while IFS= read -r registry; do
    [ -n "$registry" ] || continue
    if grep -q '"GamescopeEnableAppTargetRefreshRate2"[[:space:]]*"1"' "$registry"; then
      cp "$registry" "$registry.bak-nv-egpu-refresh-$ts"
      perl -0pi -e 's/"GamescopeEnableAppTargetRefreshRate2"\s*"1"/"GamescopeEnableAppTargetRefreshRate2"\t\t"0"/g' "$registry"
      chown deck:deck "$registry" 2>/dev/null || true
    fi
  done <<EOF
$(unique_existing_files \
  /home/deck/.steam/registry.vdf \
  /home/deck/.local/share/Steam/registry.vdf)
EOF

  while IFS= read -r config; do
    [ -n "$config" ] || continue
    sanitize_steam_gamescope_display_config "$config" "$ts"
    if grep -q '"769"' "$config"; then
      tmp=$(mktemp)
      cp "$config" "$tmp"
      perl -0pi -e 's/\n(\t*)"App"\n\1\{\n\1\t"769"\n\1\t\{\n\1\t\t"0"\n\1\t\t\{\n\1\t\t\t"0"\t\t"[0-9A-Fa-f]+"\n\1\t\t\}\n\1\t\}\n\1\}//' "$tmp" 2>/dev/null || true
      if ! cmp -s "$tmp" "$config"; then
        cp "$config" "$config.bak-nv-egpu-refresh-$ts"
        cat "$tmp" > "$config"
        chown deck:deck "$config" 2>/dev/null || true
      fi
      rm -f "$tmp"
    fi
  done <<EOF
$(unique_existing_files \
  /home/deck/.local/share/Steam/config/config.vdf \
  /home/deck/.steam/steam/config/config.vdf)
EOF
}

stage_gamescope_env() {
  local conf_dir="/home/deck/.config/environment.d"
  local conf_file="$conf_dir/10-egpu-gamescope-output.conf"

  mkdir -p "$conf_dir"
  cat > "$conf_file" <<EOF
# NV-EGPU-Buddy - intentionally inert Game Mode environment placeholder.
#
# Do not set OUTPUT_CONNECTOR or KWIN_DRM_DEVICES here. The scoped
# nv-egpu-gamescope-session wrapper detects the current NVIDIA-owned connector
# at launch, stages the ultrawide mode, and exports NVIDIA routing only to that
# Gamescope session. Persisting these values globally can black-screen boot,
# poison Desktop sessions, or re-enable NVIDIA Gamescope HDR corruption.
EOF
  chown -R deck:deck "$conf_dir" 2>/dev/null || true
  # UNSET, never "set to empty": an exported but empty VK_DRIVER_FILES is a driver list with no entries, and the Vulkan
  # loader then reports "Found no drivers" — every Vulkan game fails to start. Verified on the development machine.
  systemctl --user unset-environment \
    OUTPUT_CONNECTOR \
    KWIN_DRM_DEVICES \
    VK_DRIVER_FILES \
    VK_ICD_FILENAMES \
    __EGL_VENDOR_LIBRARY_FILENAMES \
    __GLX_VENDOR_LIBRARY_NAME \
    PROTON_ENABLE_NVAPI \
    DXVK_ENABLE_NVAPI \
    PROTON_HIDE_NVIDIA_GPU \
    DXVK_HDR \
    STEAM_DISPLAY_REFRESH_LIMITS >/dev/null 2>&1 || true
  systemctl --user unset-environment \
    OUTPUT_CONNECTOR \
    KWIN_DRM_DEVICES \
    VK_DRIVER_FILES \
    VK_ICD_FILENAMES \
    __EGL_VENDOR_LIBRARY_FILENAMES \
    __GLX_VENDOR_LIBRARY_NAME \
    PROTON_ENABLE_NVAPI \
    DXVK_ENABLE_NVAPI \
    PROTON_HIDE_NVIDIA_GPU \
    DXVK_HDR \
    STEAM_DISPLAY_REFRESH_LIMITS \
    STEAM_GAMESCOPE_FORCE_HDR_DEFAULT \
    STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT >/dev/null 2>&1 || true
  # UNSET, never "set to empty": an exported but empty VK_DRIVER_FILES is a driver list with no entries, and the Vulkan
  # loader then reports "Found no drivers" — every Vulkan game fails to start. Verified on the development machine.
  systemctl --user unset-environment \
    OUTPUT_CONNECTOR \
    KWIN_DRM_DEVICES \
    VK_DRIVER_FILES \
    VK_ICD_FILENAMES \
    __EGL_VENDOR_LIBRARY_FILENAMES \
    __GLX_VENDOR_LIBRARY_NAME \
    PROTON_ENABLE_NVAPI \
    DXVK_ENABLE_NVAPI \
    PROTON_HIDE_NVIDIA_GPU \
    DXVK_HDR \
    STEAM_DISPLAY_REFRESH_LIMITS >/dev/null 2>&1 || true
  sanitize_steam_gamescope_display_settings
}

best_sysfs_mode() {
  local output=$1 node
  node=$(sysfs_output_node "$output" || true)
  [ -n "$node" ] || return 1
  [ -r "$node/modes" ] || return 1
  awk '
    match($0, /^([0-9]+)x([0-9]+)$/, m) {
      w = m[1] + 0
      h = m[2] + 0
      score = (w * 1000000000) + (w * h)
      if (score > best_score) {
        best_score = score
        best_w = w
        best_h = h
      }
    }
    END {
      if (best_w != "") {
        print best_w " " best_h
      }
    }
  ' "$node/modes"
}

drm_output_on_egpu() {
  local output=$1 node device
  for node in /sys/class/drm/card*-"$output"; do
    [ -e "$node/status" ] || continue
    [ "$(cat "$node/status" 2>/dev/null)" = "connected" ] || continue
    device=$(readlink -f "$node/device/device" 2>/dev/null || true)
    case "$device" in
      */"$EGPU_PCI") return 0 ;;
    esac
  done
  return 1
}

best_mode() {
  local output=$1
  output_block "$output" | awk '
    /Modes:/ {
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/\*/, "", token)
        gsub(/!/, "", token)
        if (match(token, /^([0-9]+):([0-9]+)x([0-9]+)@([0-9.]+)/, m)) {
          id = m[1]
          w = m[2] + 0
          h = m[3] + 0
          hz = m[4] + 0
          # Prefer the widest mode first. Some 32:9 displays expose
          # 3840x2160 TV modes, but the real desktop-native mode is 5120x1440.
          score = (w * 1000000000) + (w * h * 1000) + hz
          if (score > best_score) {
            best_score = score
            best_id = id
            best_w = w
            best_h = h
            best_hz = hz
          }
        }
      }
    }
    END {
      if (best_id != "") {
        print best_id " " best_w " " best_h " " best_hz
      }
    }
  '
}

mode_id_for_resolution() {
  local output=$1
  local resolution=$2
  output_block "$output" | awk -v res="$resolution" '
    /Modes:/ {
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/\*/, "", token)
        gsub(/!/, "", token)
        if (token ~ "^[0-9]+:" res "@") {
          split(token, parts, ":")
          print parts[1]
          exit
        }
      }
    }
  '
}

apply_external_mode() {
  local external=$1
  local best
  best=$(best_mode "$external" || true)
  if [ -n "$best" ]; then
    set -- $best
    "$KSCREEN" output."$external".mode."$1" >/dev/null 2>&1 || true
    printf '%s %s %s\n' "$2" "$3" "${4:-}"
  else
    printf '1920 1080\n'
  fi
}

output_enabled() {
  local output=$1
  local node
  node=$(sysfs_output_node "$output" || true)
  if [ -n "$node" ]; then
    [ "$(cat "$node/enabled" 2>/dev/null)" = "enabled" ]
    return
  fi
  output_block "$output" | grep -q 'enabled'
}

best_drm_mode() {
  local output=$1
  command -v modetest >/dev/null 2>&1 || return 1
  modetest -c 2>/dev/null | awk -v output="$output" '
    $0 ~ "connected[[:space:]]+" output "[[:space:]]" {
      in_connector = 1
      next
    }
    in_connector && /^  props:/ {
      exit
    }
    in_connector && /^  #[0-9]+/ {
      refresh = $3 + 0
      width = $4 + 0
      height = $8 + 0
      score = (width * 1000000000) + (width * height * 1000) + refresh
      if (score > best_score) {
        best_score = score
        best_width = width
        best_height = height
        best_refresh = refresh
      }
    }
    END {
      if (best_width != "") {
        printf "%s %s %.0f\n", best_width, best_height, best_refresh
      }
    }
  '
}

gamescope_ui_drm_mode() {
  local output=$1
  command -v modetest >/dev/null 2>&1 || return 1
  modetest -c 2>/dev/null | awk -v output="$output" -v native_ultrawide="${EGPU_GAMESCOPE_NATIVE_ULTRAWIDE:-0}" '
    $0 ~ "connected[[:space:]]+" output "[[:space:]]" {
      in_connector = 1
      next
    }
    in_connector && /^  props:/ {
      in_connector = 0
    }
    in_connector && /^  #[0-9]+/ {
      count++
      refresh[count] = $3 + 0
      width[count] = $4 + 0
      height[count] = $8 + 0
      clock[count] = $12 + 0
      native_score = (width[count] * 1000000000) + (width[count] * height[count] * 1000) + refresh[count]
      if (native_score > best_native_score) {
        best_native_score = native_score
        native_index = count
      }
    }
    END {
      if (!native_index) {
        exit 1
      }

      native_w = width[native_index]
      native_h = height[native_index]
      native_r = refresh[native_index]

      # Steam/Game Mode can mis-scale when a 32:9 panel is changed live. Keep
      # the physical output ultrawide and stage the panel real timing before
      # gamescope starts instead of changing it from the live Game Mode UI.
      if ((native_w * 9) <= (native_h * 21)) {
        printf "%s %s %.0f native\n", native_w, native_h, native_r
        exit
      }

      if (output ~ /^HDMI-/) {
        # Preserve a real 32:9 KMS timing. Non-EDID 3840x1080 requests fall
        # back to the monitor preferred 1920x1080 mode in embedded gamescope.
        # The lower-risk fallback for this monitor is a smaller nested Steam
        # canvas, injected by nv-egpu-gamescope-shim, over real 5120x1440@60.
        if (native_w >= 5120 && native_h == 1440) {
          for (i = 1; i <= count; i++) {
            if (width[i] != native_w || height[i] != native_h || refresh[i] > 60 || clock[i] > 600000) {
              continue
            }
            score = 4000000000 + refresh[i] - clock[i]
            if (score > fallback_score) {
              fallback_score = score
              fallback_w = width[i]
              fallback_h = height[i]
              fallback_r = refresh[i]
            }
          }
          if (fallback_w != "") {
            printf "%s %s %.0f hdmi-safe-ultrawide\n", fallback_w, fallback_h, fallback_r
            exit
          }
        }

        for (i = 1; i <= count; i++) {
          if (width[i] != native_w || height[i] != native_h) {
            continue
          }
          if (clock[i] <= 600000) {
            score = 4000000000 + refresh[i]
          } else {
            score = 1000000000 - clock[i]
          }
          if (score > hdmi_score) {
            hdmi_score = score
            hdmi_w = width[i]
            hdmi_h = height[i]
            hdmi_r = refresh[i]
          }
        }
        if (hdmi_w != "") {
          printf "%s %s %.0f hdmi-safe-ultrawide\n", hdmi_w, hdmi_h, hdmi_r
          exit
        }
      }

      for (i = 1; i <= count; i++) {
        if (width[i] != native_w || height[i] != native_h) {
          continue
        }
        score = 4000000000 + refresh[i]
        if (score > ultrawide_score) {
          ultrawide_score = score
          ultrawide_w = width[i]
          ultrawide_h = height[i]
          ultrawide_r = refresh[i]
        }
      }

      if (ultrawide_w != "") {
        printf "%s %s %.0f ultrawide-ui\n", ultrawide_w, ultrawide_h, ultrawide_r
      } else {
        printf "%s %s %.0f native\n", native_w, native_h, native_r
      }
    }
  '
}

repair_kwin_hdr_config() {
  local output=$1 config="${KWIN_OUTPUT_CONFIG:-/home/deck/.config/kwinoutputconfig.json}"
  [ -f "$config" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local tmp
  tmp=$(mktemp)
  if jq --arg connector "$output" '
    map(
      if .name == "outputs" then
        .data |= map(
          if .connectorName == $connector then
            . + {
              "highDynamicRange": true,
              "wideColorGamut": true,
              "edrPolicy": "always",
              "colorPowerTradeoff": "PreferAccuracy",
              "allowSdrSoftwareBrightness": true,
              "sdrBrightness": (.sdrBrightness // 200),
              "maxPeakBrightnessOverride": (.maxPeakBrightnessOverride // 1000)
            }
          else
            .
          end
        )
      else
        .
      end
    )
  ' "$config" > "$tmp"; then
    if ! cmp -s "$tmp" "$config"; then
      cp "$config" "$config.bak-nv-egpu-hdr-$(date +%Y%m%d_%H%M%S)"
      cat "$tmp" > "$config"
      qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$tmp"
}

refresh_gamescope_display_cache() {
  local output=$1 node edid product mode width height refresh cfg
  node=$(sysfs_output_node "$output" || true)
  [ -n "$node" ] || return 0
  [ -r "$node/edid" ] || return 0
  mkdir -p /home/deck/.config/gamescope
  cp "$node/edid" /home/deck/.config/gamescope/edid.bin 2>/dev/null || true
  chown deck:deck /home/deck/.config/gamescope /home/deck/.config/gamescope/edid.bin 2>/dev/null || true

  product=$(edid-decode "$node/edid" 2>/dev/null | awk -F"'" '/Display Product Name:/ { print $2; exit }')
  [ -n "$product" ] || product=$output
  mode=$(gamescope_ui_drm_mode "$output" || true)
  [ -n "$mode" ] || mode=$(best_sysfs_mode "$output" || true)
  [ -n "$mode" ] || return 0
  set -- $mode
  width=$1
  height=$2
  refresh=${3:-60}
  cfg=/home/deck/.config/gamescope/modes.cfg
  if [ -f "$cfg" ]; then
    awk -F: -v product="$product" -v value="${width}x${height}@${refresh}" '
      index($1, product) {
        print $1 ":" value
        found = 1
        next
      }
      { print }
      END {
        if (!found) {
          print product ":" value
        }
      }
    ' "$cfg" > "$cfg.tmp"
    mv "$cfg.tmp" "$cfg"
  else
    printf '%s:%sx%s@%s\n' "$product" "$width" "$height" "$refresh" > "$cfg"
  fi
  chown deck:deck "$cfg" 2>/dev/null || true
}

repair_hdr_state() {
  local external=$1
  [ -n "$external" ] || return 0
  stage_gamescope_env
  repair_kwin_hdr_config "$external"
  refresh_gamescope_display_cache "$external"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

status_json() {
  local external output_order best mode_id width height refresh game_mode game_width game_height game_refresh game_reason panel_enabled risk reason handheld_bottleneck bandwidth_bottleneck bar1_bytes bar1_human full_bandwidth pcie_link
  external=$(first_connected_egpu_connector || true)
  [ -n "$external" ] || external=$(external_connector || true)
  output_order=$(egpu_output_connector_order)
  bar1_bytes=$(bar1_size_bytes)
  bar1_human=$(bar1_size_human "$bar1_bytes")
  pcie_link=$(pcie_link_state)
  full_bandwidth=false
  bar1_full && full_bandwidth=true
  if [ -z "$external" ]; then
    reason="No connected NVIDIA-attached external display found. Presenting games on the handheld/iGPU display recreates the cross-GPU copy bottleneck."
    printf '{"success":false,"external":"","panel":"%s","output_connector_order":"%s","native_resolution":"","refresh_hz":"","mode_id":"","bar1_size":"%s","bar1_bytes":%s,"pcie_link":"%s","full_bandwidth":%s,"bandwidth_bottleneck":true,"bottleneck_risk":"critical","handheld_display_bottleneck":true,"reason":"%s"}\n' \
      "$(json_escape "$PANEL")" "$(json_escape "$output_order")" "$(json_escape "$bar1_human")" "$bar1_bytes" "$(json_escape "$pcie_link")" "$full_bandwidth" "$(json_escape "$reason")"
    return 1
  fi
  best=""
  mode_id=""
  width=""
  height=""
  refresh=""
  if best=$(best_drm_mode "$external" || true); then
    if [ -n "$best" ]; then
      set -- $best
      width=$1
      height=$2
      refresh=${3:-}
      best="drm $width $height $refresh"
    fi
  fi
  if [ -z "$best" ] && best=$(best_sysfs_mode "$external" || true); then
    if [ -n "$best" ]; then
      set -- $best
      width=$1
      height=$2
      best="sysfs $width $height"
    fi
  fi
  game_mode=$(gamescope_ui_drm_mode "$external" || true)
  game_width=""
  game_height=""
  game_refresh=""
  game_reason=""
  if [ -n "$game_mode" ]; then
    set -- $game_mode
    game_width=$1
    game_height=$2
    game_refresh=${3:-}
    game_reason=${4:-}
  fi
  panel_enabled=false
  if output_enabled "$PANEL"; then
    panel_enabled=true
  fi
  handheld_bottleneck=false
  bandwidth_bottleneck=false
  if [ "$full_bandwidth" != true ]; then
    risk="high"
    bandwidth_bottleneck=true
    reason="The NVIDIA-attached external output is available, but BAR1 is $bar1_human instead of 16GB. This is a degraded eGPU state and should not be used as full-bandwidth Game Mode."
  elif [ "$panel_enabled" = true ]; then
    risk="medium"
    handheld_bottleneck=true
    reason="The NVIDIA-attached external output is available, but the handheld panel is enabled. Use external-direct for the lowest-risk game-present path."
  else
    risk="low"
    reason="The selected output is attached to the NVIDIA eGPU and the handheld panel is disabled."
  fi
  printf '{"success":true,"external":"%s","panel":"%s","output_connector_order":"%s","native_resolution":"%s","refresh_hz":"%s","game_mode_resolution":"%s","game_mode_refresh_hz":"%s","game_mode_reason":"%s","mode_id":"%s","best_mode":"%s","bar1_size":"%s","bar1_bytes":%s,"pcie_link":"%s","full_bandwidth":%s,"bandwidth_bottleneck":%s,"bottleneck_risk":"%s","handheld_display_bottleneck":%s,"reason":"%s"}\n' \
    "$(json_escape "$external")" "$(json_escape "$PANEL")" "$(json_escape "$output_order")" \
    "$(json_escape "${width:+$width x $height}")" "$(json_escape "$refresh")" \
    "$(json_escape "${game_width:+$game_width x $game_height}")" "$(json_escape "$game_refresh")" "$(json_escape "$game_reason")" \
    "$(json_escape "$mode_id")" "$(json_escape "$best")" "$(json_escape "$bar1_human")" "$bar1_bytes" "$(json_escape "$pcie_link")" "$full_bandwidth" "$bandwidth_bottleneck" "$(json_escape "$risk")" "$handheld_bottleneck" "$(json_escape "$reason")"
}

profile=${1:-status}
case "$profile" in
  status)
    status_json
    ;;
  auto)
    primary=$(dp_egpu_connector || true)
    hdmi=$(hdmi_egpu_connector || true)
    [ -n "$primary" ] || primary=$hdmi
    [ -n "$primary" ] || { echo "No connected external display found." >&2; exit 2; }

    read -r width _height < <(apply_external_mode "$primary")
    "$KSCREEN" output."$primary".enable output."$primary".priority.1 output."$primary".scale.1 output."$primary".position.0,0

    enabled="$primary"
    if [ -n "$hdmi" ] && [ "$hdmi" != "$primary" ] && [ "${EGPU_HDMI_ACTIVE:-0}" = "1" ]; then
      read -r hdmi_width _hdmi_height < <(apply_external_mode "$hdmi")
      "$KSCREEN" output."$hdmi".enable output."$hdmi".priority.2 output."$hdmi".scale.1 output."$hdmi".position."$width",0
      enabled="$enabled $hdmi"
      repair_hdr_state "$hdmi"
    fi

    disable_unselected_egpu_connectors $enabled
    if [ "${EGPU_KEEP_PANEL_LIFELINE:-0}" = "1" ]; then
      "$KSCREEN" output."$PANEL".enable output."$PANEL".scale.1.5 output."$PANEL".position."$width",0 >/dev/null 2>&1 || true
      panel_state="handheld lifeline enabled"
    else
      "$KSCREEN" output."$PANEL".disable >/dev/null 2>&1 || true
      panel_state="handheld disabled"
    fi
    repair_hdr_state "$primary"
    stage_desktop_kwin_route
    echo "Auto display applied: enabled [$enabled], $panel_state."
    ;;
  external-direct)
    external=$(external_connector || true)
    [ -n "$external" ] || { echo "No connected external display found." >&2; exit 2; }
    read -r width _height < <(apply_external_mode "$external")
    "$KSCREEN" output."$external".enable output."$external".priority.1 output."$external".scale.1 output."$external".position.0,0
    disable_other_egpu_connectors "$external"
    if [ "${EGPU_KEEP_PANEL_LIFELINE:-0}" = "1" ]; then
      "$KSCREEN" output."$PANEL".enable output."$PANEL".scale.1.5 output."$PANEL".position."$width",0 >/dev/null 2>&1 || true
      panel_state="handheld lifeline enabled"
    else
      "$KSCREEN" output."$PANEL".disable >/dev/null 2>&1 || true
      panel_state="handheld disabled"
    fi
    repair_hdr_state "$external"
    stage_desktop_kwin_route
    echo "External Direct applied on $external with $panel_state; HDR/WCG state refreshed."
    ;;
  hdmi|tv)
    external=$(hdmi_egpu_connector || true)
    [ -n "$external" ] || { echo "No connected HDMI display found." >&2; exit 2; }
    read -r width _height < <(apply_external_mode "$external")
    "$KSCREEN" output."$external".enable output."$external".priority.1 output."$external".scale.1 output."$external".position.0,0
    disable_other_egpu_connectors "$external"
    if [ "${EGPU_KEEP_PANEL_LIFELINE:-0}" = "1" ]; then
      "$KSCREEN" output."$PANEL".enable output."$PANEL".scale.1.5 output."$PANEL".position."$width",0 >/dev/null 2>&1 || true
      panel_state="handheld lifeline enabled"
    else
      "$KSCREEN" output."$PANEL".disable >/dev/null 2>&1 || true
      panel_state="handheld disabled"
    fi
    repair_hdr_state "$external"
    stage_desktop_kwin_route
    echo "HDMI TV display applied on $external with $panel_state; other eGPU outputs disabled."
    ;;
  hybrid|extend)
    external=$(external_connector || true)
    [ -n "$external" ] || { echo "No connected external display found." >&2; exit 2; }
    read -r width _height < <(apply_external_mode "$external")
    "$KSCREEN" output."$external".enable output."$external".priority.1 output."$external".scale.1 output."$external".position.0,0
    disable_other_egpu_connectors "$external"
    "$KSCREEN" output."$PANEL".enable output."$PANEL".scale.1.5 output."$PANEL".position."$width",0
    repair_hdr_state "$external"
    stage_desktop_kwin_route
    echo "Hybrid display applied on $external with handheld secondary; HDR/WCG state refreshed."
    ;;
  mirror)
    external=$(external_connector || true)
    [ -n "$external" ] || { echo "No connected external display found." >&2; exit 2; }
    ext_1080=$(mode_id_for_resolution "$external" "1920x1080" || true)
    panel_1080=$(mode_id_for_resolution "$PANEL" "1920x1080" || true)
    "$KSCREEN" output."$external".enable output."$external".priority.1 output."$external".scale.1 output."$external".position.0,0
    disable_other_egpu_connectors "$external"
    [ -n "$ext_1080" ] && "$KSCREEN" output."$external".mode."$ext_1080" >/dev/null 2>&1 || true
    "$KSCREEN" output."$PANEL".enable output."$PANEL".scale.1 output."$PANEL".position.0,0
    [ -n "$panel_1080" ] && "$KSCREEN" output."$PANEL".mode."$panel_1080" >/dev/null 2>&1 || true
    stage_desktop_kwin_route
    echo "Mirror display applied on $external and $PANEL."
    ;;
  hdr-repair)
    external=$(first_connected_egpu_connector || true)
    [ -n "$external" ] || external=$(external_connector || true)
    [ -n "$external" ] || { echo "No connected external display found." >&2; exit 2; }
    repair_hdr_state "$external"
    echo "HDR/WCG state refreshed for $external."
    ;;
  handheld)
    external=$(external_connector || true)
    "$KSCREEN" output."$PANEL".enable output."$PANEL".priority.1 output."$PANEL".scale.1.5
    for external in $(connected_egpu_connectors); do
      "$KSCREEN" output."$external".disable >/dev/null 2>&1 || true
    done
    clear_desktop_kwin_route
    echo "Handheld display applied."
    ;;
  *)
    echo "Unknown display profile: $profile" >&2
    exit 2
    ;;
esac
