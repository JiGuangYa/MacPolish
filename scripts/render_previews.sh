#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/previews"
PREVIEW_APP="$ROOT_DIR/.build/MacPolishPreview.app"
supported_localizations=(${(f)"$(<"$ROOT_DIR/Localization/supported_localizations.txt")"})
localizations=("$@")
if (( ${#localizations} == 0 )); then
  localizations=(en zh-Hans de)
fi
for localization in "${localizations[@]}"; do
  if (( ! ${supported_localizations[(Ie)$localization]} )); then
    print -u2 "Unsupported localization: $localization"
    exit 1
  fi
done

cd "$ROOT_DIR"
swift build --product MacPolishVerification
BIN_DIR="$(swift build --show-bin-path)"

mkdir -p "$PREVIEW_APP/Contents/MacOS" "$PREVIEW_APP/Contents/Resources"
cp "$BIN_DIR/MacPolishVerification" "$PREVIEW_APP/Contents/MacOS/MacPolishVerification"
rm -rf "$PREVIEW_APP/Contents/Resources/MacPolish_MacPolishKit.bundle"
cp -R "$BIN_DIR/MacPolish_MacPolishKit.bundle" "$PREVIEW_APP/Contents/Resources/"

# A real app bundle is required for Foundation to select dependency-bundle
# localizations. A bare command-line executable can silently fall back to en.
cat > "$PREVIEW_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacPolishVerification</string>
  <key>CFBundleIdentifier</key><string>com.jiguang.MacPolish.Preview</string>
  <key>CFBundleName</key><string>MacPolish Preview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>
$(for localization in "${supported_localizations[@]}"; do
  printf '    <string>%s</string>\n' "$localization"
done)
  </array>
</dict></plist>
EOF
plutil -lint "$PREVIEW_APP/Contents/Info.plist" >/dev/null

for localization in "${localizations[@]}"; do
  "$PREVIEW_APP/Contents/MacOS/MacPolishVerification" \
    --render-previews "$OUTPUT_DIR/$localization" \
    --expect-language "$localization" \
    -AppleLanguages "($localization)"
done
