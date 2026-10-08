#!/bin/bash
set -euo pipefail
COMPANION_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$COMPANION_DIR/.build"
APP_DIR="$BUILD_DIR/Call Companion.app"
CODEX_BINARY="${CODEX_BINARY:-$(command -v codex)}"
DEVELOPER_ROOT="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
SWIFTC="${SWIFTC:-$DEVELOPER_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
SDKROOT="${SDKROOT:-$DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
if [[ ! -x "$SWIFTC" ]]; then SWIFTC="$(xcrun --find swiftc)"; fi
if [[ ! -d "$SDKROOT" ]]; then SDKROOT="$(xcrun --show-sdk-path)"; fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/module-cache"
"$SWIFTC" -swift-version 5 -O -target arm64-apple-macosx26.0 -sdk "$SDKROOT" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$COMPANION_DIR/Models.swift" "$COMPANION_DIR/ProjectContext.swift" "$COMPANION_DIR/SpeechCapture.swift" \
  "$COMPANION_DIR/AnswerEngine.swift" "$COMPANION_DIR/CompanionModel.swift" "$COMPANION_DIR/App.swift" \
  -o "$APP_DIR/Contents/MacOS/CallCompanion"
cp "$COMPANION_DIR/answer.schema.json" "$COMPANION_DIR/assistant-instructions.md" "$APP_DIR/Contents/Resources/"
cp "$COMPANION_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CallCompanion</string>
<key>CFBundleIdentifier</key><string>co.margilo.call-companion</string>
<key>CFBundleName</key><string>Call Companion</string>
<key>CFBundleDisplayName</key><string>Call Companion</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>2.1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSMicrophoneUsageDescription</key><string>Transcribe your call on this Mac and show private text suggestions using your selected project.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribe your call locally for text-only assistance.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$APP_DIR/Contents/Resources/launch.json" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>
PLIST
/usr/bin/plutil -insert codex -string "$CODEX_BINARY" "$APP_DIR/Contents/Resources/launch.json"
/usr/bin/plutil -convert json "$APP_DIR/Contents/Resources/launch.json"
/usr/bin/codesign --force --sign - --identifier co.margilo.call-companion "$APP_DIR"
printf '%s\n' "$APP_DIR"
