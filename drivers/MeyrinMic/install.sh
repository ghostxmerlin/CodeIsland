#!/bin/bash
# Installs (or with -u removes) Meyrin Virtual Mic and restarts coreaudiod: every app's audio drops for a second or two.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }
cd "$(dirname "$0")"
target=/Library/Audio/Plug-Ins/HAL/MeyrinMic.driver
if [ "${1:-}" = "-u" ]; then
    rm -rf "$target"
else
    [ -d build/MeyrinMic.driver ] || { echo "run ./build.sh first"; exit 1; }
    rm -rf "$target"
    cp -R build/MeyrinMic.driver "$target"
    chown -R root:wheel "$target"
fi
# launchd starts coreaudiod again at once (launchctl kickstart is refused under SIP on macOS 26).
killall coreaudiod || true
echo "done"
