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

## Everything else this leans on

- **Valve** — gamescope (BSD-2-Clause), the Steam Linux Runtime, Proton, the `gamescope-session` scripts this
  wraps, and the gamescope WSI layer whose source made the `WAYLAND_DISPLAY` bug findable.
- **jp7677 and the dxvk-nvapi contributors** — NVAPI on Linux, without which DLSS on the eGPU would not exist.
- **Bazzite** — their documentation of Game Mode quirks on NVIDIA.
- **CachyOS** — the Deckify handheld edition this was built on.
- **Decky Loader** and its plugin template.
- **NVIDIA** — nvidia-open, and the engineers who acknowledged the scan-out bug and escalated it.

If your work is used here and is not credited, open an issue and it will be fixed.
