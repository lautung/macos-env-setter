# launchctl 持久化机制调研

- 日期：2026-09-12
- 票：`issues/01-research-launchctl-persistence.md`
- 方法：本机只读验证（man page、`launchctl print`、目录/进程检查）+ 一手来源（Apple man page、Apple Developer Relations 回复、社区权威帖与近两年实践文）。本机为 macOS 26.6.2（Build 25G83，darwin 25.6.0，arm64，uid 501）。
- 关联：先例工具的部分细节见 `research/prior-art.md`（EnvPane/macenv 等），本文不重复。

---

## 结论（推荐方案要点）

1. **运行时层：App 进程内直接 `Process` 执行 `/bin/launchctl setenv KEY VALUE` / `unsetenv KEY`**。无 sudo、无 entitlement、无 TCC 弹窗、不受 SIP 影响（SIP 只保护系统路径，不管 launchd 命令）。只影响**之后新启动**的进程；已运行 App 必须退出重开。
2. **持久化层：一个 RunAtLoad LaunchAgent**，plist 放 `~/Library/LaunchAgents/<reverse-DNS>.plist`（如 `com.example.envsetter.plist`），`ProgramArguments` 调用工具自己生成的 setenv 脚本（建议放 `~/Library/Application Support/<App>/setenv.sh`，内容为逐行 `launchctl setenv KEY 'value'`）。变量变化时只需重写脚本文件，**不必重注册 agent**。注册用现代语法 `launchctl bootstrap gui/$(id -u) <plist>`（已注册时先 `bootout gui/UID/label`）；遗留 `launchctl load` 仍可用。社区所有方案（SO 25385934 高票、Dowd & Associates、Naiyer Asif 2024、EnvPane、macenv）都是这一模式。
3. **PATH 同样走 `launchctl setenv PATH`**，不要用 `sudo launchctl config user path`：它是 PATH-only + 需 sudo + 需重启，且在 Sequoia 上普遍 SIGBUS（nix-darwin #1080，2024-09 起）、macOS 26.4.1（2026-07）报告"不工作"。
4. **生效语义在 UI 里说清楚**：新值只对随后由 launchd 启动的进程生效；Dock/Finder/Spotlight 启动的新 App 立即拿到（本机验证 Finder/Dock 的父进程就是 launchd，ppid=1），**无需重启 Dock/Finder**（`killall Dock` 只在个别老方案里出现，非必需）；登录时"重新打开窗口"恢复的 App 可能抢在 agent 之前启动而拿不到变量（无服务排序保证）。
5. **要处理的新版限制不是 SIP 而是 BTM**：Ventura 起，写入 `~/Library/LaunchAgents` 的 plist 会出现在 系统设置 → 通用 → 登录项与扩展 → 后台允许列表中，用户可将其关闭（关闭后登录时 agent 不执行）。工具应能检测（`launchctl getenv` 返回空）并引导用户重新启用。
6. 两个已知边界：**ssh 会话**不拿 gui 域变量（需 shell rc 层兜底——本项目本来就有 zprofile 层）；从 Terminal 启动的 App 继承 shell 环境，shell 里 export 的值会**覆盖** launchd 值。

---

## Q1 `launchctl setenv` 的作用域与生命周期

- **man page 官方措辞**（本机 macOS 26.6.2 `man launchctl` 原文）：
  > setenv key value — Specify an environment variable to be set on all future processes launched by launchd in the caller's context.

  即：作用于调用者所在 launchd 域中**之后**被启动的所有进程。在 Aqua 会话的 Terminal 里执行时，"caller's context" = 用户 GUI 会话域 `gui/501`——Dock、Finder、Spotlight、`open` 启动的 App 全部由该域的 launchd 直接 spawn（本机验证：`Finder` 与 `Dock` 进程 ppid=1，父进程为 `/sbin/launchd`），因此都能拿到。
- **读取方式**：`launchctl getenv KEY`；`launchctl print gui/$UID` 的 `environment = { ... }` 字典也会列出当前 gui 域的全部注入变量（本机验证：当前机器只含 `SSH_AUTH_SOCK`，即 setenv 过的变量会出现在这里）。
- **生命周期：易失**。变量保存在 launchd 内存里，注销/重启即丢；man page 与社区均确认"not preserved across login sessions"，所以持久化必须在**每次登录时重放**（见 Q2）。这不是 bug，是设计——Apple 没有提供持久化的用户级通用 setenv 子命令（`config` 被刻意限定为 PATH-only，见 Q3）。
- **边界**：ssh 登录得到的是独立会话域，拿不到 gui 域的 setenv 变量（SO 25385934 高票答案的 Edit 注明"if you log in via ssh, the variables will not be set"）——这正是本项目保留 `~/.zprofile` shell 层的理由之一。

## Q2 持久化标准做法：LaunchAgent

**plist 位置**：`~/Library/LaunchAgents/`（用户级，免 sudo；`/Library/LaunchAgents` 为管理员级、`/Library/LaunchDaemons` 为系统级且需 sudo）。登录时 launchd 自动扫描该目录，`RunAtLoad=true` 即自动执行——放到位后无需任何手工注册也会在下次登录生效。

**社区通用写法**（三种等价形态，按推荐顺序）：

1. **脚本文件 + 单 agent**（最适合本工具：变量列表变化时只改脚本）：
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
     "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key><string>com.example.envsetter</string>
     <key>ProgramArguments</key>
     <array>
       <string>/bin/sh</string>
       <string>/Users/USER/Library/Application Support/EnvSetter/setenv.sh</string>
     </array>
     <key>RunAtLoad</key><true/>
   </dict>
   </plist>
   ```
   脚本内容即 `#!/bin/sh` + 逐行 `launchctl setenv KEY 'value'`（值含空格没问题，加引号即可——Dowd & Associates 特别指出这比已死的 `/etc/launchd.conf` 强）。
2. **ProgramArguments 内联多组 setenv**（Ask Different 289060 采纳答案）：同一 `<array>` 里重复 `[/bin/launchctl, setenv, K1, V1, /bin/launchctl, setenv, K2, V2, ...]`。缺点：改一个变量就要 bootout/bootstrap 重注册。
3. **WatchPaths 变体**（SO 25385934 第三高票的 `/etc/environment` 方案）：agent 上加 `<key>WatchPaths</key><array><string>/etc/environment</string></array>`，文件一变就重放 setenv，"改完只需重启目标 App"。代价是引入常驻代理。

**注册/注销**（现代语法，man page；Alan Siu 2023 有速查）：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.envsetter.plist  # 注册并按 RunAtLoad 立即执行
launchctl bootout gui/$(id -u)/com.example.envsetter                                  # 注销（卸载/更新前）
launchctl kickstart -k gui/$(id -u)/com.example.envsetter                             # 手动重跑
launchctl enable gui/$(id -u)/com.example.envsetter                                   # 若被 disable 时
```
遗留 `launchctl load/unload -w <plist>` 仍可用（社区所有教程都用它），man page 已归为 legacy；bootstrap 对已加载项会报 `Bootstrap failed: 5: Input/output error` 一类错误，流程上先 bootout 再 bootstrap 即可。

**运行时更新不需要碰 agent**：保存变量时直接再跑一次 `/bin/launchctl setenv`（立刻生效）+ 重写脚本文件（下次登录生效）即可；仅当 plist 的 `ProgramArguments` 本身（内联形态）变化时才需要 bootout/bootstrap。

**Harald Koch 方案现状**：其 2014 年前后的原始博客已从搜索索引中消失（WebSearch/DuckDuckGo/Wayback CDX 均无存档记录，2026-09 验证），但该模式早已是社区公共财产：Dowd & Associates 的系列教程（launchd.plist 篇）、SO 25385934 高票答案、Ask Different 289060/454430、以及 2024-12 的 Naiyer Asif 文章、Tom Fleet 文章内容完全一致——即上面第 1/2 种写法。EnvPane 用的是同一机制的 ObjC 直调版本（与 setenv 相同的私有 API），且是 plist+WatchPath 常驻 agent（见 `research/prior-art.md`）。

**登录时序坑（各来源一致）**：launchd 不保证服务启动顺序，"重新打开窗口"恢复的 App 可能先于 agent 启动而拿不到变量；受影响的 App 重开一次即可，或提示用户关闭窗口恢复（SO 高票答案 Edit 与第三票均明确此问题；EnvPane issue #22 同款，见 prior-art）。

## Q3 SIP 与 Ventura → Tahoe 26 的限制变化

**时间线（机制存亡）**：

| macOS | 变化 |
|---|---|
| 10.8 | `~/.MacOSX/environment.plist` 停止被读取（Dowd & Associates 系列） |
| 10.10 Yosemite | `/etc/launchd.conf` 被删除；Apple Developer Relations 2014-10-10 官方回复："The file /etc/launchd.conf was intentionally removed for security reasons"（SO 25385934 引用） |
| 13 Ventura | 登录项/后台项管理重做：`~/Library/LaunchAgents` 的 plist 进入"系统设置 → 登录项与扩展 → 后台允许"（Background Task Management），用户可关；新条目有系统通知；状态更新"overnight maintenance 后才反映"（Eclectic Light/Oakley 2023） |
| 15 Sequoia | `sudo launchctl config user path` 多数机器 SIGBUS 崩溃（nix-darwin #1080：2024-09 "terminated by signal SIGBUS"；Fork #1227 报 Sequoia 无效）；个别 15.3.1 用户可用但需允许终端"管理你的电脑"（TCC） |
| 26.x Tahoe | nix-darwin #1080 2026-07-17 评论："On macOS 26.4.1 `sudo launchctl config user path` does not work" |

**`launchctl setenv` 本身没有被移除的迹象**：2024-2026 的实践文（Naiyer Asif 2024-12、macsysadmin Reddit 2024 帖、riaf gist）以及本机 26.6.2 的 man page（措辞与十年前一致）都表明机制健在。本工具应在 App 内做运行时自检（setenv 后 `launchctl getenv` 回读）以兜底未来变化。

**SIP 的边界**：Apple 平台安全文档只说 SIP 把"特定关键文件系统位置"变为只读、且"无论进程是否沙盒或有管理员权限都适用"；用户目录不在其列——`~/Library/LaunchAgents` 是 user-writable 的常规目录（本机验证：该目录已存在并含 EdgeUpdater、Lemon 等第三方 plist，权限 `drwxr-xr-x@`，属主为用户），写入/创建无障碍。`launchctl setenv`/`bootstrap gui/UID` 同样不是 SIP 管辖的操作。

**`launchctl config user path` 的官方限制**（本机 man page 原文）：
> path — Sets the PATH environment variable for all services within the target domain... NOTE: This facility cannot be used to set general environment variables for all services within the domain. It is intentionally scoped to the PATH environment variable and nothing else for security reasons.
> A reboot is required for changes made through this subcommand to take effect.

实现细节（SO 51636338 采纳答案，macOS 14 验证）：写 `/private/var/db/com.apple.xpc.launchd/config/user.plist` 的 `PathEnvironmentVariable` 键，user 与 system 两个域"都奇怪地需要 sudo"，撤销用 `sudo defaults delete`，查询用 `launchctl getenv PATH`（本机当前为空串）与 `sysctl -n user.cs_path`。加上 Sequoia/Tahoe 的 SIGBUS 报告与潜在 TCC 弹窗，**对本工具是死路，弃用**；GUI 层 PATH 直接 `launchctl setenv PATH`（riaf gist 证明现代 macOS 可行）。

## Q4 已运行的 GUI 应用如何读到新值

- **没有进程内刷新途径**。POSIX 环境块在 exec 时拷贝固定，进程无法事后被外界改写。所有来源一致：**已运行 App 必须退出并重新启动**（SO 25385934 高票"you will need to restart applications for this to take effect"；riaf gist、shakecode、Naiyer Asif 同）。
- **新启动的 App 不需要重启 Dock/Finder**：Dock/Finder/Spotlight 点开 → LaunchServices 请求 launchd spawn → 进程环境取自 gui 域当前值（本机验证父进程为 launchd）。`launchctl setenv` 后再点开的 App 立即生效。`osascript 'tell app "Dock" to quit'` 只出现在 SO 第三票的 `/etc/environment`+WatchPaths 老方案里（Dock 自动重生以刷新其自身环境），setenv 流程非必需。
- **工具可以提供的便利**：对目标 App 执行"退出 + 重开"（AppleScript `tell application "X" to quit` 再 `open -a X`），把"需要重启应用"变成一键操作；UI 上列出"改动后尚未重启的常用 App"。
- **两个例外语义**：(a) 从 Terminal 启动的进程继承 shell 环境，shell 中 export 的值优先于 launchd 值（SO 高票 Edit）；(b) Xcode 历史上主动清洗注入环境（`defaults write com.apple.dt.Xcode UseSanitizedBuildSystemEnvironment -bool NO`，SO 高票 Edit，El Capitan 时代行为，现状需实测）。

## Q5 非沙盒 SwiftUI 应用执行 `launchctl setenv` / 写 LaunchAgents 的权限

- **`launchctl setenv`：零权限要求**。App 以当前用户身份在 Aqua 会话内 spawn `/bin/launchctl` 即可；无 sudo、无 entitlement、无 TCC。对比 `sudo launchctl config user path`：写 `/var/db/...` 需 root，Sequoia 上还会触发"…想管理你的电脑"（TCC）授权（nix-darwin #1080 中 pitkling 的描述）——setenv 路线完全绕开这些。
- **写 `~/Library/LaunchAgents`**：用户自有目录，非 SIP 保护、无 TCC 保护（本机已见多个第三方 App 的 plist 常驻其中）。本机构建的 App 写出的文件不带 `com.apple.quarantine` 属性，不会被 Gatekeeper 拦；签名与否不影响。
- **沙盒对比**：若开启 App Sandbox，向会话域注入变量与在容器外写文件都不可行——本项目"非沙盒"前提是该方案成立的必要条件（Apple SIP 文档亦指出其保护与进程是否沙盒无关，但沙盒本身会限制上述写操作）。
- **剩余风险都在"用户可见性"而非"权限"**：
  1. Ventura+ 的 BTM：新 plist 可能弹"xxx 添加了可在后台运行的项目"通知，并出现在"后台允许"列表；用户关掉后 agent 登录时不执行 → 变量在重启后消失。工具应提供"诊断"（比较持久层脚本与 `launchctl getenv` 实际值）并给出重新启用指引（plist 的 Label 尽量可读）。
  2. `bootstrap` 幂等性：重复注册会失败，先 `bootout` 再 `bootstrap`。
  3. 无签名自用 App 首次打开的 Gatekeeper 提示（右键打开 / `xattr -dr com.apple.quarantine`，见 prior-art 第 7 条）。

---

## 来源列表

**Apple / man page（一手）**
- `man launchctl`（本机 macOS 26.6.2 实测引用：setenv "all future processes launched by launchd in the caller's context"；config "intentionally scoped to the PATH… for security reasons"、"A reboot is required"）
- Apple Platform Security — System Integrity Protection：<https://support.apple.com/guide/security/system-integrity-protection-secb7ea06b49/web>（SIP 通用描述；未列目录，故以本机目录权限佐证）

**Apple Developer Relations 官方回复（/etc/launchd.conf 之死）**
- 经 SO 25385934 转引：<https://stackoverflow.com/questions/25385934/setting-environment-variables-via-launchd-conf-no-longer-works-in-os-x-yosemite>（含三条高票答案：sh -c agent、AppleScript 登录项、/etc/environment+WatchPaths；"reopen windows"竞态与 ssh 边界）

**社区标准方案（LaunchAgent + setenv）**
- Dowd & Associates 系列（票中引用 URL 的活体页面）：<https://www.dowdandassociates.com/blog/content/howto-set-an-environment-variable-in-mac-os-x-launchd-plist/> 与索引页 `…in-mac-os-x/`（各机制存亡表）
- Ask Different 289060（单 plist 多 setenv 对 + load/unload 重载）：<https://apple.stackexchange.com/questions/289060/setting-variables-in-environment-plist>
- Ask Different 454430（GUI 会话变量，Ventura 时代确认）：<https://apple.stackexchange.com/questions/454430/set-environment-variable-for-the-whole-gui-session-aka-without-using-zshenv>
- Naiyer Asif（2024-12，Sequoia 时代完整教程）：<https://naiyerasif.com/post/2024/12/29/setting-up-environment-variables-on-macos/>
- Tom Fleet：<https://www.followtheprocess.codes/posts/macos-env-vars/>
- shakecode：<https://www.shakecode.com/blog/other/setting-environment-variables-on-mac>
- riaf gist（shell PATH 同步到 GUI，含"需重启 App"说明）：<https://gist.github.com/riaf/cf662d965ebd1b8b47453dd79cdd5578>
- Reddit r/MacOS "Add system-wide environment-variables in MacOS Ventura"（Ask Different 454430 作者详述帖）：<https://www.reddit.com/r/MacOS/comments/12ryky5/>

**`launchctl config user path` 限制与 Sequoia/Tahoe 故障**
- SO 51636338（写入路径 `/private/var/db/com.apple.xpc.launchd/config/user.plist`、双方均需 sudo、撤销命令）：<https://stackoverflow.com/questions/51636338/what-does-launchctl-config-user-path-do>
- nix-darwin #1080（Sequoia SIGBUS 2024-09 起；macOS 26.4.1 不工作 2026-07-17；TCC"管理你的电脑"提示）：<https://github.com/nix-darwin/nix-darwin/issues/1080>
- Fork #1227（Sequoia 上 config user path 无效的实际影响案例）：<https://github.com/fork-dev/Tracker/issues/1227>

**Ventura+ 登录项/后台项（BTM）机制**
- Eclectic Light Company, "How to diagnose and control login and background items"（2023-07-04）：<https://eclecticlight.co/2023/07/04/how-to-diagnose-and-control-login-and-background-items/>

**Harald Koch 原文**
- 已不可达（多引擎 + Wayback CDX 无记录，2026-09-12 验证）；其方案由上述 Dowd & Associates / SO 25385934 等承载，技术内容一致。

**本机只读验证**（2026-09-12，macOS 26.6.2 / darwin 25.6.0 arm64）
- `man launchctl`（setenv/config 原文见上文）；`launchctl print gui/501`（gui 域 environment 仅含 `SSH_AUTH_SOCK`）；`launchctl getenv PATH`（空串）；`/etc/launchd.conf` 不存在；`~/Library/LaunchAgents` 存在且含第三方 plist（属主用户、可写）；`/System/Library/LaunchAgents` 465 项；`Finder`/`Dock` 进程 ppid=1（父进程 `/sbin/launchd`）。
