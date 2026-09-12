#!/usr/bin/env bash
# Install EGPU Buddy into Decky (run as root). Backs up and retires the legacy NV-EGPU-Buddy/Lego Hub plugin.
set -eu
SRC=$(cd "$(dirname "$0")" && pwd); DEST=${DECKY_PLUGIN_DEST:-/home/deck/homebrew/plugins/EGPU-Buddy}; OLD=/home/deck/homebrew/plugins/NV-EGPU-Buddy
[ -s "$SRC/dist/index.js" ] || { echo "build first: npm install && npm run build"; exit 1; }
if [ -d "$OLD" ]; then mkdir -p /home/deck/homebrew/plugins-retired && mv -f "$OLD" "/home/deck/homebrew/plugins-retired/NV-EGPU-Buddy.$(date +%Y%m%d-%H%M%S)"; fi
mkdir -p "$DEST/dist"
install -m0644 "$SRC/plugin.json" "$SRC/package.json" "$DEST/"; install -m0755 "$SRC/main.py" "$DEST/main.py"; install -m0644 "$SRC/dist/index.js" "$DEST/dist/index.js"
chown -R root:root "$DEST"; systemctl restart plugin_loader.service; echo "EGPU Buddy installed to $DEST (Decky restarted)"
