#!/usr/bin/env bash
# Build the release artifacts: a self-extracting installer (.run) and a plain tarball, then publish with gh.
#   ./build-release.sh            build into dist/
#   ./build-release.sh --publish  build and create the GitHub release for the version in VERSION
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd); cd "$ROOT"
VER=$(cat VERSION); NAME="SteamOS-EGPU-Buddy-$VER"
rm -rf dist && mkdir -p dist/stage/"$NAME"
# Decky plugin: pin the payload version it fetches, build the frontend, zip it for "install from URL"
P=decky-plugin/egpu-buddy
sed -i "s/^PAYLOAD_VERSION = \"[^\"]*\"/PAYLOAD_VERSION = \"$VER\"/" "$P/main.py"
(cd "$P" && npm install --no-audit --no-fund >/dev/null 2>&1 && npm run build >/dev/null 2>&1)
mkdir -p dist/plugin/EGPU-Buddy && cp -r "$P/dist" "$P/main.py" "$P/plugin.json" "$P/package.json" "$P/README.md" "$P/LICENSE" dist/plugin/EGPU-Buddy/
(cd dist/plugin && python3 -c "import shutil,sys; shutil.make_archive(sys.argv[1], 'zip', '.', 'EGPU-Buddy')" "../EGPU-Buddy-Decky-$VER")
git ls-files -z | grep -zvE '^(dist/|\.github/|build-release\.sh|decky-plugin/egpu-buddy/(src|node_modules|pnpm-lock|rollup|tsconfig|\.gitignore))' | xargs -0 -I{} cp --parents {} dist/stage/"$NAME"/
# prebuilt gamescope is not tracked (binary); ship it in the artifacts
cp -a prebuilt dist/stage/"$NAME"/ 2>/dev/null || true
chmod +x dist/stage/"$NAME"/install.sh dist/stage/"$NAME"/uninstall.sh dist/stage/"$NAME"/installer/steamos-egpu-buddy
tar -C dist/stage -czf "dist/$NAME.tar.gz" "$NAME"
# self-extracting: shell header + tarball
{
cat <<'HDR'
#!/bin/sh
# SteamOS EGPU Buddy self-extracting installer. Run it; use --uninstall to remove; --no-gui for a terminal.
set -e
T=$(mktemp -d "${TMPDIR:-/tmp}/steamos-egpu-buddy.XXXXXX")
LINE=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$0")
tail -n +"$LINE" "$0" | tar -xzf - -C "$T"
D=$(ls -d "$T"/SteamOS-EGPU-Buddy-*)
exec bash "$D/installer/steamos-egpu-buddy" "$@"
__PAYLOAD_BELOW__
HDR
cat "dist/$NAME.tar.gz"
} > "dist/$NAME.run"
chmod +x "dist/$NAME.run"
sha256sum "dist/$NAME.run" "dist/$NAME.tar.gz" "dist/EGPU-Buddy-Decky-$VER.zip" > dist/SHA256SUMS
ls -la dist | grep -E 'run|tar|SHA'
if [ "${1:-}" = --publish ]; then
  gh release create "v$VER" "dist/$NAME.run" "dist/$NAME.tar.gz" "dist/EGPU-Buddy-Decky-$VER.zip" dist/SHA256SUMS --title "SteamOS EGPU Buddy $VER" --notes-file RELEASE-NOTES.md
fi
