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

There are two install methods that give the same result, plus a checkout for developers. Pick one.

### Method 1 — from Game Mode, with the Decky plugin

No desktop, no terminal. Needs [Decky Loader](https://decky.xyz).

1. Download `EGPU-Buddy-Decky-<version>.zip` from [Releases](https://github.com/denver8989/SteamOS-EGPU-Buddy/releases),
   or copy its link.
2. In Game Mode open the Quick Access menu → Decky → settings (gear) → enable **Developer mode**.
3. Decky settings → **Developer** → **Install plugin from URL** (or from the zip file) → paste the link → install.
4. Open the **EGPU Buddy** plugin in the Quick Access menu, press the top button twice to reach the **Setup** tab.
5. Optionally tick **Also build the patched hot-unplug driver** (Arch-based systems only, several minutes).
6. Press **Install system integration**, then press it again to confirm. A progress bar shows the stages: user
   files, system files, GBM gamescope, desktop app, done. The payload ships inside the plugin, so no internet is
   needed. Everything replaced is backed up next to the original.
7. Reboot. Plug the eGPU in after Game Mode is up the first time.

The same Setup tab shows the installed version and has **Uninstall system integration**, which restores the backups.

### Method 2 — from the Desktop, with the graphical installer

1. Download `SteamOS-EGPU-Buddy-<version>.run` from [Releases](https://github.com/denver8989/SteamOS-EGPU-Buddy/releases).
2. Make it executable and run it (double-click, or `./SteamOS-EGPU-Buddy-<version>.run`).
3. It shows what it detected (distro, immutable root, Game Mode session script, NVIDIA GPU, build toolchain, Decky).
4. Tick the components: hot-plug core, Game Mode session integration, GBM-scanout gamescope, Decky plugin, boot
   policy, desktop app, patched driver. Confirm.
5. Reboot. Plug the eGPU in after the session is up the first time.

`--uninstall` and `--no-gui` (terminal mode) are accepted. On SteamOS it toggles `steamos-readonly` around the
install. An "SteamOS EGPU Buddy Uninstaller" entry is added to the application menu.

### Method 3 — from a checkout

```
git clone https://github.com/denver8989/SteamOS-EGPU-Buddy
cd SteamOS-EGPU-Buddy
./install.sh --check        # shows what would change on this machine
./install.sh                # user + system files, GBM gamescope build, Decky plugin, desktop app
./install.sh --with-driver  # additionally builds the patched nvidia-open-egpu-dkms package with makepkg and installs it
```

`./uninstall.sh` puts the backed-up originals back. The patched driver package (`pacman -R nvidia-open-egpu-dkms`, then
reinstall `nvidia-open-dkms`) and the private gamescope build are left for you to remove by hand.

### What it needs on the machine

Beyond systemd, udev and `pciutils`, the scripts call `setpci`, `modetest` (libdrm), `fuser` (psmisc), `jq`, `xxd`,
`perl`, `python3`, `qdbus6`, `kscreen-doctor`, `xprop`, `boltctl` and `nvidia-smi`; the installer warns about any
that are missing. The desktop app wants `python-gobject` with GTK 4 and WebKitGTK 6.0 for its window and falls back
to your browser without them. Nothing else is required and no other project is referenced: if you run something of
your own that must stop before the driver unloads or start after an attach, drop an executable into
`/etc/nv-egpu-buddy/hooks.d/{pre-unload,post-attach,post-detach}/`.

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
Nothing in this repository would work without the people below. Where a fix is vendored, the file names in this repo
say where it came from. The same list is kept in [CREDITS.md](CREDITS.md) and ships inside every installer.

### The scan-out corruption fix (Game Mode UI on NVIDIA)

- **matt-schwartz (matte-schwartz on GitHub)** — found the root cause after two years of reports: gamescope's Vulkan-allocated scan-out
  buffers are backed by scattered video memory and nvidia-drm scans them out without a contiguity check
  (NVIDIA bug 5240452). His analysis, instrumentation and the driver-side experiment are in
  [NVIDIA forum thread 295314](https://forums.developer.nvidia.com/t/display-modes-above-2560x1440p-120hz-with-hdr-enabled-cause-flickering-corruption-within-gamescope-session/295314)
  and [open-gpu-kernel-modules PR #1305](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1305).
- **NightHammer1000** — published the GBM-scanout route for gamescope that this project builds, branch
  [`poc/gamescope-gbm-route`](https://github.com/NightHammer1000/gamescope/tree/poc/gamescope-gbm-route)
  (8 commits on top of gamescope 3.16.25, pinned at `2bfc18c`), and tested it across several NVIDIA cards.
- **antheas** — the compact original of the same idea:
  [antheas/gamescope@fa6f7f2](https://github.com/antheas/gamescope/commit/fa6f7f2503c2e773acf818ad688ddd1db73df3a0).
- **Matthewmachin962** and the other testers in that thread who confirmed the fix at 5120×1440.

### The hot-unplug-safe driver

- **NickNill** — maintainer of the AUR `nvidia-open-egpu` recipe whose PKGBUILD and base patches (110–140) this
  package builds on.
- **bdandy** — [open-gpu-kernel-modules PR #985](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/985),
  Thunderbolt/eGPU hot-unplug kernel support, vendored as patch 160.
- **roger-pmta** — [open-gpu-kernel-modules PR #984](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/984),
  the `RmForceExternalGpu` registry key, vendored as patch 170.
- Patches 165, 166 and 167 (deferred mode-config cleanup, software-only atomic commits during removal, detaching
  NVKMS kapi events on surprise removal) were written for this project on top of those.

### LACT — the base of the eGPU control side

- **Ilya Zlobintsev — [LACT](https://github.com/ilya-zlobintsev/LACT)** (MIT). This project's GPU control side grew out
  of a private fork of LACT ("LegionLACT") that was extended with eGPU management: the power-limit and clock-offset
  controls, the apply / keep / revert safety for pending GPU settings, the telemetry collection and the eGPU status
  reporting were first built inside that fork, and the first version of the Decky plugin talked to its daemon. The
  code shipped here was since rewritten to call nvidia-smi and NVML directly so that nothing depends on a running
  `lactd`, but the design and parts of the control logic derive from LACT and its NVIDIA backend.
  LACT's license: MIT, Copyright (c) 2023 Ilya Zlobintsev.

### Everything else this leans on

- **Valve** — gamescope (BSD-2-Clause), the Steam Linux Runtime, Proton, the `gamescope-session` scripts this
  wraps, and the gamescope WSI layer whose source made the `WAYLAND_DISPLAY` bug findable.
- **jp7677 and the dxvk-nvapi contributors** — NVAPI on Linux, without which DLSS on the eGPU would not exist.
- **Bazzite** — their documentation of Game Mode quirks on NVIDIA.
- **CachyOS** — the Deckify handheld edition this was built on.
- **Decky Loader** and its plugin template.
- **NVIDIA** — nvidia-open, and the engineers who acknowledged the scan-out bug and escalated it.

If your work is used here and is not credited, open an issue and it will be fixed.

## License

MIT for the scripts and documentation in this repository. Vendored patches keep the licenses of their upstream
projects (see CREDITS.md).
