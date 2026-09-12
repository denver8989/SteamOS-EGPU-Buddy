# What is tested, what is not, and what can bite you

Everything below was verified on the single machine described in the README (Legion Go 2 + RTX 5060 Ti eGPU +
5120×1440 DisplayPort monitor, CachyOS Deckify, nvidia-open 610.57.04). "Verified" means it was exercised
repeatedly in one session on 2026-09-11/12 and behaved as described. Nothing here has been run on a second machine.

## Verified

| Feature | How it was verified |
|---|---|
| Hot-plug attach into Game Mode on the external display | replug → Game Mode on the monitor in ~22 s, repeatedly |
| Safe detach from Game Mode (plugin / `egpu-gamemode-detach`) | Game Mode back on the panel, driver unloaded, GPU off the bus |
| Surprise removal (cable yank) with the patched driver | falls back to the panel in ~5 s, driver unloads, standby OK, replug re-attaches |
| Clean Game Mode UI on the eGPU (GBM-scanout gamescope) | no striping/flicker at 5120×1440@60, confirmed visually over hours of use |
| Games launching in Game Mode on the eGPU (DX11 and DX12, Proton 11 / Proton-CachyOS / GE) | Doom: The Dark Ages, Cyberpunk 2077, Wolfenstein II |
| Steam performance overlay | shows once the WSI layer hooks the game; the switch script revives the overlay service |
| Boot with the eGPU attached | driver + DRM device up before login; autologin into Game Mode |
| Steam UI scale clamp on a 49" display | Big Picture stays at a sane scale instead of 2.4× |

## Not tested

- Any other handheld, dock, GPU generation, monitor, or distro (SteamOS itself included). The scripts detect the
  NVIDIA GPU generically, but the kernel command line, the USB4 quirks and the DPC handling are Strix Halo specific.
- HDMI output from the eGPU (only DisplayPort was used).
- HDR in Game Mode on the eGPU. It negotiates correctly (PQ, BT.2020 metadata reaches the monitor) but was not
  evaluated for picture quality; Steam's own HDR toggle did not always reach gamescope.
- Desktop-mode helpers (`steam-egpu-vk.sh`, `egpu-desktop-display-autostart.sh`, `egpu-kwin-route.sh`) date from an
  earlier phase of the project and were not re-verified in this session.
- Resume from standby with the eGPU attached and Game Mode on the monitor.

## Known limitations and risks

- **Driver patches**: `packaging/nvidia-open-egpu` rebuilds the nvidia-open kernel modules with hot-unplug patches.
  Building against a different kernel or driver version may fail or misbehave. The package is pinned via
  `IgnorePkg`; system updates will not replace it, which also means you must rebuild it yourself when you upgrade.
- **Private gamescope build**: lives in `~/.local/gamescope-gbm`. If a system library update breaks its linking, the
  session shim falls back to the distro gamescope automatically (the UI corruption returns until you rebuild).
- **Boot**: the boot enumerator loads the driver before login when a dock is present. A bad link at boot is caught
  by a flood lockout; if the screen stays black, unplug the eGPU and reboot.
- **Desktop→Game Mode switch with the eGPU attached** registered once as a surprise removal and took ~4 minutes to
  recover on its own. Avoid switching sessions while a game is running.
- **Mods that spoof AMD hardware** (OptiScaler, fakenvapi, dlssg-to-fsr3, DLSS Enabler) left in game folders will
  break games on the NVIDIA card in ways that look like driver bugs. Remove them before blaming anything here.
- **No warranty**. This project replaces kernel modules and boot configuration. If you cannot recover a machine that
  does not boot, do not install it.
