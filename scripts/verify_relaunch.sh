#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_APP="$ROOT_DIR/.build/MacPolishRelaunchProbe.app"
cd "$ROOT_DIR"
swift build --product MacPolishVerification
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "$PROBE_APP/Contents/MacOS"
cp "$BIN_DIR/MacPolishVerification" "$PROBE_APP/Contents/MacOS/Probe"
cat > "$PROBE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleIdentifier</key><string>com.jiguang.MacPolish.RelaunchProbe</string>
  <key>CFBundleName</key><string>MacPolish Relaunch Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSBackgroundOnly</key><true/>
  <key>MacPolishRelaunchProbe</key><true/>
</dict></plist>
PLIST
plutil -lint "$PROBE_APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$PROBE_APP"
"$BIN_DIR/MacPolishVerification" --verify-relaunch-launcher "$PROBE_APP"
