-- Legion Go 2 OLED panel definition for gamescope — source: InnoVision-Games/SteamOS-Utils (LegionGo2BrightnessSlider.py)
local lenovo_go2_oled_colorimetry = {
  r = { x = 0.6835, y = 0.3154 },
  g = { x = 0.2402, y = 0.7138 },
  b = { x = 0.1396, y = 0.0439 },
  w = { x = 0.3134, y = 0.3291 },
}

gamescope.config.known_displays.lenovo_go2_oled = {
  pretty_name = "AMS881KB01-0 OLED",
  dynamic_refresh_rates = {
    60,
    144,
  },
  hdr = {
    supported = true,
    force_enabled = true,
    eotf = gamescope.eotf.gamma22,
    max_content_light_level = 1107.128,
    max_frame_average_luminance = 475.683,
    min_content_light_level = 0.001,
  },
  colorimetry = lenovo_go2_oled_colorimetry,
  dynamic_modegen = function(base_mode, refresh)
    debug("Generating mode " .. refresh .. "Hz for AMS881KB01-0 OLED")
    local mode = base_mode

    gamescope.modegen.set_resolution(mode, 1920, 1200)
    gamescope.modegen.set_h_timings(mode, 32, 8, 40)
    if refresh == 60 then
      gamescope.modegen.set_v_timings(mode, 1904, 8, 56)
    else
      gamescope.modegen.set_v_timings(mode, 56, 8, 56)
    end
    mode.clock = gamescope.modegen.calc_max_clock(mode, refresh)
    mode.vrefresh = gamescope.modegen.calc_vrefresh(mode)

    return mode
  end,
  matches = function(display)
    if display.vendor == "SDC" and display.product == 17153 then
      return 5000
    end
    return -1
  end,
}
debug("Registered AMS881KB01-0 OLED as a known display")
