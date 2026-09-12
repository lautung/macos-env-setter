# 双层写入：标记块 + RunAtLoad LaunchAgent

macOS 上环境变量有两个互不相通的层（shell 配置文件、launchd 的 gui 域），本工具对两层各自采用如下写入机制，并由「作用层」开关决定每条变量写到哪层：

- **shell 层**：工具只在 `~/.zprofile` 的自有标记块内整块替换写入（原子写、写入前时间戳备份），块外内容永不触碰。选标记块而非独立文件 + source 行，是为了卸载无残留、且不与用户手写内容争抢同一文件的控制权。
- **GUI 层**：生成单个 RunAtLoad LaunchAgent（`~/Library/LaunchAgents/<reverse-dns>.plist` + 工具生成的 `setenv.sh`），登录时按声明顺序重放 `launchctl setenv`。值中的 `$` 引用由该脚本按声明顺序展开；`$PATH` 锚点在此层解析为 launchd 默认 PATH。

**Considered Options**：
- `sudo launchctl config user path`——PATH-only、需 sudo + 重启，且 Sequoia/Tahoe 上有普遍失效报告（nix-darwin #1080），弃用。
- `~/.MacOSX/environment.plist`（10.8 移除）、`/etc/launchd.conf`（Yosemite 移除）——已被系统移除。
- pref pane 形态（EnvPane 路线）——Ventura 起系统偏好面板普遍空白，弃用。
- 逐变量 grep/sed 改写配置文件（menv 路线）——脆弱且易破坏用户手写内容，弃用。

**Consequences**：已运行的 GUI 应用必须退出重开才能读到新值（进程环境在 exec 时固定）；LaunchAgent 会被 macOS 的「登录项与扩展」后台项管理，用户可在系统设置里关掉它——工具需要提供诊断入口而不是静默失败。详见 wayfinder 票 #1、#2 的调研。
