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

## 0.1.1 (2026-09-14)

- Hot plug while on the Desktop: **tested** after the change (external display primary, handheld panel off).
- Desktop Safe Detach returning to the Desktop: **changed, not yet re-run**.
- Re-login panel watchdog (`vt-bounce`): the manual VT bounce was verified to recover the dark panel; the automatic
  watchdog path is **not yet exercised**.

## 0.2.0 (2026-09-14)

- Desktop app: backend `/api/status` and action guards **tested** on the tested machine (eGPU attached, Desktop);
  the GTK/WebKit window and the Safe Detach / Re-attach buttons from the app **not yet exercised**.
- hooks.d mechanism: **untested** with a real hook by anyone but the maintainer (their hooks live outside this repo).

## 0.3.1 (2026-09-14)

- Decky Setup tab install route: **tested** on the tested machine (bundled payload, root-mode installer, progress
  reaches 100, files owned by the login user, `install.sh --check` clean afterwards). Uninstall from the tab and
  the optional driver build from the tab: **not exercised**.
- Patched driver package: the PKGBUILD builds on the tested machine and its DKMS source is byte-identical to the one
  installed here (same package, `pacman -Qkk` clean); the makepkg-based install script itself was not run to completion
  on a second machine.

## 0.3.2 (2026-09-14)

- One-line installer: download + checksum + dry run **tested** on the tested machine; the Decky Loader prompt path **not exercised** (Decky is already installed here).
- Plugin first-page Install button: backend route unchanged from 0.3.1 (tested); the new button flow **not exercised** in the Quick Access UI by the maintainer's automation.

## 0.3.3 (2026-09-14)

- `egpu-kernel-cmdline --check` **tested** here (reports ok); `--apply --dry-run` **tested** against this machine's Limine config; a real `--apply` on GRUB, systemd-boot or rpm-ostree **untested**.
- GUI installer sudo-via-dialog: mechanism **tested** (sudo -A with an askpass helper); the dialog flow itself not clicked through by the maintainer's automation.
- Fresh-machine flow (no NVIDIA packages, no eGPU ever connected): **untested**; this machine already had everything.

## 0.4.0 (2026-09-14)

- Dock self-authorization: **untested** (the dock here was enrolled long ago; bolt policy iommu).
- Userspace pinning from the Arch Linux Archive: URLs verified to exist; the pin step **not exercised** here (already at the pinned version).
- Plugin one-press route re-run here without the driver step (it is the same package already installed).

## 0.4.2 (2026-09-14)

- Post-upgrade hook: script **tested** here (no breakage to repair; reports clean); an actual rebuild after a breaking library update **not exercised**.
- Update survival on CachyOS: reasoned from file locations and pacman/DKMS behaviour; this machine has been through kernel/package updates with the same layout since June 2026 (private repo era), but no update was run today to prove the new hook.

## 0.5.0 (2026-09-14)

- Self-heal: quick path and a forced repair **tested** on the tested machine (files, packages, modules already present); a real SteamOS update **not tested**; module restore into a fresh /usr **not exercised**.

## 0.6.0 (2026-09-15)

- Wake guard: a controlled 4-minute DPMS sleep of the eGPU monitor (Desktop, DP, HDR on) woke normally within 1 s,
  so the stuck state reported by the user (and in NVIDIA #1055/#1028) was **not reproduced** during this session; the
  guard correctly stayed silent on that normal wake (no false trigger). Its recovery action (`vt-bounce`) is the
  same one that fixed the dark handheld panel on 2026-09-12. Real-world confirmation pending: the guard logs
  `-> vt-bounce` to the journal (`journalctl --user -t egpu-wake-guard`) when it acts.

## 0.6.1 (2026-09-15)

- Steam branch fix: diagnosed from Steam's bootstrap log (branch flip-flop on every Desktop/Game Mode switch); the fix is applied but **not yet observed** through a full Desktop→Game Mode cycle, and whether `SteamDeck=0` in the launcher's environment reaches games (keeping desktop resolution lists uncapped) is **to be confirmed** on the next desktop game launch.

## 0.6.2 (2026-09-15)

- 144 Hz Game Mode on the eGPU: the wrapper now stages 5120×1440@144 (verified from its environment dump); a Game
  Mode session at 144 Hz with the GBM-scanout gamescope has **not yet been run** (takes effect at the next session
  restart); the desktop already ran 144 Hz on the same link.
