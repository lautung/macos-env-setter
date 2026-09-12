# launchctl 持久化机制调研

Type: research
Status: resolved
Blocked by:

## Question

在 macOS 26.x（本机 darwin 25.6.0，arm64）上，如何让从 Dock/Finder 启动的 GUI 应用读到自定义环境变量，且重启后仍然生效？需要查清：

1. `launchctl setenv` 的作用域与生命周期——设置的变量是否重启即失效？
2. 持久化的标准做法：LaunchAgent 方案的具体实现（plist 放哪、RunAtLoad 怎么写、setenv 脚本怎么写、如何 load/bootstrap 注册）；社区通用方案（如 Harald Koch 的 setenv LaunchAgent）现状与做法。
3. SIP 及 macOS 近年版本（ Ventura → Tahoe 26）对这些机制的限制是否变化；`launchctl config user path` 的已知限制（PATH-only、需要 sudo）。
4. 变量修改后，已运行的 GUI 应用如何读到新值（必须重启应用？还是有即时生效的途径）；Dock/Finder 是否需要重启。
5. 非沙盒 SwiftUI 应用执行 `launchctl setenv` 是否有权限问题（本应用不做沙盒）。

产出：结论 + 推荐给本工具采用的持久化方案要点，写入 `.scratch/macos-env-setter/research/launchctl-persistence.md`，并在本票文件末尾追加 `## Answer` 摘要后把 Status 改为 resolved。

## Answer

详见 [research/launchctl-persistence.md](../research/launchctl-persistence.md)（本机 macOS 26.6.2 实测 + 一手来源，2026-09-12）。

1. `launchctl setenv` 作用于调用者所在 gui 域中**之后**由 launchd 启动的所有进程（man page 原文"all future processes launched by launchd in the caller's context"）；变量存 launchd 内存，**注销/重启即失**，属易失机制，持久化靠每次登录重放。
2. 标准持久化 = 单个 **RunAtLoad LaunchAgent**：plist 放 `~/Library/LaunchAgents/<reverse-dns>.plist`，`ProgramArguments` 调工具生成的 `setenv.sh`（逐行 `launchctl setenv K 'V'`）；注册用 `launchctl bootstrap gui/$(id -u) <plist>`（重复注册先 `bootout`），遗留 `launchctl load` 仍可用；变量变化只需重写脚本、无需重注册。Harald Koch 原文已下线，模式由 SO 25385934 / Dowd & Associates / Naiyer Asif(2024) 等完整承载。
3. SIP 不碍事（`~/Library/LaunchAgents` 是用户可写目录）；真正的新限制是 Ventura 起的**登录项/后台项（BTM）**——agent 会进"登录项与扩展 → 后台允许"，用户可关，关掉即登录不重放，工具需可诊断。`sudo launchctl config user path`：PATH-only + 需 sudo + 需重启（man page），且 Sequoia 普遍 SIGBUS、26.4.1 报告不工作（nix-darwin #1080）——**弃用，PATH 也走 setenv**。
4. 已运行 App **必须退出重开**（exec 时环境固定，无进程内刷新途径）；新点开的 App 经 Dock/Finder/Spotlight 由 launchd 直接 spawn（本机验证 ppid=1），立即拿新值，**无需重启 Dock/Finder**；"重新打开窗口"恢复的 App 可能抢在 agent 前启动（launchd 无服务排序）。工具可提供一键"重启指定 App"。
5. 非沙盒 App 执行 setenv / 写 `~/Library/LaunchAgents` **无任何权限问题**（无 sudo、无 entitlement、无 TCC；对比 config user path 还会触发 TCC）；自建 App 写出的文件无 quarantine。ssh 会话拿不到 gui 域变量 → shell（zprofile）层保留正是兜底。
