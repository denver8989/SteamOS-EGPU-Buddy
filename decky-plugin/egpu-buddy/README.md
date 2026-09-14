# EGPU Buddy (Decky plugin)

Attach and safely detach a Thunderbolt/USB4 NVIDIA eGPU from Steam Game Mode, see live eGPU details, set the
power limit, and install the whole [SteamOS EGPU Buddy](https://github.com/denver8989/SteamOS-EGPU-Buddy) system
integration from the Setup tab (hot-plug scripts, udev/systemd/modprobe/sudoers rules, Game Mode session
integration with the GBM-scanout gamescope, boot policy, desktop app). The plugin fetches the matching release
tarball from GitHub, verifies its SHA-256, and runs the installer as root; everything it replaces is backed up and
the Setup tab can uninstall it again.

Tested on CachyOS Deckify + Lenovo Legion Go 2 + RTX 5060 Ti. SteamOS and Bazzite untested. The patched
hot-unplug driver is not built from the plugin (Desktop `.run` installer, Arch-based only). This changes kernel
module configuration, udev, sudoers and your Game Mode session: read the project's TESTED.md first. MIT.
