# What is tested, what is not, and what can bite you

Everything below was verified on the single machine described in the README (Legion Go 2 + RTX 5060 Ti eGPU +
5120×1440 DisplayPort monitor, CachyOS Deckify, nvidia-open 610.57.04). "Verified" means it was exercised
repeatedly in one session on 2026-09-11/12 and behaved as described. Nothing here has been run on a second machine.

## SteamOS: verified in a container built from Valve's image, not on a device (0.7.17)

Test environment: the root filesystem of Valve's `steamdeck-oobe-repair-20260707.10-3.8.14` image, run with
`systemd-nspawn`, a writable `/etc` overlay, a separate small `/var` and `/home` on their own (as SteamOS mounts
them; until 0.7.21 the container also mounted `/usr/local` separately, which SteamOS 3.8 does **not** do: that mistake
hid the 0.7.21 reinstall failure described below), Valve's real `pacman.conf`, repositories and keyrings, no compiler on the host.

| Verified there | Result |
|---|---|
| Full `install.sh` as root with the Decky plugin's component list, no prompts | exit 0, "driver 610.57.04 active ... system partition untouched" |
| pacman keyring initialisation on a stock image | works (this was the first failure on a real Legion Go, SteamOS) |
| Kernel headers for the exact running kernel (`valve24.4`, while the repository offers `valve24.5`) | fetched from Valve's mirror by version |
| Patched 610.57.04 modules compiled against Valve's 6.16.12 kernel | `modinfo`: version 610.57.04, matching vermagic, hot-unplug patch strings present |
| System extension merged into a read-only `/usr` | libraries visible, 102 NVIDIA entries in the loader cache, `modprobe --show-depends nvidia_drm` resolves |
| Simulated reboot (extension unmerged) -> self-heal | re-activated offline |
| Simulated kernel change (modules removed) -> boot path | modules rebuilt, driver active |
| Safe Detach hide/restore on the read-only merged `/usr` | 10 files covered by bind mounts, unreadable to users, restored, no mounts left |
| OS-update keep-list, GRUB drop-in (as Valve's `grub-mkconfig` sources it) | written; resulting command line contains the parameters |
| Uninstall | nothing left: extension, build environment, keep-list, drop-in, units, scripts |

## SteamOS: boot WITH the eGPU attached, end to end (0.7.46)

Same Legion Go (the first one), SteamOS 3.8, kernel 6.16.12-valve24.5, RTX 5060 Ti in a Gigabyte AORUS TB5 box,
5120x1440@144 ultrawide. 2026-09-20, read from the machine's own logs rather than reported by eye.

| Verified on the device | Result |
|---|---|
| Boot with the eGPU attached, on the **second** USB4 port | Game Mode comes up on the monitor, handheld panel dark |
| BAR1 at boot | `BAR1 resized while driverless -> 16384MiB` — the full bar, on the first path, no re-enumeration |
| Surprise-removal protection | applied at boot (`uncorrectable errors masked`), not only on attach |
| A monitor in standby at boot | answers the forced probe; the session lands on it |
| Quiet boot, no boot menu | `quiet` and `splash` reach the kernel; 13 s from power to network |
| The session stays up | past 3 minutes, where earlier builds tore it down at ~90 s |
| Either USB4 port | both reach a full 16 GiB BAR1; the eGPU enumerates behind whichever root port is used |
| Patched driver detection | read from the installed modules, not from a package SteamOS does not have |

Also verified on 2026-09-20, by swapping the cable on a live session:

| Verified on the device | Result |
|---|---|
| DisplayPort -> HDMI while attached, on a TV | `staging Game Mode output 4096x2160@120 on HDMI-A-1` — 4K at 120 Hz |
| HDMI -> DisplayPort back again | `staging Game Mode output 5120x1440@144 on DP-9` |
| The handheld panel during the gap with no eGPU output | came back on by itself, and went dark again once the TV had the picture |
| Audio across both swaps | stayed on the eGPU output; the sink is chosen by port availability, so DP and HDMI behave the same |

Not verified on this machine: a from-scratch install after a full uninstall (the next thing to test), and anything on
hardware other than the two handhelds named here.

## SteamOS: tested on a real device (0.7.23)

Legion Go (the first one), SteamOS 3.8, kernel 6.16.12-valve24.5, RTX 5060 Ti in a Gigabyte AORUS TB5 box, Acer X49 V
ultrawide at 5120x1440@144 over DisplayPort. Everything below was done on that machine on 2026-09-19 and watched in its
own logs.

| Verified on the device | Result |
|---|---|
| Install from the release payload, repeatedly, including over a working install | exit 0, ~30 s; the driver extension is unmerged and re-merged around the write |
| Patched 610.57.04 built on the device and merged as a system extension | driver active, modules and libraries resolve, survives a re-run |
| Attach in Game Mode (plug in, no button) | ~30 s from plug to Game Mode on the monitor; BAR1 16 GB, link pinned Gen3 x4 |
| Game Mode picture | clean, no scanout corruption, with the GBM-scanout gamescope built for SteamOS |
| Steam UI at the display's native mode | 5120x1440@144, UI scale applied |
| A game in Game Mode | played, "works fine, operates well" |
| Safe Detach in Game Mode | SAFE_COMPLETE, 51 s (was 98 s before the wait fix) |
| Replug after a Safe Detach | auto-attached, Game Mode back on the monitor |
| Surprise unplug in Game Mode | recovered in 8 s, one session relaunch, no reset, driver unloaded |
| Desktop mode on the eGPU | NVIDIA-only: the compositor holds only the eGPU's nodes, the built-in GPU is held by nobody |
| Safe Detach from the desktop | SAFE_COMPLETE, compositor back on the built-in GPU, panel and backlight restored |
| Surprise unplug on the desktop | recovered in 8 s, no reset, Steam and the tray app came back |
| Kernel parameters, self-heal service, keep-list, GRUB drop-in | written and effective |
| Uninstall | nothing left behind |

**Not the same machine as the development one:** its USB4 root ports have no Downstream Port Containment, its GPUs
enumerate the other way round (the eGPU is `card1`), its login manager is `sddm`, and its Game Mode session file has a
different name. Each of those broke something that had only ever run on the development machine; see the 0.7.23 notes.

**Known limitation there:** HDR must be enabled on the monitor itself as well as in Steam. With the display's own HDR
mode off, enabling HDR in Steam gives a washed out, grey picture — that is the display, not the software.

**Real device, 2026-09-19 (Legion Go, SteamOS 3.8, kernel 6.16.12-valve24.5):** with 0.7.20 the build environment,
the headers for the exact kernel and the driver compile all succeeded; assembling the extension then failed with
`overlay: case-insensitive capable filesystem ... not supported`, because SteamOS formats `/home` as case-folding ext4
and the test container's `/home` was not. Since 0.7.21 the extension is a squashfs image and no overlay layer is ever
placed on `/home`; the container's `/home` is now a case-folding ext4 too, and a shim there refuses overlay layers on
it the way Valve's kernel does (the development kernel is newer and no longer refuses). Re-verified there: full
install exit 0, image merged (layers: `/run/systemd/sysext/...` and `/usr` only), modules and libraries resolve,
boot re-activation, from-scratch driver build 2 min 56 s on 16 threads.

**Real device, 0.7.21:** the first install completed and the driver extension merged. A second install then failed
with `Read-only file system` on `/usr/local/sbin`: on SteamOS `/usr/local` is part of the system partition, and a merged
extension makes all of `/usr` a read-only overlay. Since 0.7.22 the installer and the uninstaller unmerge the extension
first (refusing while the NVIDIA driver is loaded) and merge it again on every way out. The container now has one
writable system partition including `/usr/local`; there, 0.7.21 reproduces the failure and 0.7.22 passes: fresh
install, install again while merged, uninstall while merged.

**Not yet verified on a real SteamOS device:** the merged extension and everything after it. Unknown until someone runs it there: boot ordering on real hardware,
GRUB regeneration on the device, a real OS update, loading the modules with an eGPU attached, and everything the
NVIDIA path does at attach time on a non-Legion-Go-2 machine.

## Verified

Re-verified on 2026-09-18 (0.7.15), each ending with a game launched and displayed on the eGPU monitor: Safe Detach from
the plugin -> physical unplug -> replug; cable yank in Game Mode -> replug. Both need no reboot and no enclosure power
cycle.

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

- 144 Hz Game Mode on the eGPU: **verified** by the user after the next session start (5120×1440@144 with the
  GBM-scanout gamescope); VRR from the Quick Access menu no longer caps games at 60 fps, and the display setting
  stays at 144.

## 0.6.3 (2026-09-16)

- Post-resume kick: the manual VT round-trip **recovered** the monitor after a real resume on the tested machine (Game
  Mode, 144 Hz); the automatic unit is installed and enabled but **not yet exercised** by a suspend/resume cycle.

## 0.7.0 (2026-09-16)

- Auto-update: **verified end to end from inside Decky** on the tested machine. 0.7.0→0.7.1 failed on Decky's
  LD_LIBRARY_PATH (fixed in 0.7.2), 0.7.2 installed the integration from a downloaded release, and 0.7.3 was a full
  unattended update: release found, tarball verified, integration installed (rc 0), plugin files replaced (backup
  kept), Decky restarted itself, plugin reloaded, first page asked for a reboot.

## 0.7.2 (2026-09-16)

- First real plugin-driven update (0.7.0→0.7.1) **failed** on LD_LIBRARY_PATH from Decky's Python; fixed here.

## 0.7.4 (2026-09-16)

- Boot with the eGPU attached: the desktop landing was **reproduced** on the tested machine (journal: policy wrote Game
  Mode, the hot-plug script overwrote it 0.5 s later); the gate is applied, the next boot with the eGPU attached is the test.
- Post-update "Restart Game Mode" button: **not yet pressed** in the UI.

## 0.7.5 (2026-09-16)

- Safe Detach from the plugin: press reached the backend (logged) and the script died on Decky's LD_LIBRARY_PATH;
  fixed; a press after the fix is the test (user).

## 0.7.7 (2026-09-16)

- The detach/updater collision was **reproduced from the logs** on the tested machine; the fixes are applied, and a Safe
  Detach from the plugin after them is the test (user).

## 0.7.11 (2026-09-16)

- Audio loss after the interrupted detach: **reproduced** (WirePlumber stopped at 09:01, never restarted); manual start
  restored speaker and microphone; the two safety nets are applied, not yet exercised by another interrupted detach.

## 0.7.12 (2026-09-16)

- Documentation and versioning only; no script changes.
