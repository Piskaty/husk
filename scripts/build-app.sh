#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

CONFIG="release"
RUN_AFTER_BUILD=false
VERSION="${HUSK_VERSION:-1.0.4}"
BUILD_NUMBER="${HUSK_BUILD_NUMBER:-5}"

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
swift build -c "$CONFIG" \
  --disable-sandbox \
  --cache-path /tmp/swiftpm-cache \
  -Xswiftc -module-cache-path \
  -Xswiftc "$CLANG_MODULE_CACHE_PATH"

BIN_DIR="$PROJECT_ROOT/.build/$CONFIG"
BINARY_PATH="$BIN_DIR/DevCleanerApp"

if [[ ! -f "$BINARY_PATH" ]]; then
  BINARY_PATH="$(find "$PROJECT_ROOT/.build" -name DevCleanerApp -type f | head -n 1)"
fi

APP_BUNDLE="$PROJECT_ROOT/dist/Husk.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE" "$PROJECT_ROOT/dist/DevCleaner.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/Husk"
chmod +x "$MACOS_DIR/Husk"

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
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null || true
fi

echo "✓ Packaged native macOS bundle at: $APP_BUNDLE"

if [[ "$RUN_AFTER_BUILD" == "true" ]]; then
  echo "▸ Launching Husk.app..."
  open "$APP_BUNDLE"
fi
