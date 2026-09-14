#!/bin/bash
# SteamOS EGPU Buddy one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/denver8989/SteamOS-EGPU-Buddy/master/get-egpu-buddy.sh | bash
# Fetches the latest release, verifies its SHA-256, offers to install Decky Loader from its official installer if it
# is missing, then runs the EGPU Buddy installer (graphical if a display is available, otherwise in this terminal).
set -euo pipefail
REPO=denver8989/SteamOS-EGPU-Buddy
say(){ printf '\033[1m%s\033[0m\n' "$*"; }
ask(){ read -rp "$1 [y/N] " r </dev/tty; [ "${r,,}" = y ]; }
[ "$(id -u)" = 0 ] && { echo "run this as your normal user (sudo is asked for when needed)"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
if [ "$(passwd -S "$USER" 2>/dev/null | awk '{print $2}')" != P ]; then
  say "== your account has no password (SteamOS default); sudo needs one. Set it now (typed twice, nothing is shown):"
  passwd </dev/tty; [ "$(passwd -S "$USER" 2>/dev/null | awk '{print $2}')" = P ] || { echo "no password set; cannot continue"; exit 1; }
fi
say "== SteamOS EGPU Buddy: looking up the latest release"
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$TAG" ] || { echo "could not determine the latest release"; exit 1; }
VER=${TAG#v}; NAME="SteamOS-EGPU-Buddy-$VER.run"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
say "== downloading $NAME"
curl -fSL --progress-bar -o "$T/$NAME" "https://github.com/$REPO/releases/download/$TAG/$NAME"
curl -fsSL -o "$T/SHA256SUMS" "https://github.com/$REPO/releases/download/$TAG/SHA256SUMS"
WANT=$(awk -v n="$NAME" '$2 ~ ("(^|/)" n "$") {print $1; exit}' "$T/SHA256SUMS"); GOT=$(sha256sum "$T/$NAME" | cut -d" " -f1)
[ -n "$WANT" ] && [ "$WANT" = "$GOT" ] && say "== checksum ok" || { echo "checksum mismatch, aborting"; exit 1; }
chmod +x "$T/$NAME"
if [ ! -d "$HOME/homebrew/plugins" ]; then
  say "== Decky Loader is not installed (needed for the Game Mode plugin)"
  if ask "Install Decky Loader now with its official installer (github.com/SteamDeckHomebrew/decky-installer)?"; then
    curl -fsSL https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh </dev/tty || echo "Decky installer returned an error; continuing without the plugin"
  fi
fi
[ "${EGPU_BOOTSTRAP_DRYRUN:-0}" = 1 ] && { say "== dry run: would now run $NAME"; exit 0; }
say "== running the installer"
"$T/$NAME" "$@" </dev/tty
