# Root causes, in one page each

These are the problems that made an NVIDIA eGPU in Game Mode unusable, what actually caused them, and what in this
repository addresses each. Kept short on purpose; the referenced threads have the full detail.

## 1. Striping / flicker of the Game Mode UI on the eGPU display

**Symptom.** Steam's Game Mode UI (and games) show horizontal striping and flicker on the external display, worse
above ~2560 px width, worse after a desktop→Game Mode switch, absent on a cold boot, invisible in screen captures.

**Cause.** gamescope allocates scan-out buffers through Vulkan and exports them as dmabufs. The NVIDIA user-mode
driver backs them with physically scattered video memory; nvidia-drm/NVKMS registers them for scan-out without
checking contiguity. The display engine needs contiguous memory, so after the first contiguous run it reads
unrelated allocations. Compositors that allocate through GBM (KWin) are unaffected because NVKMS forces those
contiguous. NVIDIA bug 5240452; analysis by matt-schwartz in forum thread 295314.

**Fix here.** `packaging/gamescope-gbm` builds gamescope from NightHammer1000's `poc/gamescope-gbm-route` branch
(scan-out buffers allocated with GBM, imported into Vulkan) plus a one-line patch that forces full composition
whenever GBM scan-out is active (Steam otherwise writes `GAMESCOPE_COMPOSITE_FORCE=0` and re-enables direct
scan-out of game buffers). Enabled through `gamescope_drm_gbm_scanout=1` in the session drop-in; the shim falls back
to the distro gamescope if the private build cannot run.

## 2. Games freeze at the loading screen / no performance overlay

**Symptom.** After a desktop→Game Mode switch, games hang at their loading screen with audio running, the Steam
performance overlay never appears, gamescope logs "got the same buffer committed twice".

**Cause.** A Plasma session earlier in the same boot leaves `WAYLAND_DISPLAY=wayland-0` in the systemd user
environment. Steam inherits it, every game inherits it, and gamescope's WSI layer refuses to attach when
`WAYLAND_DISPLAY` differs from the gamescope socket name (`isRunningUnderGamescope()` in the layer source). Games
then present through the Xwayland fallback, which does not work for DX12 titles on this path.

**Fix here.** `user/.config/systemd/user/steam-launcher.service.d/10-nv-egpu-buddy.conf` unsets
`WAYLAND_DISPLAY` and `WAYLAND_SOCKET` for Steam.

## 3. Compositor hang / black screens on cable yank

**Symptom.** Unplugging the eGPU while its display is active freezes the compositor or leaves the driver wedged
until a reboot.

**Cause.** nvidia-drm and NVKMS do not expect the device to vanish underneath an active mode-set; DRM mode-config
cleanup and pending atomic commits touch hardware that is gone, and NVKMS event queues reference freed devices.

**Fix here.** `packaging/nvidia-open-egpu`: upstream PRs #985 and #984 plus three patches that defer the DRM
mode-config cleanup to device release, turn atomic commits into software no-ops during removal, and detach the
NVKMS kapi event queues on surprise removal. Paired with `egpu-surprise-recover` (udev on PCI remove) which moves
Game Mode back to the panel and unloads the driver.

## 4. Big Picture cropped on a 49" display

**Symptom.** Steam re-identifies the display, auto-scales the UI to ~2.4× and Big Picture renders in a 2125×598
viewport, cropped and overlapping.

**Fix here.** `nv-egpu-gamescope-steam-scale-clamp` rewrites the per-display `ScaleFactor` in Steam's config to a
sane value for any external windowed display entry, before Steam starts and whenever the entry changes.

## 5. Boot lands on the desktop with the eGPU attached

**Cause.** CachyOS persists `Session=plasma.desktop` after "Switch to Desktop"; a reboot from the desktop then
stays on the desktop.

**Fix here.** `egpu-conditional-session` runs at boot and sets the autologin session to Game Mode
(`/etc/nv-egpu-buddy/boot-desktop` as opt-out). `egpu-boot-enumerate.sh` brings the card up before login, with a
flood lockout so a bad link cannot loop the boot.

## Appendix: the exact recipe for the Game Mode UI fix

1. Source: `https://github.com/NightHammer1000/gamescope.git`, branch `poc/gamescope-gbm-route`, commit `2bfc18c`
   (2026-08-20, "drm, rendervulkan: apply final review findings"; base gamescope 3.16.25).
2. Local patch `packaging/gamescope-gbm/0001-force-composition-with-gbm-scanout.patch` (4 lines in
   `src/Backends/DRMBackend.cpp`): `bNeedsFullComposite |= (g_DRM.gbm && g_DRM.allow_modifiers && cv_drm_gbm_scanout)`.
3. Build: `meson setup build -Dprefix=$HOME/.local/gamescope-gbm/usr -Dpipewire=disabled -Davif_screenshots=disabled`,
   `ninja -C build install` (the prefix must be real: `SCRIPT_DIR` is compiled in and gamescope aborts in Lua if its
   own `util.lua` is not found).
4. Runtime: the session drop-in sets `NV_EGPU_BUDDY_GAMESCOPE_BIN=$HOME/.local/gamescope-gbm/usr/bin/gamescope`,
   `gamescope_drm_gbm_scanout=1` (gamescope turns any `gamescope_<convar>` environment variable into a convar
   override) and `NV_EGPU_GAMESCOPE_FORMAT_FILTER_ENABLE=0`. The shim falls back to `/usr/bin/gamescope` if the
   private binary cannot be linked. Only the eGPU session uses it; the handheld panel keeps the distro gamescope.
5. What it does: scan-out buffers are allocated with `gbm_bo_create_with_modifiers2(..., GBM_BO_USE_SCANOUT)` on the
   KMS device and imported into Vulkan; NVKMS forces GBM scan-out allocations to be physically contiguous, so the
   display engine never reads scattered memory. Expected log noise: "CreateScanoutBuffer: GBM allocation failed for
   24x24/32x32" (cursor buffers; harmless).
6. Not used: the driver-side mitigation (`RMDisableNoncontigAlloc=1` + PR #1305). It works but was reported to crash
   games (X4: Foundations, Half-Life 2) by the same testers.
