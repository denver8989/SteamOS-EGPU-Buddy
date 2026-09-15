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

## 6. eGPU slower than the iGPU, corruption and page-flip timeouts while docked (AMD crosstalk)

**Cause.** The AMD iGPU owns `boot_vga`, so KWin/gamescope composite on it and copy each frame over the USB4
tunnel to the NVIDIA connector. The copy saturates the tunnel and the NVIDIA side sees late, cross-device buffers.

**Fix here.** The whole docked session is made NVIDIA-only: `boot_vga` bind-mounted (eGPU=1, iGPU=0),
`KWIN_DRM_DEVICES`/`OUTPUT_CONNECTOR` restricted to the NVIDIA card, Vulkan/GL pinned to the NVIDIA ICD, and the
session restarted on hot plug because a running compositor cannot be re-routed. See README, *How it works*.

## 7. Handheld panel stays dark after a re-login into Game Mode

**Symptom.** After a session ends and autologin starts Game Mode again (Desktop safe-detach, session restart),
gamescope selects `eDP-1` and a mode, but never commits: the CRTC stays off and the panel is black. Nothing is
logged; libseat never reports "Enabling seat" / "Session resumed".

**Cause.** gamescope started with an inactive libseat seat, and it only re-evaluates its paused state on a
seat event that never came.

**Fix here.** The session wrapper watches the panel for 12 s after gamescope starts; if it is still disabled and
no eGPU is on the bus it asks the privileged helper for `vt-bounce` (`chvt 2; chvt 1`), which makes logind
re-activate the session. The Desktop safe-detach additionally pins the re-login to the desktop, where the eject
tool expects KWin.

## 8. Handheld panel keeps a frozen image next to the eGPU display (Desktop hot plug)

**Cause.** After the NVIDIA-only re-login KWin never opens the AMD card, so it cannot disable `eDP-1`; the panel
keeps scanning out the last frame of the previous compositor.

**Fix here.** `egpu-hotplug-mount.sh` waits for the NVIDIA-only KWin and then runs `egpu-panel off`, which
disables the unowned CRTC directly.

## 9. eGPU display stays dark after the monitor sleeps

**Symptom.** The monitor goes to sleep on idle; moving the mouse wakes nothing. Suspend and resume brings the
picture back. Desktop or Game Mode, DisplayPort.

**Cause.** After DPMS-off the NVIDIA driver can leave the DRM connector `enabled=disabled / dpms=Off` while the
compositor believes the output is on again; only a full modeset recovers it. Reported against the open kernel
modules as [#1055](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1055) and
[#1028](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1028) (Blackwell, 580+); no driver fix as of
610.57.04.

**Fix here.** `egpu-wake-guard` (user service) watches input activity on the session's evdev nodes; when input
arrives while an NVIDIA connector is still off and it stays off for four seconds, it asks the privileged helper for
`vt-bounce` (a VT round-trip, the same recovery a suspend gives), at most once every two minutes. A normal wake never
trips it: the connector comes back within a second of the compositor's DPMS-on.

## 10. Game Mode on the eGPU keeps saying "update available, restart Steam", and the restart breaks Decky

**Cause.** Two Steam client branches on one install. The distro wrapper (`/usr/bin/steam`) pins the
`steamdeck_stable` branch and passes `-steamdeck`, which Game Mode uses. The eGPU desktop launcher started the bare
client without the flag, so desktop Steam ran the plain branch and installed its package; the next Game Mode start
found its own branch "not installed" and asked for a restart to reinstall it, and the in-place restart replaced the
client files under Decky Loader. Each Desktop→Game Mode switch repeated it. Only on the eGPU because only that
desktop path used the launcher.

**Fix here.** `steam-egpu-vk.sh` keeps the branch file at `steamdeck_stable` and launches with `-steamdeck` like
the wrapper, while exporting `SteamDeck=0` so games do not enter their Deck presets (resolution caps) on the desktop.

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
