# EnvSetter

一个 SwiftUI 原生 macOS 窗口应用：在一个全局列表里管理环境变量，写入两个互不相通的层。

- **shell 层** — `~/.zprofile` 里由标记注释围起的标记块，对终端生效。块外内容工具永不触碰。
- **GUI 层** — 工具生成的 `setenv.sh` + 一个 `RunAtLoad` 的 LaunchAgent，登录时把变量注入 launchd 的 gui 域，对 Dock / Finder / Spotlight 启动的 App 生效。

macOS 上这两层互不相通——在终端里 `export` 的变量，Dock 启动的 App 看不到，反之亦然。EnvSetter 用一份列表同时管两层，每条变量各自开关要写到哪一层。

PATH 有专用排序编辑器（拖拽 + ↑↓、`$PATH` 锚点、重复条目警告）；编辑只改内存，点「应用」才一次性落盘（先自动备份）；「秘密值」在列表与预览里打码。

## 安装

1. 到 [Releases](https://github.com/lautung/macos-env-setter/releases) 下载 `EnvSetter-1.0.0.zip`。
2. 双击解开，把 `EnvSetter.app` 拖进「应用程序」。
3. **右键（或 Control + 点击）→ 打开**，在弹出的框里再点「打开」。

第 3 步只做一次：这个 app 没有 Apple 签名（签名要开发者账号），系统第一次会拦一下，按上面的方式放行之后就能正常双击了。

**打不开怎么办：** 如果系统说「已损坏，无法打开」或右键打开也无效，多半是下载时带上了隔离标记，终端里跑一句：

```bash
xattr -d com.apple.quarantine /Applications/EnvSetter.app
```

## 第一次使用

打开后是一个左右分栏的窗口：左边是变量列表，右边是选中那条的详情。

1. 想让工具接管你已经在 `~/.zprofile` 里手写的 `export` 行，点侧栏的**「收编已有配置」**。它会把那些行接管成列表里的记录，**原行注释掉**（留着手工回退路径，随时可以改回去）。
2. 也可以直接**新建变量**：填 key 和值，勾选写到哪一层。值里的 `$` 引用照常展开（例如 `$JAVA_HOME/bin`），单引号则保持字面。
3. 改完点右上角的**「应用 (N)」**一次性落盘——在那之前所有编辑都只在内存里，不会碰你的文件。应用前会自动备份 `~/.zprofile`。
4. GUI 层的改动**只影响之后新启动的 App**。已经在跑的 App 要退出重开才读到新值；侧栏的「重启指定 App」可以帮你做这件事。
5. 出问题时点侧栏的**「诊断」**：脚本、LaunchAgent、注册状态、登录项开关、域里的注入值、残留，逐项给结论。

## 它会动你机器上的什么

这个工具会写文件、也会注册一个登录项。全部清单如下，心里有数再用：

| 路径 | 什么时候有 |
|---|---|
| `~/.zprofile` 的标记块（`# >>> EnvSetter >>>` 到 `# <<< EnvSetter <<<`） | 有开启 shell 层的变量时。**块外内容永不触碰** |
| `~/Library/LaunchAgents/com.lautung.env-setter.plist` | 有开启 GUI 层的变量时（登录项本体） |
| `~/Library/Application Support/EnvSetter/setenv.sh` | 同上（登录时重放变量的脚本，权限 0600） |
| `~/Library/Application Support/EnvSetter/store.json` | 始终（工具自己的本地状态：列表、开关、快照） |
| `~/.env-setter/backups/` | 每次应用前的时间戳备份 + 一份永不轮转的基线备份 |

另外，**系统设置 → 通用 → 登录项与扩展**里会多一条后台项。它显示成 `sh` 而不是 EnvSetter（系统拿程序名当显示名，见「已知问题」）——**别关掉它**，关掉后 GUI 层的变量在下次登录时就不会生效了；工具的诊断能看出这件事并提示你。

## 卸载

1. 打开应用，把所有变量的 **GUI 层开关关掉**，点「应用」。这一步会把脚本、plist 和登录项整体撤掉（没有 GUI 层变量就没有任何残留）。
2. 退出应用，把 `EnvSetter.app` 拖到废纸篓。
3. shell 层想一起清干净：手工删掉 `~/.zprofile` 里 `# >>> EnvSetter >>>` 到 `# <<< EnvSetter <<<` 那一段（工具从不碰块外内容，所以删掉块就够了），或者用应用里「备份与恢复」回到收编之前。
4. 最后删掉本地状态与备份：`rm -rf ~/Library/Application\ Support/EnvSetter ~/.env-setter`

## 系统要求

macOS 13 或更新。**实际只在 macOS 26 上验证过**——更早的系统没测过，遇到问题欢迎开 issue。

## 已知问题

- **登录项显示成 `sh`**：`LaunchAgent` 的 `ProgramArguments` 是 `/bin/sh <setenv.sh>`（脚本必须 0600、不能自己执行），系统拿程序名当显示名。功能不受影响，但看着可疑。要改得动 agent 的形态，还没做。
- **没有签名、没有公证**：第一次打开要右键 → 打开（见「安装」）。
- **升级路径有一处手工步骤**：如果将来某个版本改动了 plist 或 `setenv.sh` 的形状，而你没有待应用的改动（「应用」按钮是灰的），生成物不会自己重写——先随便改一处再应用，或者删掉上面那两个文件再点应用。工具会用诊断告诉你它是不是最新的。

## 从源码构建（开发用）

```bash
./Scripts/build-app.sh              # release 构建 → .build/EnvSetter.app → 打开（验收与快速迭代用）
./Scripts/build-app.sh --no-open    # 只构建
./Scripts/install-app.sh            # 构建后装到 ~/Applications/EnvSetter.app（日常从 Dock / Spotlight 打开）
./Scripts/install-app.sh --no-open  # 装完不打开
./Scripts/package-app.sh            # 打发布包 → dist/EnvSetter-<版本>.zip
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

领域语言见 [`CONTEXT.md`](CONTEXT.md)，双层写入机制见 [`docs/adr/0001-dual-layer-env-write.md`](docs/adr/0001-dual-layer-env-write.md)。

## 许可证

[MIT](LICENSE)
