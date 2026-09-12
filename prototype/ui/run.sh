#!/bin/bash
# PROTOTYPE runner: swift build → assemble a bare .app bundle → open it.
set -euo pipefail
cd "$(dirname "$0")"

swift build
BIN=".build/debug/EnvSetterPrototype"
APP=".build/EnvSetter 原型（用完即弃）.app"

mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/EnvSetterPrototype"
cp Info.plist "$APP/Contents/Info.plist"
touch "$APP"

open "$APP"
