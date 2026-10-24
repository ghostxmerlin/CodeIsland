#!/bin/bash
# Builds .build/release/MeilingInputMethod.app (美玲输入法), ad-hoc signed. build.sh embeds it into AISM.app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        [ -d "$xcode/Contents/Developer" ] && export DEVELOPER_DIR="$xcode/Contents/Developer" && break
    done
fi
swift build -c release --product MeilingInputMethod
app=".build/release/MeilingInputMethod.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/MeilingInputMethod "$app/Contents/MacOS/MeilingInputMethod"
cp Sources/MeilingInputMethod/Info.plist "$app/Contents/Info.plist"
codesign -s - --force --deep "$app"
codesign -v "$app"
echo "built $app"
