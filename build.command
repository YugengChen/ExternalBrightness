#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
build_root="$(mktemp -d -t ExternalBrightness-build)"
trap 'rm -rf "$build_root"' EXIT
# Sign outside iCloud/File Provider folders, which may asynchronously attach
# FinderInfo to .app bundles and make codesign reject them.
app_path="$build_root/ExternalBrightness.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
    "$task_root"/Source/*.swift -framework AppKit -framework IOKit -framework ApplicationServices -framework Carbon \
    -o "$app_path/Contents/MacOS/ExternalBrightness"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ychen.ExternalBrightness</string>
<key>CFBundleName</key><string>ExternalBrightness</string>
<key>CFBundleDisplayName</key><string>外接屏亮度</string>
<key>CFBundleExecutable</key><string>ExternalBrightness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp "$task_root/THIRD_PARTY_NOTICES.txt" "$app_path/Contents/Resources/"
xattr -cr "$app_path"
codesign --force --sign - --identifier local.ychen.ExternalBrightness \
    --requirements '=designated => identifier "local.ychen.ExternalBrightness";' "$app_path"
codesign --verify --strict "$app_path"
"$app_path/Contents/MacOS/ExternalBrightness" --self-test
ditto --norsrc --noextattr "$app_path" "$task_root/ExternalBrightness.app"
printf 'Built: %s\n' "$task_root/ExternalBrightness.app"
