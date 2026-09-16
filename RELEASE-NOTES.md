0.7.10 — plugin: the progress bar is now a plain, full-width bar drawn by the plugin (the UI kit's bar rendered inline
next to its label and ran off the panel on every display). Used for installs, updates and repairs alike.

0.7.9 — plugin: with no eGPU the details page says just that (one line plus the session) instead of a wall of empty
metrics; the tab switcher is labelled by what it opens ("Show setup & updates"), never like an action; Reinstall in
Setup asks first and says what it does; the raw PipeWire placeholder no longer shows as the audio sink.

0.7.8 — plugin: "Safe to unplug the cable" now goes away by itself once the enclosure is actually unplugged (no
Thunderbolt/USB4 device enumerated and no GPU on the bus).

0.7.7 — Safe Detach and the updater no longer fight each other.

- **Cause of the dead Decky after a detach:** the plugin's automatic update ran 90 s after Game Mode started and
  scheduled its Decky restart exactly while Safe Detach was running as a child of the plugin. The stop hung on that
  child, systemd killed the whole group after 15 s (Decky, the plugin and the half-finished detach), and the failed
  restart left Decky down.
- Attach, Safe Detach and the Game Mode restart now run as transient system services outside Decky's process group;
  a Decky restart cannot interrupt them. Their output goes to /tmp/egpu-buddy-{attach,detach,switch}.log.
- The updater never acts while an attach/detach is pending or a game runs, and not in the first five minutes of a
  session; the Decky restart after a self-update is a try-restart.
- Attach and Safe Detach ask for confirmation and explain what will happen (screen goes dark, reopen the menu, it
  says when it is safe to unplug). The first page shows the operation state in colour and "Safe to unplug the cable."
- After "Restart Game Mode now" the post-install message no longer reappears.
- The surprise-removal recovery also skips when a Game Mode detach is in progress.

0.7.6 — plugin: the install/update progress row overflowed the Quick Access panel (long single-line stage text); it is
now the panel's item-style bar with a wrapping, length-capped description.

0.7.5 — plugin: Safe Detach from Game Mode did nothing. The detach script was launched with Decky's library path, so
bash died on a readline symbol before doing anything, silently. Same class as the 0.7.2 installer fix; the last plain
spawn in the backend is now cleaned too, and the detach's output goes to /tmp/egpu-buddy-detach.log.

0.7.4 — two boot/reboot mistakes fixed.

- **Booting with the eGPU attached landed on the Desktop.** The hot-plug script, when it brought the card up during
  boot, pinned the autologin session to the desktop before any session existed, overriding the Game Mode boot policy.
  It now only does that when re-logging an already running desktop session.
- **After an update the plugin offered a full system reboot.** Script updates need none: the plugin now offers
  "Restart Game Mode now" and only asks for a reboot when the driver or kernel parameters actually changed.
- The boot-enumerate unit no longer carries a free-text Documentation line that systemd rejected.

0.7.3 — plugin updater follows the newest of GitHub's latest release and the payload the plugin carries, so an
integration older than the plugin is brought up without a download; plugin self-replacement only when the release is
newer than the plugin's own payload.

0.7.2 — plugin: installs and updates launched from Decky failed with `bash: undefined symbol: rl_trim_arg_from_keyseq`
because Decky's Python exports its own LD_LIBRARY_PATH; the plugin now strips it for everything it spawns. Found by the
first real unattended update attempt.

0.7.1 — plugin: the update check works inside Decky's bundled Python (it has no certificate store; the distro's CA bundle
is now used), the first page shows plugin version, integration version and update state, and Attach/Safe Detach presses
are logged.

0.7.0 — automatic updates from the Decky plugin. Hourly check of this repository's releases; with *Automatic updates* on
(default) a new release installs the system integration (verified tarball, same installer) and replaces the plugin's own
files, reloads Decky and asks for a reboot; never while a game is running, never as a first install. *Update now* and
*Check for updates now* buttons; the toggle lives in Setup. The driver package is no longer rebuilt when the installed one
already matches the release.

0.6.3 — picture back after resume from suspend. A new system unit runs after every resume: when an eGPU display is
connected it forces the modeset (VT round-trip) that the NVIDIA DisplayPort link needs to re-train, then re-darkens the
handheld panel. Root cause 11. The privileged helper gained `panel-off`/`panel-on`.

0.6.2 — Game Mode on the eGPU no longer capped at 60 Hz. The session wrapper kept a 60 Hz ceiling from the corruption
era (it chose the output mode and handed Steam a 40–60 limit, so the refresh slider snapped back to 60 each session).
The cap is gone: the display's best mode is used (5120×1440@144 on the tested monitor) and Steam's slider spans 40 to
that. `NV_EGPU_GAMESCOPE_MAX_REFRESH` in the session drop-in caps it again if a display misbehaves.

0.6.1 — no more "update available, restart Steam" loop on the eGPU.

- The eGPU desktop Steam launcher now stays on the same client branch as Game Mode (`steamdeck_stable`, `-steamdeck`),
  so switching between the eGPU desktop and Game Mode no longer makes Steam reinstall the other branch, nag for a
  restart, and break Decky on that restart. Games launched from the desktop get `SteamDeck=0` so they keep their
  normal resolution lists. Root cause 10 in docs/ROOT-CAUSES.md.

0.6.0 — the eGPU display no longer stays dark after the monitor sleeps.

- **Wake guard** (`egpu-wake-guard`, user service): NVIDIA leaves the DRM connector off after a monitor sleep while the
  compositor thinks it is on (open-gpu-kernel-modules #1055/#1028); moving the mouse then shows nothing until a
  suspend/resume. The guard sees the input, notices the connector is still off four seconds later, and performs the VT
  round-trip that a suspend would, automatically. Root cause 9 in docs/ROOT-CAUSES.md.

0.5.0 — survives OS updates that wipe /usr (SteamOS-style).

- **Self-heal.** The install keeps the whole release, a pacman package cache (nvidia-utils, lib32, bolt, dkms, the
  patched driver package) and the patched modules for the running kernel under `~/.local/share/steamos-egpu-buddy`,
  and enables `egpu-buddy-selfheal.service` (unit in /etc, script in /home). At boot it re-applies the root-side
  integration when missing or outdated, restores cached packages, rebuilds or restores the kernel modules, and
  re-applies the kernel parameters. The plugin offers **Repair system integration** for the same on demand.
- SteamOS is therefore installable again (experimental, untested on a real update); the 0.4.2 refusal is gone.
- The uninstaller disables the self-heal unit and removes the kept copy.

0.4.2 — surviving updates, and the truth about SteamOS.

- **pacman hook** `egpu-buddy-post-upgrade`: after every transaction it checks the private GBM gamescope against the
  updated libraries and rebuilds it (or logs the fallback), and reports when the patched DKMS modules are missing
  for the newest kernel.
- **IgnorePkg** is appended to, never replaced (0.4.1 and earlier overwrote an existing line).
- **SteamOS itself is declared unsupported** and the installer/plugin refuse there unless overridden: its updates wipe
  `/usr`, it has no NVIDIA driver and no kernel headers. Targets are Arch-based handheld distros (CachyOS tested);
  Bazzite untested and without the patched driver. README has a "Surviving OS updates" section.

0.4.1 — SteamOS accounts without a password: the `.run` and the one-line installer detect it and have you set one
first (terminal prompt); the Decky plugin route never needed one, since Decky runs the plugin's backend as root and the
installer in root mode does not call sudo. README says which route needs what.

0.4.0 — one press, no choices.

- **The plugin's Install button and the `.run` install everything**: hot-plug core, session integration, GBM
  gamescope, boot policy, desktop app, the patched hot-unplug driver (Arch-based), the NVIDIA userspace pinned to the
  exact version the patched modules are built for (from the Arch Linux Archive, kept by IgnorePkg), and the kernel
  parameters written to the bootloader. No driver toggle, no questions. `--advanced` on the `.run` keeps the
  component checklist for people who want it.
- **First-ever connection on a fresh machine**: the hot-plug script now authorizes the Thunderbolt dock itself
  when boltd has not (Game Mode has no consent prompt), for security levels user/none/dponly, and enrols it with an
  auto policy; higher security levels are reported and need a one-time enrol from the desktop.
- **USB4/Thunderbolt stack**: the installer loads the `thunderbolt` driver at boot (modules-load.d), installs bolt where
  missing, and warns when no USB4/Thunderbolt controller is visible (firmware setting).
- The patched driver package now requires `nvidia-utils` of exactly its version, so a mismatched userspace cannot
  be left behind.

0.3.3 — safe first plug-in on a fresh machine.

- **Kernel command line is now handled.** New `egpu-kernel-cmdline --check/--apply` (rpm-ostree, Limine, GRUB,
  systemd-boot; backups kept). The installer reports what is missing and offers to write it; the plugin's first
  page shows an Apply button when the running kernel lacks the parameters. Earlier releases only documented them.
- **NVIDIA packages.** The installer offers to install `nvidia-open-dkms` + `nvidia-utils` with pacman when
  nvidia-smi is missing (the plugin route does it automatically).
- **Graphical installer fixed.** The `.run` GUI path ran `sudo` without a terminal, so on any machine that asks
  for a password it would have failed; it now asks with a dialog once and reuses it.
- README: a "Before you start" block: install and reboot with the eGPU disconnected, why, and what is assumed.

0.3.2 — simpler ways in.

- **Decky plugin: one press.** When the system integration is missing or outdated, the plugin's first page shows a
  single Install button; a progress bar reports the stages inline, then a Reboot button. No tab hunting, no double
  confirm. The Setup tab keeps the driver toggle and Uninstall.
- **One-line installer** (`get-egpu-buddy.sh`): fetches the latest release, verifies the SHA-256, offers to install
  Decky Loader from its official installer if missing, then runs the installer.
- README: the three install methods are outlined step by step.

0.3.1 — one build, two ways in.

- **Decky plugin can install everything.** New Setup tab: "Install system integration" runs `install.sh` as root
  from the payload bundled inside the plugin (no internet needed), with a progress bar driven by the installer's
  stages (core, session, prebuilt GBM gamescope, boot policy, desktop app, optional patched-driver build on
  Arch-based systems). Uninstall from the same tab. The installer gained a root mode for this
  (`EGPU_TARGET_USER`), creating user files as the login user. `EGPU-Buddy-Decky-0.3.0.zip` is the plugin for
  Decky's "Install from URL". The plugin is part of this repository (`decky-plugin/egpu-buddy`).
- **Driver install fixed.** The `--with-driver` step (and the plugin's driver toggle) now builds the
  `nvidia-open-egpu-dkms` package from the shipped PKGBUILD with makepkg and installs it with pacman. The 0.1.x–0.3.0
  script only copied modules that existed on the maintainer's machine and would have failed anywhere else.
- Plugin: GPU detection generalised to any NVIDIA VGA device (was pinned to one device ID); the Desktop hint no
  longer names another project.
- Desktop app icon: the eGPU box as a blue duotone illustration with the hot-plug bolt.
- All earlier releases (0.1.0–0.2.0) were removed; this is the only build.

Tested on the tested machine: the plugin's install route end-to-end as root against the live system (no drift
afterwards). SteamOS and Bazzite untested.

0.2.0 — standalone.

- **No references to any other project.** The Go Hub tray-app hooks that were guarded in 0.1.x are gone from the
  attach/detach scripts. In their place: `/etc/nv-egpu-buddy/hooks.d/{pre-unload,post-attach,post-detach}/`, where
  anyone can drop their own executables. Nothing is shipped there.
- **EGPU Buddy desktop app** (`desktop-app/`, component `desktopapp`, on by default): telemetry, power limit, reset
  clocks, Safe Detach, Re-attach for the docked Desktop. GTK 4/WebKitGTK window with browser fallback. Backend on
  127.0.0.1:8772 uses only the shipped helpers. New icon, `EGPU Buddy` menu entry, removed by the uninstaller.
- **sudoers fix.** 0.1.x only whitelisted the privileged helper, so the Desktop Safe Detach tool (`sudo -n
  egpu-safe-detach`) would have asked for a password or failed on a fresh install. The rule now covers
  egpu-safe-detach, egpu-reattach, egpu-gamemode-switch/-detach and egpu-rearm.
- Holder kill list before driver unload no longer names foreign apps; use a `pre-unload` hook for yours.

Tested on the tested machine: desktop app backend (status + guards) and the installer component; the GTK window
was not opened by the maintainer's automation (launch it yourself). Scripts otherwise unchanged from 0.1.2.
SteamOS and Bazzite untested.

0.1.2 — installer warns about missing runtime tools (setpci, modetest, jq, xxd, perl, qdbus6, kscreen-doctor, xprop, boltctl, nvidia-smi); README states what is and is not required (no Go Hub, no LACT, no desktop tray app). No script changes.

0.1.1 — two hot-plug regressions found the day after 0.1.0, both on the tested machine.

- **Desktop Safe Detach re-logged into Game Mode with a dark handheld panel.** The KWin restart ends the login and
  the boot policy chose Game Mode; that gamescope started with an inactive seat and never lit the panel. Fixed:
  the detach pins the re-login to the desktop, and the session wrapper bounces the VT if the panel is still off
  12 s after gamescope starts (`nv-egpu-buddy-privileged vt-bounce`). Root cause 7 in docs/ROOT-CAUSES.md.
- **Hot plug on the Desktop left a frozen image on the handheld panel.** KWin runs NVIDIA-only and cannot disable
  `eDP-1`; the hot-plug script now turns the unowned CRTC off itself. Root cause 8.
- The boot policy now writes both `/etc/plasmalogin.conf` and the `conf.d` override that `os-session-select`
  creates (the override was winning).
- The attach-time environment file is no longer shipped as a static install (it pinned fresh installs to a card
  that is not there); it is written on attach and removed on detach.
- README: new *How it works* section (AMD crosstalk workaround, bandwidth/ReBAR/link pinning, operating modes and
  the panel-off state).

Re-tested on the tested machine: hot plug on the Desktop (panel now off). Not yet re-run since the change:
Desktop Safe Detach and the re-login watchdog. Installer flow unchanged from 0.1.0. SteamOS and Bazzite untested.
