#!/bin/bash
# 构建 EnvSetter.app 并安装到 ~/Applications/EnvSetter.app——日常从 Dock / Spotlight 打开的位置。
#
#   ./Scripts/install-app.sh             # release 构建 + 安装（没有实例在跑时顺带打开）
#   ./Scripts/install-app.sh --debug     # debug 构建（编译更快）
#   ./Scripts/install-app.sh --no-open   # 装完不打开
#
# 重复运行是覆盖安装：整包重建，且不打断正在运行的实例——退出并重新打开应用后才会用上新版本。
# 构建产物 .build/EnvSetter.app 原样留着，供验收与快速迭代。
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN=1
for arg in "$@"; do
  case "$arg" in
    --debug) ;;
    --no-open) OPEN=0 ;;
    *) echo "用法：$0 [--debug] [--no-open]" >&2; exit 2 ;;
  esac
done

# 换安装位置（验收与脚本用）：ENVSETTER_INSTALL_DIR=/tmp/x ./Scripts/install-app.sh
DEST_DIR="${ENVSETTER_INSTALL_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/EnvSetter.app"
SRC=".build/EnvSetter.app"

# 先构建：构建失败时已装的那份原封不动。构建口径（含 --debug）交给 build-app.sh。
./Scripts/build-app.sh --no-open "$@"

# 整包重建 + 换位：新包先在目标目录里装好、验过，再换掉旧的。旧包要到新包就位之后才删，
# 万一换位只做了一半，cleanup 会把它放回原位——任何一步失败都不会把已装的实例弄丢。
mkdir -p "$DEST_DIR"
STAGE="$(mktemp -d "$DEST_DIR/.envsetter-install.XXXXXX")"
cleanup() {
  if [ ! -e "$DEST" ] && [ -e "$STAGE/old" ]; then
    mv "$STAGE/old" "$DEST"
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

NEW="$STAGE/EnvSetter.app"
ditto "$SRC" "$NEW"
if [ ! -x "$NEW/Contents/MacOS/EnvSetterApp" ]; then
  echo "装出来的包缺少可执行文件：$NEW" >&2
  exit 1
fi
plutil -lint "$NEW/Contents/Info.plist" >/dev/null

WAS_INSTALLED=0
if [ -e "$DEST" ]; then
  WAS_INSTALLED=1
  mv "$DEST" "$STAGE/old"
fi
mv "$NEW" "$DEST"
# 让 Finder/Dock 立刻认出新包。
touch "$DEST"

RUNNING=0
if pgrep -x EnvSetterApp >/dev/null 2>&1; then RUNNING=1; fi

if [ "$WAS_INSTALLED" = 1 ]; then
  echo "已覆盖安装：$DEST"
else
  echo "已安装：$DEST"
fi
if [ "$RUNNING" = 1 ]; then
  echo "检测到正在运行的实例：本次没有打断它，也没有打开新的一份——退出并重新打开应用后才会用上新版本。"
elif [ "$OPEN" = 1 ]; then
  open "$DEST"
fi
