#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

CONFIG="release"
RUN_AFTER_BUILD=false
VERSION="${HUSK_VERSION:-1.0.5}"
BUILD_NUMBER="${HUSK_BUILD_NUMBER:-6}"

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIG="debug"
      ;;
    --release)
      CONFIG="release"
      ;;
    --run)
      RUN_AFTER_BUILD=true
      ;;
  esac
done

echo "▸ Building Husk v$VERSION ($CONFIG)..."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
SWIFT_BUILD_ARGS=(-c "$CONFIG" --disable-sandbox --cache-path /tmp/swiftpm-cache)
swift build "${SWIFT_BUILD_ARGS[@]}" -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH"

BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BINARY_PATH="$BIN_DIR/DevCleanerApp"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Missing compiled binary: $BINARY_PATH" >&2
  exit 1
fi

APP_BUNDLE="$PROJECT_ROOT/dist/Husk.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE" "$PROJECT_ROOT/dist/DevCleaner.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/Husk"
chmod +x "$MACOS_DIR/Husk"
cp "$PROJECT_ROOT/CHANGELOG.md" "$RESOURCES_DIR/CHANGELOG.md"

# Generate native AppIcon.icns directly
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$SCRIPT_DIR/generate-icon.swift" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Husk</string>
    <key>CFBundleExecutable</key>
    <string>Husk</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.stabil.husk</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Husk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Code sign (uses DEVELOPER_ID_APPLICATION if provided, otherwise ad-hoc signs)
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

echo "✓ Packaged native macOS bundle at: $APP_BUNDLE"

if [[ "$RUN_AFTER_BUILD" == "true" ]]; then
  echo "▸ Launching Husk.app..."
  open "$APP_BUNDLE"
fi
