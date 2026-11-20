#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

VERSION="${HUSK_VERSION:-1.0.0}"
GITHUB_REPO="${HUSK_GITHUB_REPO:-Piskaty/husk}"
BUILD_MODE="${1:---release}"

# 1. Build Husk.app bundle
HUSK_VERSION="$VERSION" "$SCRIPT_DIR/build-app.sh" "$BUILD_MODE"

DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/Husk.app"
ZIP_NAME="Husk-${VERSION}-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
DMG_NAME="Husk-${VERSION}-macos-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# 2. Create distributable .zip archive (preserves code signature & resource forks)
rm -f "$ZIP_PATH" "$DMG_PATH"
echo "▸ Creating release archive: $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# 3. Create mountable .dmg image if hdiutil is available and permitted
DMG_STAGE="/tmp/husk-dmg-stage-$$"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/Husk.app"
ln -s /Applications "$DMG_STAGE/Applications"

if hdiutil create -volname "Husk" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1; then
  echo "✓ Created disk image: $DMG_PATH"
  PRIMARY_ASSET="$DMG_NAME"
  PRIMARY_PATH="$DMG_PATH"
else
  echo "ℹ hdiutil skipped in sandboxed shell; using $ZIP_NAME as primary release archive"
  PRIMARY_ASSET="$ZIP_NAME"
  PRIMARY_PATH="$ZIP_PATH"
fi
rm -rf "$DMG_STAGE"

# 4. Generate SHA256SUMS.txt and website latest.json manifest
SHA256_HASH="$(shasum -a 256 "$PRIMARY_PATH" | awk '{print $1}')"
PUBLISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

(
  cd "$DIST_DIR"
  if [[ -f "$DMG_NAME" ]]; then
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
  else
    shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt
  fi
)

cat > "$DIST_DIR/latest.json" <<JSON
{
  "version": "$VERSION",
  "downloadURL": "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$PRIMARY_ASSET",
  "releasePageURL": "https://github.com/$GITHUB_REPO/releases/tag/v$VERSION",
  "publishedAt": "$PUBLISHED_AT",
  "sha256": "$SHA256_HASH",
  "releaseNotes": "Husk v$VERSION — Minimal native macOS Liquid Glass developer disk & cache cleaner with 5-layer safety engine, 1-Click Safe Sweep, dormant clone detection, and native tool tasks."
}
JSON

echo "✓ Generated website update manifest: $DIST_DIR/latest.json"
echo "✓ Generated checksums: $DIST_DIR/SHA256SUMS.txt"
