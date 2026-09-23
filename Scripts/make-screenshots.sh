#!/bin/bash
# 生成 README 用的界面截图（默认落在 docs/images/）。
#
#   ./Scripts/make-screenshots.sh              # 浅色
#   ./Scripts/make-screenshots.sh --dark       # 深色（本机若是深色模式，截图更像你看到的样子）
#   ENVSETTER_SHOT_DIR=/tmp/x ./Scripts/make-screenshots.sh
#
# 截图是**渲染**出来的，不是截你的屏幕：把真实视图（`EnvSetterUI.MainWindow`）喂一份合成数据后
# 抓窗口自己的合成结果。所以不碰真实 `~/.zprofile`、不需要屏幕录制权限、也不可能把你的变量截进去
# ——这一点是刻意的，别改成对着屏幕截图。
#
# 唯一会动的地方：临时造一个 `~/.envsetter-demo/`（沙盒家目录，让界面里的路径显示成 `~/…`），
# 跑完删掉。
#
# 为什么绕一圈包成 .app 再启动：非 bundle 的进程拿不到系统的强调色（开关会渲染成灰的）、
# 也拿不到窗口的合成结果。`open` 启动的 .app 才是真实 GUI 会话。
set -euo pipefail
cd "$(dirname "$0")/.."

APPEARANCE=light
for arg in "$@"; do
  case "$arg" in
    --dark) APPEARANCE=dark ;;
    *) echo "用法：$0 [--dark]" >&2; exit 2 ;;
  esac
done

OUT_DIR="${ENVSETTER_SHOT_DIR:-docs/images}"
DEMO_HOME="$HOME/.envsetter-demo"
APP=".build/ScreenshotTool.app"

swift build -c release --product ScreenshotTool
BIN="$(swift build -c release --show-bin-path)/ScreenshotTool"

# 临时包成一个 .app：非 bundle 进程渲染不出强调色与材质（见文件头）。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ScreenshotTool"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>EnvSetter 截图</string>
	<key>CFBundleIdentifier</key><string>com.lautung.env-setter.screenshots</string>
	<key>CFBundleExecutable</key><string>ScreenshotTool</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

mkdir -p "$OUT_DIR"
OUT_ABS="$(cd "$OUT_DIR" && pwd)"
LOG="$(mktemp -t envsetter-screenshots)"
cleanup() { rm -rf "$DEMO_HOME" "$LOG"; }
trap cleanup EXIT
rm -rf "$DEMO_HOME"

# -W 等它跑完；--stderr 把工具的日志接回来（图形 app 的 stdout/stderr 默认没人接）。
open -W -n --stderr "$LOG" --env "SHOT_DIR=$OUT_ABS" --env "SHOT_APPEARANCE=$APPEARANCE" "$APP"
cat "$LOG"

# 自检：两张图都在，且不是空图。少了截图是肉眼才看得出的缺陷，所以宁可报错。
# 顺带缩到 1600 宽：README 里最多显示约 1000 点宽，1600 已经够视网膜屏看，体积却少一截。
for name in main-window path-editor; do
  file="$OUT_DIR/$name.png"
  if [ ! -s "$file" ]; then
    echo "没生成出 $file" >&2
    exit 1
  fi
  size=$(stat -f%z "$file")
  if [ "$size" -lt 20000 ]; then
    echo "$file 只有 ${size} 字节，像是空图" >&2
    exit 1
  fi
  sips -Z 1600 "$file" >/dev/null
done

echo "已生成截图（${APPEARANCE}）：$OUT_ABS/{main-window,path-editor}.png"
