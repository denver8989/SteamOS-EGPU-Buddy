# SteamOS EGPU Buddy — technical details

The [README](../README.md) covers what this does and how to install it. This page has the details behind it:
the tested rigs, how the eGPU session is set up, surviving OS updates, installer internals and the kernel
parameters. What was tested, and how, is in [TESTED.md](../TESTED.md); the bugs behind the fixes are in
[ROOT-CAUSES.md](ROOT-CAUSES.md).

## Tested hardware and software

Two machines, two GPU families, two distros. Everything below was measured on real hardware; anything
not listed here has not been tried.

| Part | Rig A — the reference | Rig B — second family |
|---|---|---|
| Handheld | Lenovo Legion Go 2 (AMD Strix Halo, USB4/TB5) | Lenovo Legion Go 1 (AMD Phoenix, USB4) |
| eGPU | Gigabyte AORUS AI Box | AOOSTAR AG03 (Intel JHL9480 TB5) |
| GPU | NVIDIA RTX 5060 Ti 16 GB — Blackwell, GB206 | NVIDIA RTX 3080 10 GB — Ampere, GA102 |
| Display | Acer Predator X49 V, 5120×1440 ultrawide, DisplayPort | same panel, DisplayPort |
| Distro | CachyOS (Deckify), kernel 7.1.8 | SteamOS 3.8, kernel 6.16.12-valve24.5 |
| Driver | `nvidia-open` 610.57.04 + the patches in `packaging/nvidia-open-egpu` | identical — same driver, no per-card build |
| gamescope | 3.16.23 handheld; 3.16.25 + GBM-scanout branch for the eGPU | as shipped by SteamOS |
| Session | `gamescope-session` + plasmalogin autologin | `gamescope-session` + sddm autologin |

**GPU support.** Ampere (RTX 30) and Blackwell (RTX 50) both work on the same open driver, with no
separate build and no per-card configuration by the user. The Ampere-specific bring-up is selected by
PCI device id (`0x22xx`–`0x25xx`, the GA10x desktop line), so the mechanism covers the family — but one
card from each family has actually been tested, the RTX 3080 and the RTX 5060 Ti. Ada (RTX 40) has not been on
the bench here; it takes the default path, and a user has reported it working on an RTX 4070.

### AMD / Intel eGPUs — the beta part of this app

NVIDIA support is the tested, released part. **Non-NVIDIA support ships in the same build but is the
beta part of it**, and it is selected entirely by what is plugged in — the NVIDIA rules never enter it,
so it cannot change how a tested NVIDIA install behaves. It is here rather than on a side branch so that
the people who have the hardware can shape it with feedback.

An AMD or Intel eGPU needs neither of the two NVIDIA-only pieces: the patched `nvidia-open` build (the
long part of an install — several minutes of compiling) and the GBM-scanout gamescope, which exists
solely to fix the NVIDIA scan-out corruption and does nothing on Mesa. Everything else this project does
is vendor-neutral and still applies:

- hot-plug attach in Game Mode and on the Desktop
- safe detach, and recovery from a surprise cable pull
- the session landing back where it started, with the built-in panel re-enabled
- audio following the eGPU output and coming back on detach
- the Decky plugin, the desktop app and the boot policy

Install it from the Decky plugin with **"Install for an AMD / Intel eGPU (skip the NVIDIA driver)"**, or
from a terminal:

```
./install.sh --amd
```

#### What is likely to work, and what is likely to bite — from other people's reports

Nothing below was measured here. It is what the kernel lists, the distro trackers and the other eGPU
projects say, collected so a tester knows where to look first rather than starting from nothing.

| | AMD (Radeon) | Intel (Arc) |
|---|---|---|
| Attach with the eGPU already plugged in at boot | should work | needs `xe.max_vfs=0` (see below) |
| Hot-plug attach | should work | often a 3-minute stall, then failure, without the flag |
| Surprise cable pull | **kernel-dependent** | unknown |
| Session returns to where it was after a cable pull | yes — same mechanism as NVIDIA | yes |
| Built-in panel re-enabled as an output | yes | yes |
| Audio follows the eGPU and returns on detach | yes | yes |
| Steam restarted after a cable pull | yes | yes |
| Fabric-flood protections (USB4 pin, AER mask, DPC clear) | yes | yes |
| Resizable BAR / large BAR1 | host-dependent | **reported broken** over Thunderbolt |
| Switching the *primary render* GPU without a session restart | **not possible on any Wayland compositor** | same |

**Hot-unplug exists but has regressed more than once.** amdgpu gained hot-unplug in Linux 5.14,
specifically so that pulling an enclosure stops crashing the machine. It is not settled: a Framework 13
with a Razer Core X and an RX 6800 XT lost the card on `linux-cachyos` 6.19.10 with `pciehp Link Down /
Card not present`, having worked on 6.19.6. **If a cable pull misbehaves, check your kernel version
before anything else.**

**Intel Arc is not officially supported in an enclosure at all**, by Intel's own statement. There is a
specific, known failure: over a Thunderbolt tunnel the driver's SR-IOV mailbox does not answer, so it
waits out a three-minute fallback and gives up with `-ETIMEDOUT`. The workaround is the kernel parameter
**`xe.max_vfs=0`**. ReBAR is separately reported as still broken over Thunderbolt for Arc, which is
consistent with this project skipping the BAR resize on the non-NVIDIA path.

**No Wayland compositor can change its primary rendering GPU without restarting the display manager** —
that is a protocol-level limitation, not a bug in anyone's driver. It is why this project restarts the
session on attach rather than trying to re-route a live one, and why `boot_vga` is set (the same
mechanism `all-ways-egpu` uses, and the one mutter, KWin and wlroots honour).

**A note on the instant-reboot problem, because it is not an NVIDIA problem.** The AMD SoC resets the
machine the moment it hits an unrecoverable interconnect error — a *data fabric sync flood*, `0x08000800`
— and PCIe tunnelling between an AMD USB4 host and a Thunderbolt peripheral is a documented trigger.
None of that depends on who made the graphics card, so an AMD or Intel eGPU on this hardware is exposed
to exactly the same instant reboot as an NVIDIA one. The mitigations are therefore applied on the
non-NVIDIA path too: the USB4 root ports are kept out of runtime suspend, AER surprise-down and the
tunnel ports' fatal errors are masked so a cable pull reports instead of escalating, and any latched DPC
containment is cleared. They are config-space operations on the bridges, vendor-neutral by construction.

**This has never been run on real AMD or Intel eGPU hardware.** The non-NVIDIA attach/detach path
(`egpu-generic`, udev rule 96) was written from the kernel's behaviour, not from a bench. It is kept
completely separate from the NVIDIA path, so it cannot affect a working NVIDIA install — but it is
unproven, and that is exactly why it is in the beta. If you have an AMD or Intel eGPU, reports are very
welcome: what attached, what did not, and the contents of `/var/log/egpu-generic.log`.

### What has been tested, per rig

| Behaviour | RTX 5060 Ti | RTX 3080 |
|---|---|---|
| Boot with the eGPU attached | yes | yes |
| Hot-plug attach in Game Mode | yes | yes |
| Hot-plug attach on the Desktop | yes | yes |
| Full 16 GiB BAR1 (ReBAR) | yes | yes — at boot and on hot-plug |
| Safe detach, Game Mode | yes | yes |
| Safe detach, Desktop | yes | yes |
| Cable pull in Game Mode → stays in Game Mode | yes | yes |
| Cable pull on the Desktop → returns to the Desktop | yes | yes |
| Audio follows the eGPU output and returns on detach | yes | yes |

No benchmarks or performance figures are published for any card here. This project is about whether the eGPU
attaches, renders, survives a cable pull and comes back — not about how fast it is.

## How it works

**The problem with two GPUs.** Out of the box, KWin and gamescope treat the handheld's AMD iGPU as the primary
GPU (it owns `boot_vga`), render and composite there, and then copy every frame across the USB4/Thunderbolt tunnel
to the NVIDIA-owned connector for scan-out. That cross-GPU copy is what made the eGPU feel worse than the iGPU:
it eats the tunnel's bandwidth, it caps frame rate and GPU power, and on the NVIDIA side it produced the
corruption and page-flip timeouts. We call it the AMD crosstalk.

**How it is circumvented: the docked session runs NVIDIA-only.**

1. The compositor is told to open only the NVIDIA card: `KWIN_DRM_DEVICES=/dev/dri/<nvidia card>` and
   `KWIN_RENDER_NODES` for KWin; `OUTPUT_CONNECTOR=<eGPU DP>,*,eDP-1` for gamescope, so Game Mode composites on
   the eGPU and scans out on the eGPU's own connector.
2. Rendering is pinned to NVIDIA for everything in the session: `VK_DRIVER_FILES`/`VK_ICD_FILENAMES` point at
   `nvidia_icd.json`, `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `__EGL_VENDOR_LIBRARY_FILENAMES` at the NVIDIA vendor
   file, `PROTON_HIDE_NVIDIA_GPU=0`, NVAPI on. Games never touch the iGPU.
4. A hot plug after login cannot re-route a running compositor, so the tool restarts the session: in Game Mode
   `gamescope-session.target` is restarted on the eGPU (games are not killed without `--force`); on the Desktop the
   session is logged out and autologin brings Plasma back NVIDIA-first.

**Bandwidth and power.** The tunnel is marginal, so the attach path also: frees the empty Thunderbolt sibling
ports, resets the card (FLR), resizes BAR1 to the full 16 GB (ReBAR; without it the CPU sees VRAM through a 256 MB
window and big games thrash it), binds the driver, pins the link to Gen4 with autonomous speed change and
ASPM/L1SS off (correctable-error storms reset the link otherwise), and keeps the card out of runtime D3
(`NVreg_DynamicPowerManagement=0`). The kernel command line (below) reserves the prefetchable space that the
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
  installer. The same hook checks that the newest kernel has the eGPU-patched modules (built, patched, matching
  `nvidia-utils`) and that the kernel parameters are still in the bootloader config. What it can fix it fixes before
  you restart: a failed DKMS build is retried, and once the update has finished a repair step installs missing kernel
  headers or puts the matching driver packages back from the installer's cache. The outcome shows in the terminal, as
  a desktop notification and in the Decky plugin.
- A second hook (`egpu-buddy-pre-upgrade`, before the transaction) stops any update that would replace, remove or
  re-version the NVIDIA packages, with nothing changed. The installer and the driver trial pass it; to change the
  driver by hand, `sudo touch /run/nvegpu/driver-change-ok` first.
- If a new kernel refuses to build the pinned 610.57.04 modules, hold the kernel (`IgnorePkg`) until a release
  with a newer driver exists; `dkms status` and the system journal (`egpu-buddy-post-upgrade`) tell you.

**SteamOS (experimental, self-healing).** The facts this is built on were read from Valve's own SteamOS 3.8.14
image: the system partition is a fixed 5 GB with about 870 MB free, `/var` is a 256 MB partition, there is no compiler,
an OS update replaces `/usr` wholesale, `/usr/local` and `/home` persist, and of `/etc` an update keeps the systemd
units plus whatever `/etc/atomic-update.conf.d/*.conf` lists. The tested NVIDIA driver needs 1.5-2.1 GB, so on SteamOS
**nothing is installed into the system partition**:

- The driver is the same patched 610.57.04 as everywhere else. It is built inside a small SteamOS build environment
  on `/home` (Valve's own repositories and keyring), against the headers of the *exact* running kernel (fetched from
  Valve's mirror by version, because the repository database moves on while devices stay on older builds).
- The NVIDIA userspace, the few EGL packages SteamOS lacks and the built modules are collected into a **systemd system
  extension** on `/home` (`/home/.egpu-buddy`), which systemd merges into `/usr` (SteamOS enables `systemd-sysext` by
  default). The extension is one squashfs **image file** (about 520 MB): SteamOS formats `/home` as ext4 with
  case-folding, and its kernel's overlayfs refuses directories on such a filesystem, so a directory extension cannot
  work there (found on a real device). Module dependency data is generated into the extension, so `modprobe` works
  as usual.
- The kernel parameters go into `/etc/default/grub.d/egpu-buddy.cfg` (Valve's `grub-mkconfig` reads that directory)
  rather than into `/etc/default/grub`, which an update replaces.
- The integration's `/etc` files are registered in `/etc/atomic-update.conf.d/egpu-buddy.conf` so an update carries
  them over.
- `egpu-buddy-selfheal.service` (kept by updates) re-activates the extension at every boot and, when an update
  brought a **new kernel**, rebuilds the modules for it in the background. Until that is done the attach script
  **refuses to bring the eGPU up** (no driver, or kernel parameters not active) and says so in the plugin, instead of
  risking the unprotected first connection. This gate exists on SteamOS only.
- None of the above is applied on other systems: CachyOS and Arch keep their own NVIDIA packages and behave as before.
- Safe Detach hides the NVIDIA userspace with bind mounts where `/usr` cannot be written.
- From the Decky plugin all of this runs as root without a password, in its own systemd unit (a Steam or Decky
  restart does not interrupt the first build: 10-20 minutes, mostly downloads; the compile uses all CPU cores). **Uninstall** removes the extension, the build
  environment, the keep-list and the GRUB drop-in.

How far this is verified: the complete install, the boot-time re-activation, a simulated kernel change, Safe Detach's
hide/restore and the uninstall were run inside a container made from Valve's 3.8.14 image with a read-only system,
a separate small `/var` and `/home` (see `TESTED.md`). On a real device (Legion Go, SteamOS 3.8) the build
environment, the exact-kernel headers and the driver compile have run; the first attempt then failed at the
case-folding `/home` described above, which is what 0.7.21 fixes. **Still unconfirmed on a real device**: the merged
extension, real boot ordering, the GRUB regeneration, an actual OS update and loading the modules on a real eGPU. The plugin's first page shows **Repair system integration** for the self-heal job on demand.

**Bazzite (rpm-ostree): untested.** `/usr/local` and `/etc` persist there, kernel parameters go through
`rpm-ostree kargs` (handled), but the patched driver is an Arch package and cannot be layered, so a cable yank may
still hang; safe detach does not need it.

## Desktop app

`egpu-buddy` (application menu: **EGPU Buddy**) is a small desktop window for the docked desktop: live GPU
telemetry from nvidia-smi, tunnel/driver/mode badges, the power limit slider, reset clocks, Safe Detach and
Re-attach. It is the stripped-down successor of the eGPU page from a private hub app; it talks only to the helpers
in this repository, has no side panel and no LACT dependency. GTK 4 + WebKitGTK 6.0 window when `python-gobject`
provides them, otherwise it opens in your browser at `http://127.0.0.1:8772/`.

## Before you connect anything

**Install, reboot, *then* plug the eGPU in.** The protections that stop a cable event taking the whole
machine down — AER handling, ASPM, the Thunderbolt options — are **kernel parameters**. They do not exist
until the next boot. On an AMD host a PCIe event over the USB4 tunnel can trigger a *data fabric sync
flood* (`0x08000800`), which resets the machine instantly with nothing in the logs, and that is exactly
the class of event an unprotected first plug-in can produce.

Almost everyone installs this with nothing connected, so it is not a footnote: the installer and the
Decky page both say so explicitly when no eGPU is present, and the plugin will not tell you the eGPU
"can stay plugged in" unless one already is.

**The plugin asks which eGPU you will connect, before it installs anything.** That is deliberate: the
whole point of this app is to be set up *in advance* so the eGPU mounts by itself when it is finally
plugged in, which means there is usually nothing connected to detect. So it asks rather than guesses —
two buttons, *NVIDIA eGPU (builds the driver)* and *AMD / Intel eGPU (no driver build)*. The choice only
decides whether the NVIDIA driver is built, the eGPU does not need to be present, and running the other
install later switches it. Detection is used only afterwards, to notice that the card you eventually
connected does not match what you chose and to point at the right button.

## Install details

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

### Updates

**Updates are your choice.** The plugin checks this repository's releases (hourly, and whenever you open it after a
while) and announces a new one on its first page with an *Update now* button; **Check for updates** sits at the bottom
of that page. Nothing installs by itself unless you switch *Automatic updates* on in Setup; it is **off by default**.
An update installs the system integration through the same verified installer, then the plugin's own files, then Decky
reloads and the first page asks for a restart. It never performs a first install on its own.

### Graphical installer options

`--advanced` shows a component checklist instead; `--uninstall` and `--no-gui` are accepted. On SteamOS it toggles
`steamos-readonly` around the install. A "SteamOS EGPU Buddy Uninstaller" entry is added to the application menu.

### Developer install

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

Open an issue with your distro and kernel, the eGPU enclosure and GPU, the installed version
(`cat /etc/nv-egpu-buddy/version`), whether the eGPU was connected at boot or plugged in later, and the log that fits:

- attach: `/var/log/egpu-hotplug-mount.log`
- Game Mode switch: `/var/log/egpu-gamemode.log`
- plugin install: `/tmp/egpu-buddy-setup.log`
- beta driver: `/var/log/egpu-driver-trial.log`
- AMD / Intel eGPU: `/var/log/egpu-generic.log`
- kernel: `journalctl -k -b`, around the time of the problem
- Game Mode: `journalctl --user -u gamescope-session.service -b`
