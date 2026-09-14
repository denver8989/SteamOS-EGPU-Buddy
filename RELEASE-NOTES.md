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
