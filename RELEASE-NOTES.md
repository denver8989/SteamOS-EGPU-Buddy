First public build.

**What it is**: hot-pluggable NVIDIA eGPU in Steam Game Mode on a Linux handheld: auto-attach, safe detach,
surprise-removal recovery (patched nvidia-open), clean gamescope scan-out on NVIDIA (GBM-scanout gamescope),
Steam launcher environment fix, UI scale clamp, boot-into-Game-Mode policy, EGPU Buddy Decky plugin.

**Installer**: run `SteamOS-EGPU-Buddy-0.1.0.run` (graphical, zenity; `--no-gui` for a terminal, `--uninstall`
to remove). Components can be ticked individually. Everything replaced is backed up next to the original.

**Tested**: CachyOS Deckify, Lenovo Legion Go 2, Gigabyte AORUS AI Box with RTX 5060 Ti, 5120×1440 DisplayPort,
nvidia-open 610.57.04. **Untested**: SteamOS, Bazzite, any other GPU/dock/display. The Game Mode session pieces
assume a `gamescope-session.service` user unit and a plasmalogin or steamos-session-select login flow; on Bazzite
they may not engage. The patched driver is Arch-based only. See TESTED.md.

**Credits**: see CREDITS.md; the scan-out fix is matt-schwartz's analysis and NightHammer1000's/antheas's gamescope
work; the hot-unplug driver patches are bdandy's and roger-pmta's on top of NickNill's AUR recipe.

Use at your own risk. This changes kernel modules, boot configuration, udev, sudoers and your Game Mode session.
