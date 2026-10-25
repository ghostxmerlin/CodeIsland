#!/bin/bash
# Builds build/MeyrinMic.driver (Meyrin Virtual Mic), ad-hoc signed. Install with: sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build
codesign --force --sign - build/MeyrinMic.driver
codesign -v build/MeyrinMic.driver
echo "built $(pwd)/build/MeyrinMic.driver"
