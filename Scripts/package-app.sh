#!/bin/bash
# 打发布包：release 构建 → dist/EnvSetter-<版本>.zip（内含 EnvSetter.app）。
#
# 包是本地构建、**不签名**——用户下载后第一次要「右键 → 打开」绕过 Gatekeeper，
# 安装说明写在 README 的「安装」一节，发布说明里也要重复一遍。
#
#   ./Scripts/package-app.sh          # 产物落在 dist/
#   ./Scripts/package-app.sh --debug  # debug 构建（只在排查打包问题时用）
set -euo pipefail
cd "$(dirname "$0")/.."

DEBUG=""
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=--debug ;;
    *) echo "用法：$0 [--debug]" >&2; exit 2 ;;
  esac
done

VERSION="$(plutil -extract CFBundleShortVersionString raw Scripts/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw Scripts/Info.plist)"
APP=".build/EnvSetter.app"
ZIP="dist/EnvSetter-$VERSION.zip"

# 包怎么组装只由 build-app.sh 决定——打包与验收共用同一条构建路径。
./Scripts/build-app.sh --no-open $DEBUG

rm -rf dist
mkdir -p dist
# 用 ditto 而不是 zip：保留 .app 的目录结构与扩展属性，解开后 Finder 直接认它是应用。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "已打包：$(pwd)/${ZIP}（版本 ${VERSION}，build ${BUILD}）"
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
  # 附注 tag 的 `rev-parse v1.0.0` 给的是 tag 对象，`^{commit}` 才是它指向的提交。
  echo "对应 tag：v${VERSION}（提交 $(git rev-parse --short "v${VERSION}^{commit}")）"
else
  echo "⚠️  还没有 v${VERSION} 这个 tag：发布前打上，用户才知道这个包对应哪个提交。"
fi
