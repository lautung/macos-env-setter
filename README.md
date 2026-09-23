# EnvSetter

一个 SwiftUI 原生 macOS 窗口应用：在一个全局列表里管理环境变量，写入两个互不相通的层。

- **shell 层** — `~/.zprofile` 里由标记注释围起的标记块，对终端生效。块外内容工具永不触碰。
- **GUI 层** — 工具生成的 `setenv.sh` + 一个 `RunAtLoad` 的 LaunchAgent，登录时把变量注入 launchd 的 gui 域，对 Dock / Finder / Spotlight 启动的 App 生效。

PATH 有专用排序编辑器（拖拽 + ↑↓、`$PATH` 锚点、重复条目警告）；编辑只改内存，点「应用」才一次性落盘（先自动备份）；「秘密值」在列表与预览里打码。

领域语言见 [`CONTEXT.md`](CONTEXT.md)，双层写入机制见 [`docs/adr/0001-dual-layer-env-write.md`](docs/adr/0001-dual-layer-env-write.md)，开发进度见 issue tracker 上的 wayfinder 地图。

## 构建 → 安装 → 日常使用

```bash
./Scripts/build-app.sh              # release 构建 → .build/EnvSetter.app → 打开（验收与快速迭代用）
./Scripts/build-app.sh --no-open    # 只构建
./Scripts/install-app.sh            # 构建后装到 ~/Applications/EnvSetter.app（日常从 Dock / Spotlight 打开）
./Scripts/install-app.sh --no-open  # 装完不打开
```

`.build/` 是被 gitignore 的构建目录，一次清理或重建就会让 Dock 上那份「消失」——所以日常用的那份装在 `~/Applications/EnvSetter.app`：它不依赖 `.build/`，重复运行 `install-app.sh` 就是覆盖安装（整包重建，不打断正在运行的实例，退出并重新打开应用后才会用上新版本）。`.build/EnvSetter.app` 照旧留着给验收用，安装不改变它。

日用时的两条作用层边界：

- **只影响之后新启动的 App** — GUI 层把变量注入 launchd 的 gui 域，已经在跑的 App 保持旧值，要退出重开才读到新值。
- **GUI 层由登录项在登录时重放** — `RunAtLoad` 的 LaunchAgent 每次登录重跑一遍 `setenv.sh`，所以变量不只在本次会话有效；它在系统设置的登录项里——有变量启用 GUI 层时，被系统关掉会被应用内诊断报出来。

应用本地构建、不签名、不沙盒（要写 `~/.zprofile` 与 `~/Library/LaunchAgents`）。

## CLI

`envsetter` 是同一套引擎的命令行入口，用于验收与诊断：

```bash
swift run envsetter status           # 漂移、记录、备份
swift run envsetter adopt            # 预览收编计划（不落盘）
swift run envsetter adopt --apply    # 执行收编并应用
swift run envsetter restore [文件名] # 列出 / 恢复备份
swift run envsetter gui              # 诊断 GUI 层（脚本 / LaunchAgent 文件 / 注册 / 后台项 / 注入值 / 残留）
swift run envsetter gui --sync       # 只重跑 GUI 层：重写 setenv.sh、注册 agent、注入当前会话、清掉待清理残留
```

## 测试

```bash
swift test                                            # 全部单测（沙盒家目录，不碰真实配置）
ENVSETTER_LIVE_LAUNCHD=1 swift test --filter LaunchdLiveTests   # 真机 launchd 验收（会临时注册并清理）
```
