#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

VERSION="${HUSK_VERSION:-1.0.5}"
GITHUB_REPO="${HUSK_GITHUB_REPO:-Piskaty/husk}"
BUILD_MODE="${1:---release}"
husk_signing_key="${HUSK_UPDATE_SIGNING_KEY:-}"
unset HUSK_UPDATE_SIGNING_KEY
if [[ -z "$husk_signing_key" && "${HUSK_REQUIRE_UPDATE_SIGNATURE:-0}" == "1" ]]; then
  echo "HUSK_UPDATE_SIGNING_KEY is required to package a signed release." >&2
  exit 1
fi

# 1. Build Husk.app bundle
HUSK_VERSION="$VERSION" "$SCRIPT_DIR/build-app.sh" "$BUILD_MODE"

DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/Husk.app"
ZIP_NAME="Husk-${VERSION}-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
DMG_NAME="Husk-${VERSION}-macos-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# 2. Create distributable .zip archive (preserves code signature & resource forks)
/usr/bin/lipo "$APP_BUNDLE/Contents/MacOS/Husk" -verify_arch arm64
rm -f "$ZIP_PATH" "$ZIP_PATH.sig" "$DMG_PATH"
echo "▸ Creating release archive: $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
SIGNATURE_FIELD=""
if [[ -n "$husk_signing_key" ]]; then
  PUBLIC_KEY="$(sed -n 's/^ *static let releaseSigningPublicKey = "\([^"]*\)".*/\1/p' Sources/DevCleanerCore/Updater/UpdateService.swift)"
  HUSK_UPDATE_SIGNING_KEY="$husk_signing_key" swift -module-cache-path "${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}" \
    "$SCRIPT_DIR/sign-update.swift" "$ZIP_PATH" "$PUBLIC_KEY"
  SIGNATURE_FIELD="  \"signatureURL\": \"https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ZIP_NAME.sig\","
fi

# 3. Create mountable .dmg image if hdiutil is available and permitted
DMG_STAGE="$(mktemp -d /tmp/husk-dmg-stage.XXXXXX)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$APP_BUNDLE" "$DMG_STAGE/Husk.app"
ln -s /Applications "$DMG_STAGE/Applications"

if hdiutil create -volname "Husk" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1; then
  echo "✓ Created disk image: $DMG_PATH"
else
  echo "ℹ hdiutil skipped in sandboxed shell; using $ZIP_NAME as primary release archive"
fi
rm -rf "$DMG_STAGE"

# 4. Generate SHA256SUMS.txt and website latest.json manifest
SHA256_HASH="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
PUBLISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

(
  cd "$DIST_DIR"
  if [[ -f "$DMG_NAME" ]]; then
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
  else
    shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt
  fi
)

awk -v version="$VERSION" '
  $1 == "##" { if (in_release) exit; in_release = ($2 == version); next }
  in_release { print }
' CHANGELOG.md > "$DIST_DIR/RELEASE_NOTES.md"
if ! grep -q '^-' "$DIST_DIR/RELEASE_NOTES.md"; then
  echo "Missing changelog entry for $VERSION." >&2
  exit 1
fi

cat > "$DIST_DIR/latest.json" <<JSON
{
  "version": "$VERSION",
  "downloadURL": "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ZIP_NAME",
  $SIGNATURE_FIELD
  "releasePageURL": "https://github.com/$GITHUB_REPO/releases/tag/v$VERSION",
  "publishedAt": "$PUBLISHED_AT",
  "sha256": "$SHA256_HASH",
  "releaseNotes": "See the release page or the in-app Changelog for Husk v$VERSION."
}
JSON

echo "✓ Generated website update manifest: $DIST_DIR/latest.json"
echo "✓ Generated checksums: $DIST_DIR/SHA256SUMS.txt"
