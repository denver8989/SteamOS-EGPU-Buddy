# SteamOS EGPU Buddy

Hot-pluggable NVIDIA eGPU on a Linux gaming handheld, in **Game Mode**, on par with Windows: plug in and Game Mode
moves to the monitor, unplug (safely or by yanking the cable) and it falls back to the handheld panel, replug and
it comes back. Includes the fixes for the three things that made this unusable before: the NVIDIA scan-out
corruption in gamescope, the driver hang on surprise removal, and games freezing at the loading screen.

**Status: works on exactly one machine (mine). Everything else is untested. Read [TESTED.md](TESTED.md) before you
run anything. This touches the kernel driver, boot configuration, udev, sudoers and your Game Mode session. Use at
your own risk, keep a way to boot without the eGPU, and read the scripts before running them.**

## Tested hardware and software

| Part | Tested configuration |
|---|---|
| Handheld | Lenovo Legion Go 2 (AMD Strix Halo, USB4/Thunderbolt 5) |
| eGPU | Gigabyte AORUS AI Box, NVIDIA RTX 5060 Ti 16 GB (Blackwell) |
| Display | Acer Predator X49 V, 5120×1440 super-ultrawide, DisplayPort |
| Distro | CachyOS (Deckify), kernel `linux-cachyos-deckify` 7.1.8 |
| Driver | `nvidia-open` 610.57.04 with the patches in `packaging/nvidia-open-egpu` |
| gamescope | 3.16.23 (distro) for the handheld; 3.16.25 + GBM-scanout branch for the eGPU (built by the installer) |
| Steam | Game Mode via `gamescope-session` + plasmalogin autologin; Decky Loader for the plugin |

An RTX 3080 (Ampere) on driver 580 was used during earlier development; that combination is not covered by the
current scripts.

## What you get

- **Auto-attach**: udev sees the eGPU, the driver loads fresh, Game Mode restarts on the external display.
- **Safe detach** (Decky plugin button or `egpu-gamemode-detach`): Game Mode moves back to the panel, the GPU is
  removed from the bus cleanly, the driver unloads. Standby works afterwards.
- **Surprise removal** (cable yank): the patched driver survives it, the session recovers to the panel in a few
  seconds, replug re-attaches.
- **Clean Game Mode UI on NVIDIA**: gamescope built with GBM-allocated scan-out buffers, which sidesteps NVIDIA
  bug 5240452 (Vulkan-allocated scan-out buffers land in scattered video memory and the display engine reads
  garbage; see [docs/ROOT-CAUSES.md](docs/ROOT-CAUSES.md)).
- **Games actually launch**: the Steam launcher environment is cleaned so gamescope's WSI layer hooks games again
  after a desktop→Game Mode switch (the stray `WAYLAND_DISPLAY` bug), and the Steam UI scale is clamped so Big
  Picture is not rendered at 2.4× on a 49" display.
- **Boot into Game Mode with the eGPU attached**: the card is enumerated before login; a flood lockout prevents a
  reboot loop if the link misbehaves.
- **EGPU Buddy Decky plugin**: attach, safe detach, status, and power/clock controls (only when Game Mode runs on
  the eGPU; the handheld's own power management is left alone on the iGPU).
- **EGPU Buddy desktop app**: the same controls for the docked Desktop, in a window (see *Desktop app*).

## How it works

**The problem with two GPUs.** Out of the box, KWin and gamescope treat the handheld's AMD iGPU as the primary
GPU (it owns `boot_vga`), render and composite there, and then copy every frame across the USB4/Thunderbolt tunnel
to the NVIDIA-owned connector for scan-out. That cross-GPU copy is what made the eGPU feel worse than the iGPU:
it eats the tunnel's bandwidth, it caps frame rate and GPU power, and on the NVIDIA side it produced the
corruption and page-flip timeouts. We call it the AMD crosstalk.

**How it is circumvented: the docked session runs NVIDIA-only.**

1. `egpu-hotplug-mount.sh` bind-mounts a file containing `1` over the eGPU's read-only `boot_vga` sysfs flag and
   `0` over the iGPU's, so every compositor picks the NVIDIA card as primary. (Same trick as all-ways-egpu method 2.)
2. The compositor is told to open only the NVIDIA card: `KWIN_DRM_DEVICES=/dev/dri/<nvidia card>` and
   `KWIN_RENDER_NODES` for KWin; `OUTPUT_CONNECTOR=<eGPU DP>,*,eDP-1` for gamescope, so Game Mode composites on
   the eGPU and scans out on the eGPU's own connector.
3. Rendering is pinned to NVIDIA for everything in the session: `VK_DRIVER_FILES`/`VK_ICD_FILENAMES` point at
   `nvidia_icd.json`, `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `__EGL_VENDOR_LIBRARY_FILENAMES` at the NVIDIA vendor
   file, `PROTON_HIDE_NVIDIA_GPU=0`, NVAPI on. Games never touch the iGPU.
4. A hot plug after login cannot re-route a running compositor, so the tool restarts the session: in Game Mode
   `gamescope-session.target` is restarted on the eGPU (games are not killed without `--force`); on the Desktop the
   session is logged out and autologin brings Plasma back NVIDIA-first.

**Bandwidth and power.** The tunnel is marginal, so the attach path also: frees the empty Thunderbolt sibling
ports, resets the card (FLR), resizes BAR1 to the full 16 GB (ReBAR; without it the CPU sees VRAM through a 256 MB
window and big games thrash it), binds the driver, pins the link to Gen4 with autonomous speed change and
ASPM/L1SS off (correctable-error storms reset the link otherwise), and keeps the card out of runtime D3
(`NVreg_DynamicPowerManagement=0`). The kernel command line in *Install* reserves the prefetchable space that the
16 GB BAR needs on hot-plug.

**Operating modes and the handheld panel.**

| Mode | Compositor | Renders on | Handheld panel |
|---|---|---|---|
| Undocked (default, untouched) | stock gamescope / KWin | AMD iGPU | on |
| Docked, Game Mode | GBM-scanout gamescope, NVIDIA-only | eGPU | **off** |
| Docked, Desktop | KWin, NVIDIA-only | eGPU | **off** (external-only) |

While docked, no compositor owns the AMD card at all. Its panel would otherwise keep showing the last frame the
previous compositor left there, so `egpu-panel off` disables the eDP CRTC directly through DRM (SETCRTC as
master), sets DPMS off and the backlight power flag. On a safe detach or a cable yank the session moves back to the
iGPU, the panel is re-enabled and the compositor takes it over again. The eGPU display is the only display when
docked; that is the tested mode. A both-screens desktop layout is possible with `egpu-display-profile.sh` but is
not the default.

## Desktop app

`egpu-buddy` (application menu: **EGPU Buddy**) is a small desktop window for the docked desktop: live GPU
telemetry from nvidia-smi, tunnel/driver/mode badges, the power limit slider, reset clocks, Safe Detach and
Re-attach. It is the stripped-down successor of the eGPU page from a private hub app; it talks only to the helpers
in this repository, has no side panel and no LACT dependency. GTK 4 + WebKitGTK 6.0 window when `python-gobject`
provides them, otherwise it opens in your browser at `http://127.0.0.1:8772/`.

## Install

**Easiest: the release installer.** Download `SteamOS-EGPU-Buddy-<version>.run` from
[Releases](https://github.com/denver8989/SteamOS-EGPU-Buddy/releases), make it executable and run it from the
desktop (double-click, or `./SteamOS-EGPU-Buddy-<version>.run`). It shows what it detected, lets you tick the
components (hot-plug core, Game Mode integration, GBM gamescope, Decky plugin, boot policy, desktop app, patched driver), backs up
everything it replaces, and adds a "SteamOS EGPU Buddy Uninstaller" entry to the application menu. `--uninstall`
and `--no-gui` (terminal mode) are accepted. On SteamOS it toggles `steamos-readonly` around the install.

**What it needs on the machine.** Beyond systemd, udev and `pciutils`, the scripts call `setpci`, `modetest`
(libdrm), `fuser` (psmisc), `jq`, `xxd`, `perl`, `python3`, `qdbus6`, `kscreen-doctor`, `xprop`, `boltctl` and
`nvidia-smi`; the installer warns about any that are missing. The desktop app wants `python-gobject` with GTK 4 and
WebKitGTK 6.0 for its window and falls back to your browser without them. Nothing else is required and no other
project is referenced: if you run something of your own that must stop before the driver unloads or start after an
attach, drop an executable into `/etc/nv-egpu-buddy/hooks.d/{pre-unload,post-attach,post-detach}/`.

**From a checkout:**

```
git clone https://github.com/denver8989/SteamOS-EGPU-Buddy
cd SteamOS-EGPU-Buddy
./install.sh --check        # shows what would change on this machine
./install.sh                # user + system files, GBM gamescope build, Decky plugin
./install.sh --with-driver  # additionally builds and installs the patched nvidia-open modules
```

`./uninstall.sh` puts the backed-up originals back. The patched driver and the private gamescope build are left for
you to remove by hand (the uninstaller tells you how).

### Kernel command line

The tested machine boots with these parameters (Limine; put them in your bootloader's cmdline):

```
nvidia-drm.modeset=1 pci=realloc=on,hpmemsize=512M,hpmemprefsize=16G,noaer pcie_aspm=off thunderbolt.host_reset=0 thunderbolt.clx=0 iommu=pt pcie_ports=native
```

`hpmemprefsize=16G` reserves enough prefetchable space for the 16 GB BAR1 (ReBAR) of the eGPU on hot-plug; adjust to
your card. `noaer` and `pcie_aspm=off` stop the USB4 link from being reset by correctable-error storms.

### Layout

```
system/   files installed under / (scripts in /usr/local/sbin, units, udev, modprobe, sudoers)
user/     files installed under $HOME (session wrapper, gamescope shim, drop-ins, Lua scripts)
packaging/nvidia-open-egpu   PKGBUILD + patches for the hot-unplug-safe nvidia-open driver
packaging/gamescope-gbm      build script + patch for the GBM-scanout gamescope
decky-plugin/egpu-buddy      the Decky plugin (prebuilt dist included)
src/                         sources of the two small native helpers
docs/                        the root-cause notes
```

Paths inside the scripts say `/home/deck`; the installer rewrites them to your home, and the sudoers rule to your
user name.

## Credits

This project stands on other people's work; see [CREDITS.md](CREDITS.md) for every upstream fix, patch and
analysis it depends on.

## License

MIT for the scripts and documentation in this repository. Vendored patches keep the licenses of their upstream
projects (see CREDITS.md).
