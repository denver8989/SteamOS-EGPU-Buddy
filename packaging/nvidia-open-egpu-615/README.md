# nvidia-open-egpu for 615.78.08 (BETA, untested on hardware)

The nine patches from `../nvidia-open-egpu/` (610.57.04) ported to the open kernel modules 615.78.08, same order:
110 120 130 140 160 170 165 166 167. Not used by any install path yet; the shipped driver is still 610.57.04.

## What had to change (everything else applies unchanged, line content identical to 610)
- **140 gcc-sls**: 615 added `-mfunction-return=thunk-extern` to the modeset flags; `-mharden-sls=all` now goes after it.
- **160 hotplug**, six hunks re-placed by hand:
  - `uvm_gpu.c`, `nv-pci.c`: include lines, new neighbours in 615.
  - `nvkms-evo.c` `nvFreeDevEvo`: 615 moved the DIFR teardown into `FreeDIFRState()`; the gpu-lost early exit sits
    right before it, the same position as on 610.
  - `osinit.c` `osHandleGpuLost`: 615 added a reset-status check (Bug 5197385) first in the branch; the
    `bIsExternalGpu` declaration and the "no Xid 79 for an external GPU" condition are added around it, NVIDIA's check kept.
  - `kernel_gsp.c`: 615 replaced `_kgspLogRpcTimeout` with `_kgspLogGspTimeout`, which also serves the periodic
    health check. The Xid 119 suppression is placed there and limited to RPC-origin timeouts, exactly as on 610.
  - `nvkms-evo3.c`: whitespace-only hunk, dropped.
- **166 software commit**: the LUT-notifier wait it guarded (`checkLutNotifier`) no longer exists in 615; hunk dropped.

## Checked (2026-10-08)
- Every added/removed line compared against the 610 patches: the only differences are the edits listed above.
- Compiles, all five modules, against CachyOS 7.1.8 and SteamOS `linux-neptune-618` 6.18.50 and `linux-neptune-72` 7.2.7.
- No new compiler warnings against stock 615 apart from two unused variables in `nvidia_dev_put` and one in
  `nvkms-dma.c`, which the 610 patches leave behind the same way.

## Not checked
Nothing has run on hardware: cable yank, safe detach, standby, shutdown, attach and BAR resize all need a device test.

## How a device gets it: Decky → Setup → "Try beta driver" (`/usr/local/sbin/egpu-driver-trial`)
Nothing of the driver is shipped in the plugin or the release. On the device: Safe Detach, then NVIDIA's own files are
downloaded from download.nvidia.com (installer ~530 MB, module source ~26 MB; makepkg checks them against the sha512 pinned
in `PKGBUILD` and `userspace/`), patched and built, then the eGPU is attached with the result and health-checked
(`nvidia-smi` answers with 615.78.08 and Game Mode is on the eGPU display). Healthy → kept
(`/etc/nv-egpu-buddy/driver-dir`, read by install.sh and the self-heal). Anything else → 610 is put back and attached.
A trial that never reached "kept" (hard reset, hang) is reverted at the next boot by `egpu-driver-trial-boot.service`,
before any eGPU bring-up. Log: `/var/log/egpu-driver-trial.log`.
- **Userspace**: no distribution ships 615.78.08 yet (Arch is at 615.71.09), so it is built from Arch's own recipe in
  `userspace/` with only the version and NVIDIA's checksums changed, plus three CachyOS extras that suit every distro
  (CUDA idle power, two per-app profiles). Not CachyOS's `nvidia-sleep.conf` (`/var/tmp` is on SteamOS's 256 MB /var) nor
  its `modules-load.d` (the eGPU driver must never autoload). One build for every distro.
- **CachyOS/Arch**: pacman packages. The exact installed 610 package files are copied to the package cache before anything
  changes; a revert installs them again (offline, DKMS rebuilds 610 in a few minutes). Disk: ~6 GB free while building;
  afterwards ~500 MB of 615 packages, deleted again by a revert.
- **SteamOS**: a second build root + image in `/home/.egpu-buddy-615`, next to 610's; a revert links 610's image back and
  deletes the 615 one. Untested on SteamOS hardware.
