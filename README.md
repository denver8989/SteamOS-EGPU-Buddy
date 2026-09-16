# SteamOS EGPU Buddy

Hot-pluggable NVIDIA eGPU on a Linux gaming handheld, in **Game Mode**, on par with Windows: plug in and Game Mode
moves to the monitor, unplug (safely or by yanking the cable) and it falls back to the handheld panel, replug and
it comes back. Includes the fixes for the three things that made this unusable before: the NVIDIA scan-out
corruption in gamescope, the driver hang on surprise removal, and games freezing at the loading screen.

**Status: works on exactly one machine (mine). Claude (Anthropic) and Codex (OpenAI) were used as development assistants
throughout; every change was tested on that machine as recorded in TESTED.md, and nothing is claimed beyond that. Everything else is untested. Read [TESTED.md](TESTED.md) before you
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
- **Wake guard**: when the eGPU monitor sleeps and stays dark on wake (an NVIDIA driver bug, see
  [docs/ROOT-CAUSES.md](docs/ROOT-CAUSES.md) #9), the picture is brought back automatically instead of needing a
  suspend/resume.

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

## Surviving OS updates

**CachyOS and other mutable Arch-based distros (the target):**

- Scripts live in `/usr/local`, configuration in `/etc` (udev, modprobe, modules-load, systemd units, sudoers,
  pacman hook), the session pieces in your home. pacman never touches any of these on an update.
- The patched driver is a DKMS package (`nvidia-open-egpu-dkms`); kernel updates rebuild its modules
  automatically. It conflicts with the stock `nvidia-open-dkms`, so an update cannot silently swap it back. The
  NVIDIA userspace is held at the matching version through `IgnorePkg`; the installer appends to any existing
  `IgnorePkg` line rather than replacing it.
- The private GBM-scanout gamescope links against system libraries. After every pacman transaction a hook runs
  `egpu-buddy-post-upgrade`: if a library update broke the binary it rebuilds it from the kept source tree
  (toolchain present) or logs that the session shim will fall back to the distro gamescope until you re-run the
  installer. The same hook reports when no patched module is installed for the newest kernel.
- If a new kernel refuses to build the pinned 610.57.04 modules, hold the kernel (`IgnorePkg`) until a release
  with a newer driver exists; `dkms status` and the system journal (`egpu-buddy-post-upgrade`) tell you.

**SteamOS (experimental, self-healing).** SteamOS A/B updates replace `/usr` wholesale, which takes `/usr/local`
and every pacman-installed package with it, while `/etc` and `/home` persist. So the install keeps a complete copy of
the release under `~/.local/share/steamos-egpu-buddy`, together with a cache of the pacman packages it installed and
of the patched kernel modules for the running kernel, and enables `egpu-buddy-selfheal.service`: a unit in `/etc`
whose script lives in that home directory. At every boot it checks the root-side integration and, after an update
has wiped it, re-applies it from the copy, restores the cached packages, rebuilds the driver with DKMS if the new
kernel's headers exist or restores the cached modules if the kernel is unchanged, re-applies the kernel parameters,
and logs what it could not do (a new kernel without headers means no eGPU until a release with modules for it). The
plugin's first page shows **Repair system integration** for the same job on demand. None of this has been exercised
on a real SteamOS update yet.

**Bazzite (rpm-ostree): untested.** `/usr/local` and `/etc` persist there, kernel parameters go through
`rpm-ostree kargs` (handled), but the patched driver is an Arch package and cannot be layered, so a cable yank may
still hang; safe detach does not need it.

## Desktop app

`egpu-buddy` (application menu: **EGPU Buddy**) is a small desktop window for the docked desktop: live GPU
telemetry from nvidia-smi, tunnel/driver/mode badges, the power limit slider, reset clocks, Safe Detach and
Re-attach. It is the stripped-down successor of the eGPU page from a private hub app; it talks only to the helpers
in this repository, has no side panel and no LACT dependency. GTK 4 + WebKitGTK 6.0 window when `python-gobject`
provides them, otherwise it opens in your browser at `http://127.0.0.1:8772/`.

## Install

**SteamOS note.** The `deck` account normally has no password, and without one `sudo` cannot work. The Decky plugin
route (Method 1) does not need a password at all: Decky runs the plugin as root. The `.run` and the one-line installer
ask you to set a password first if none exists.

**Before you start, whichever method you pick:** have the eGPU **disconnected** while installing and for the
reboot that follows. Connecting it before the fixes are in place can crash or shut the machine down: the stock
path auto-loads the driver on a half-initialised link and lets the compositor pick the wrong card. The install
puts the NVIDIA packages, the patched driver with its userspace pinned to the same version, and the kernel
parameters in place itself; you choose nothing. The tool assumes the eGPU is the machine's only NVIDIA GPU. USB4 / Thunderbolt must be enabled in the
firmware (BIOS) settings; the installer loads the kernel's Thunderbolt driver at boot, installs bolt, and tells you
if no USB4/Thunderbolt controller is visible.

There are two install methods that give the same result, plus a one-line installer. Pick one. Every release stays
available on the Releases page, so a build that worked for you can always be reinstalled if a newer one breaks something;
the plugin's automatic updates follow the newest release only.

### Method 1 — from Game Mode, with the Decky plugin

1. With [Decky Loader](https://decky.xyz) installed: Decky settings → Developer → **Install plugin from URL** →
   the `EGPU-Buddy-Decky-<version>.zip` link from [Releases](https://github.com/denver8989/SteamOS-EGPU-Buddy/releases).
2. Open **EGPU Buddy** in the Quick Access menu and press **Install system integration**. A progress bar reports
   each stage until it is done (the driver build takes a few minutes).
3. Press **Reboot now**, with the eGPU disconnected. Plug it in once Game Mode is up.

When everything is installed and current that page shows only the eGPU controls; **Setup** (two presses of the
top button) reinstalls or uninstalls.

**Automatic updates.** The plugin checks this repository's releases every hour. With *Automatic updates* on (the
default, in Setup) a new release installs itself when no game is running: the system integration through the same
verified installer, then the plugin's own files, then Decky reloads and the first page asks for a reboot. With it off
the first page shows an *Update now* button instead. It never performs a first install on its own.

### Method 2 — from the Desktop, with the graphical installer

1. Download `SteamOS-EGPU-Buddy-<version>.run` from [Releases](https://github.com/denver8989/SteamOS-EGPU-Buddy/releases),
   make it executable and run it.
2. It shows what it detected and asks once: install everything now? Yes.
3. Reboot with the eGPU disconnected, then plug it in.

`--advanced` shows a component checklist instead; `--uninstall` and `--no-gui` are accepted. On SteamOS it toggles
`steamos-readonly` around the install. A "SteamOS EGPU Buddy Uninstaller" entry is added to the application menu.

### Method 3 — one line in a terminal

```
curl -fsSL https://raw.githubusercontent.com/denver8989/SteamOS-EGPU-Buddy/master/get-egpu-buddy.sh | bash
```

It fetches the latest release, verifies its SHA-256, offers to install Decky Loader with Decky's own official
installer if it is missing, then runs the same installer as Method 2 (graphical when a display is available,
otherwise in the terminal). Developers can instead clone the repository and use `./install.sh --check`,
`./install.sh`, `./install.sh --with-driver` and `./uninstall.sh`.

### What it needs on the machine

Beyond systemd, udev and `pciutils`, the scripts call `setpci`, `modetest` (libdrm), `fuser` (psmisc), `jq`, `xxd`,
`perl`, `python3`, `qdbus6`, `kscreen-doctor`, `xprop`, `boltctl` and `nvidia-smi`; the installer warns about any
that are missing. The desktop app wants `python-gobject` with GTK 4 and WebKitGTK 6.0 for its window and falls back
to your browser without them. Nothing else is required and no other project is referenced: if you run something of
your own that must stop before the driver unloads or start after an attach, drop an executable into
`/etc/nv-egpu-buddy/hooks.d/{pre-unload,post-attach,post-detach}/`.

### Kernel command line

The tested machine boots with these parameters. `sudo egpu-kernel-cmdline --check` reports which are missing from the running
kernel; `sudo egpu-kernel-cmdline --apply` writes them for rpm-ostree, Limine (`/etc/default/limine`), GRUB (`/etc/default/grub`)
or systemd-boot entries, keeping a backup, and regenerates the boot config:

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

## Roadmap

- **One version.** The plugin and the system files carry the same version number (from 0.7.12).
- **Every release stays published.** No build is removed once released.
- **Separate the NVIDIA-specific pieces from the generic eGPU path.** Generic: Thunderbolt authorization, PCI attach
  order, kernel parameters, boot policy, session restart, panel handling, safe detach, the plugin. NVIDIA-only: the
  patched driver, the GBM-scanout gamescope, the NVIDIA userspace pinning, nvidia-smi telemetry and power controls, the
  DPC/link-pin details that exist because of the GSP lockdown. The goal is a layout where an AMD eGPU can use the
  generic path with the NVIDIA layer left out. Not started.

## Reporting problems

Open an issue with: your distro and kernel, the eGPU enclosure and GPU, the installed version (`cat
/etc/nv-egpu-buddy/version`), and the relevant log: `/var/log/egpu-hotplug-mount.log` (attach), `/var/log/egpu-gamemode.log`
(Game Mode switch), `/tmp/egpu-buddy-setup.log` (plugin install), `journalctl -k -b` around the time of the problem, and for
Game Mode issues `journalctl --user -u gamescope-session.service -b`. Say whether the eGPU was connected at boot or
plugged in later.

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

### The USB4 link stability (the AMD data-fabric sync flood)

- **damianbienias32** (CachyOS forum, [setup](https://discuss.cachyos.org/t/my-setup-mini-pc-aorus-egpu-and-cachyos/34425)
  and [eGPU control switcher](https://discuss.cachyos.org/t/egpu-control-switcher/34486) threads) — the platform twin
  (Ryzen AI Max+ USB4 host + the same AORUS AI Box on CachyOS) whose method this project's attach path follows: bring
  the card up only after the desktop, disable ASPM/L1 substates on both ends of the tunnel, pin the link speed with
  hardware autonomous speed change disabled and retrain **before** the driver loads, keep the GPU at P0. Before that,
  every boot with the card attached ended in an AMD data-fabric sync-flood reset on this machine.
- **The open-gpu-kernel-modules [#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) thread** — roger-pmta
  (opener), apnex, jciolek, lokmantsui, efenex and others, who established that the tunneled link's autonomous speed
  negotiation, not GPU clocks, triggers the GSP lockdown that cascades into the flood, and that `pcie_aspm=off` is harmful
  on AMD USB4 hosts.
- **nikomiiller** (NVIDIA forum thread [365386](https://forums.developer.nvidia.com/t/365386), same box and GPU) — the
  link-speed cap, ASPM-off and persistenced workarounds that were tested first.
- **Alex Forencich** — the [setpci link-speed recipe](https://alexforencich.com/wiki/en/pcie/set-speed) (Link Control 2
  target speed, retrain bit) that the pin is written with.
- **DamianKA1993 — [blackwell-egpu-manager](https://github.com/DamianKA1993/blackwell-egpu-manager)** (MIT) — a tool built
  around the same approach (udev-driven attach, setpci ASPM/link control, boltctl authorization, P0 lock) for Blackwell
  eGPUs; not used here, listed because the approach is the same lineage.
- **ewagner12 — [all-ways-egpu](https://github.com/ewagner12/all-ways-egpu)** (MIT) — the `boot_vga` bind-mount
  technique (its "Method 2") is reimplemented in `egpu-hotplug-mount.sh` so that compositors pick the eGPU as primary;
  no code was copied, the idea and the file layout (a `0`/`1` file bind-mounted over the sysfs flag, a list of mounted
  paths for cleanup) are his.
- The PCIe DPC handling (clearing the containment trigger so the second USB4 port forms its tunnel, re-arming it before
  the driver loads), freeing the enclosure's empty Thunderbolt sibling ports so the 16 GB BAR fits, and the flood lockout
  that breaks a reboot loop were worked out on this machine.

### Related projects (no code shared)

- [hertg/egpu-switcher](https://github.com/hertg/egpu-switcher) — X.Org-only eGPU switching; not applicable to
  gamescope/Wayland, nothing taken from it.
- [WowOne987/eGPUBridge](https://github.com/WowOne987/eGPUBridge) — a Decky plugin for eGPU display switching (AMD
  RX 9070 on a Legion Go S, with NVIDIA driver loading). Independent work from the same period; it replaces the whole
  gamescope session script, this project wraps the distro's. Checked side by side: no shared code.
- [djanice1980/eGPU-Blackwell-Stability](https://github.com/djanice1980/eGPU-Blackwell-Stability) — Blackwell eGPU on a
  Strix Halo host (Flow Z13) with apnex's driver patches; it uses the card for render offload only and does not drive a
  display from it, which is why it never meets the display-path problems solved here.

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
