#!/bin/bash
# 构建 EnvSetter.app（本地构建、不签名、不沙盒）并默认打开。
#
#   ./Scripts/build-app.sh             # release 构建 + 打开
#   ./Scripts/build-app.sh --debug     # debug 构建（编译更快）
#   ./Scripts/build-app.sh --no-open   # 只构建
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
OPEN=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-open) OPEN=0 ;;
    *) echo "用法：$0 [--debug] [--no-open]" >&2; exit 2 ;;
  esac
done

swift build -c "$CONFIG" --product EnvSetterApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/EnvSetterApp"
APP=".build/EnvSetter.app"

# 整包重建：避免上次构建留下的文件混在里面。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/EnvSetterApp"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
# 让 Finder/Dock 立刻认出新包。
touch "$APP"

echo "已构建：$(pwd)/$APP"
if [ "$OPEN" = 1 ]; then
  open "$APP"
fi
