#!/usr/bin/env zsh
set -euo pipefail

REPO="${HUSK_GITHUB_REPO:-Piskaty/husk}"
INSTALL_DIR="/Applications"
APP_NAME="Husk.app"
TMP_DIR="$(mktemp -d /tmp/husk-install-XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "▸ Checking latest Husk release from github.com/$REPO..."
RELEASE_JSON="$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest")"

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
ZIP_URL="$(printf '%s' "$RELEASE_JSON" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
assets = data.get("assets", [])
zips = [a["browser_download_url"] for a in assets if a.get("name", "").endswith(".zip")]
print(zips[0] if zips else "")
')"

if [[ -z "$ZIP_URL" ]]; then
  echo "✗ Could not find a .zip release archive in $REPO ($TAG_NAME)."
  exit 1
fi

echo "▸ Downloading Husk $TAG_NAME..."
curl -fL --progress-bar "$ZIP_URL" -o "$TMP_DIR/Husk.zip"

echo "▸ Extracting to $INSTALL_DIR/$APP_NAME..."
ditto -x -k "$TMP_DIR/Husk.zip" "$TMP_DIR/extracted"

if [[ ! -d "$TMP_DIR/extracted/$APP_NAME" ]]; then
  echo "✗ Expected $APP_NAME inside archive."
  exit 1
fi

# Close any running instance cleanly before swapping the app bundle
killall Husk 2>/dev/null || true

rm -rf "$INSTALL_DIR/$APP_NAME"
mv "$TMP_DIR/extracted/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

# Clear any extended quarantine attribute (ad-hoc signed open-source build)
xattr -cr "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true

echo "✓ Installed Husk $TAG_NAME to $INSTALL_DIR/$APP_NAME"
echo "▸ Launching Husk..."
open "$INSTALL_DIR/$APP_NAME"
