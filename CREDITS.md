# Credits

Nothing in this repository would work without the people below. Where a fix is vendored, the file names in this repo
say where it came from.

## The scan-out corruption fix (Game Mode UI on NVIDIA)

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

## The hot-unplug-safe driver

- **NickNill** — maintainer of the AUR `nvidia-open-egpu` recipe whose PKGBUILD and base patches (110–140) this
  package builds on.
- **bdandy** — [open-gpu-kernel-modules PR #985](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/985),
  Thunderbolt/eGPU hot-unplug kernel support, vendored as patch 160.
- **roger-pmta** — [open-gpu-kernel-modules PR #984](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/984),
  the `RmForceExternalGpu` registry key, vendored as patch 170.
- Patches 165, 166 and 167 (deferred mode-config cleanup, software-only atomic commits during removal, detaching
  NVKMS kapi events on surprise removal) were written for this project on top of those.

## LACT — the base of the eGPU control side

- **Ilya Zlobintsev — [LACT](https://github.com/ilya-zlobintsev/LACT)** (MIT). This project's GPU control side grew out
  of a private fork of LACT ("LegionLACT") that was extended with eGPU management: the power-limit and clock-offset
  controls, the apply / keep / revert safety for pending GPU settings, the telemetry collection and the eGPU status
  reporting were first built inside that fork, and the first version of the Decky plugin talked to its daemon. The
  code shipped here was since rewritten to call nvidia-smi and NVML directly so that nothing depends on a running
  `lactd`, but the design and parts of the control logic derive from LACT and its NVIDIA backend.
  LACT's license: MIT, Copyright (c) 2023 Ilya Zlobintsev.

## The USB4 link stability (the AMD data-fabric sync flood)

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

## Related projects (no code shared)

- [hertg/egpu-switcher](https://github.com/hertg/egpu-switcher) — X.Org-only eGPU switching; not applicable to
  gamescope/Wayland, nothing taken from it.
- [WowOne987/eGPUBridge](https://github.com/WowOne987/eGPUBridge) — a Decky plugin for eGPU display switching (AMD
  RX 9070 on a Legion Go S, with NVIDIA driver loading). Independent work from the same period; it replaces the whole
  gamescope session script, this project wraps the distro's. Checked side by side: no shared code.
- [djanice1980/eGPU-Blackwell-Stability](https://github.com/djanice1980/eGPU-Blackwell-Stability) — Blackwell eGPU on a
  Strix Halo host (Flow Z13) with apnex's driver patches; it uses the card for render offload only and does not drive a
  display from it, which is why it never meets the display-path problems solved here.

## Everything else this leans on

- **Valve** — gamescope (BSD-2-Clause), the Steam Linux Runtime, Proton, the `gamescope-session` scripts this
  wraps, and the gamescope WSI layer whose source made the `WAYLAND_DISPLAY` bug findable.
- **jp7677 and the dxvk-nvapi contributors** — NVAPI on Linux, without which DLSS on the eGPU would not exist.
- **Bazzite** — their documentation of Game Mode quirks on NVIDIA.
- **CachyOS** — the Deckify handheld edition this was built on.
- **Decky Loader** and its plugin template.
- **NVIDIA** — nvidia-open, and the engineers who acknowledged the scan-out bug and escalated it.

If your work is used here and is not credited, open an issue and it will be fixed.
