# 双层写入：标记块 + RunAtLoad LaunchAgent

macOS 上环境变量有两个互不相通的层（shell 配置文件、launchd 的 gui 域），本工具对两层各自采用如下写入机制，并由「作用层」开关决定每条变量写到哪层：

- **shell 层**：工具只在 `~/.zprofile` 的自有标记块内整块替换写入（原子写、写入前时间戳备份），块外内容永不触碰。选标记块而非独立文件 + source 行，是为了卸载无残留、且不与用户手写内容争抢同一文件的控制权。
- **GUI 层**：生成单个 RunAtLoad LaunchAgent（`~/Library/LaunchAgents/<reverse-dns>.plist` + 工具生成的 `setenv.sh`），登录时按声明顺序重放 `launchctl setenv`。值中的 `$` 引用由该脚本按声明顺序展开；`$PATH` 锚点在此层解析为 launchd 默认 PATH——agent 进程的 PATH 由 plist 钉住这个值（见下方「期望值的环境」），所以重跑脚本也算得出同一个结果。

**Considered Options**：
- `sudo launchctl config user path`——PATH-only、需 sudo + 重启，且 Sequoia/Tahoe 上有普遍失效报告（nix-darwin #1080），弃用。
- `~/.MacOSX/environment.plist`（10.8 移除）、`/etc/launchd.conf`（Yosemite 移除）——已被系统移除。
- pref pane 形态（EnvPane 路线）——Ventura 起系统偏好面板普遍空白，弃用。
- 逐变量 grep/sed 改写配置文件（menv 路线）——脆弱且易破坏用户手写内容，弃用。

**Consequences**：已运行的 GUI 应用必须退出重开才能读到新值（进程环境在 exec 时固定）；LaunchAgent 会被 macOS 的「登录项与扩展」后台项管理，用户可在系统设置里关掉它——工具需要提供诊断入口而不是静默失败。详见 wayfinder 票 #1、#2 的调研。

**GUI 层的生效与自检**（实现期补充，票 #7）：显式应用时除重写 `setenv.sh` 外，还立即对当前会话跑一次该脚本（不必等下次登录），并把 `launchctl getenv` 的逐个回读与脚本 `--print` 算出的期望值比对——不一致即告警并指向诊断，而不是静默通过。关闭或移除一条变量时，工具只清除「自己上次写进脚本、且自己拥有过（上次应用时在记录里，或现在仍在记录里）」的 key——包括本次被移除的那条；launchd 没有标记块那样的隔离区，所以用「只清理自己拥有过的」来划边界，gui 域里别人设的变量一律不碰。

**期望值的环境**（实现期补充，票 #9）：脚本的 `$PATH` 锚点必须只取决于配置，不取决于跑脚本的进程恰好继承到什么——否则「应用时的即时注入」与「agent 重放」会算出不同的值，而重放（重新注册触发 `RunAtLoad`）在域里已有本工具注入的 PATH 时会把目录再前插一遍。两侧因此都钉住 PATH 为 launchd 默认值：agent 那侧由 plist 的 `EnvironmentVariables`（`LaunchAgent.plistData`），工具那侧由固定的 launchd-like 环境（`GuiLayer.launchdLikeEnvironment`）。两侧一致，回读自检的期望值才与两个写入者都相符。**升级路径**：钉之前装下的 plist 没有这一项，`plistMatches` 按内容判定会认出它，下次应用重写并重新注册。

**GUI 层的整体撤回**（实现期补充，票 #14）：没有启用 GUI 层的变量时，显式应用不是「什么都不装」，而是把上次装下的东西撤干净——bootout、删 plist、删脚本，并清掉本工具写过的 key。不变式是**没有 GUI 层变量 ⇒ 没有脚本、没有 plist、没有注册**，登录项不会永久留在系统设置里；本来就没装过（且没有待清理残留）时只做一次只读的注册查询，不改动任何东西。

**清残留的依据**（实现期补充，审查后修正）：判据有两处——**待清理残留**（本地状态里的 `pendingGuiRemovals`，在覆盖脚本**之前**落盘，清除成功后移除）与**脚本里记的 key**（历史线索，兼作人工排查的现场）。脚本不能是唯一依据：其他 GUI 变量还在时脚本会被重写成不含该 key，只认脚本就会让 `unsetenv` 失败的 key 永久遗留在 gui 域里。所以 `unsetenv` 没做成时脚本会保留下来（报告成部分完成），待清理残留记着没清成的 key——下次显式应用、诊断面板的「重试 GUI 同步」、CLI 的 `gui --sync` 都会继续清除，诊断也据此报残留。
