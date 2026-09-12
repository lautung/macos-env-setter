# 同类工具与已知坑调研

Type: research
Status: resolved
Blocked by:

## Question

现有 macOS 环境变量管理工具如何解决「shell 配置 + GUI 应用」两层管理的问题？调研对象包括但不限于 EnvPane、envman、direnv，以及 GitHub 上高星的相关工具。要回答：

1. 各工具覆盖哪些层（shell rc 文件 / launchctl / /etc/paths.d 等），哪些两层都管。
2. UI 与数据模型模式：列表编辑、PATH 专用处理、标记块还是独立文件还是整文件重写。
3. 已知坑与用户差评点：PATH 重复条目、配置文件被手工编辑后冲突、系统更新后失效、改完要开新终端才生效等。
4. 值得本工具借鉴的设计，与应避免的做法。

产出：写入 `.scratch/macos-env-setter/research/prior-art.md`，并在本票文件末尾追加 `## Answer` 摘要后把 Status 改为 resolved。

## Answer

完整调研见 [research/prior-art.md](../research/prior-art.md)（10 工具逐个分析 + 来源）。要点：

1. **两层都管的工具全是 CLI 小脚本，且都没把 PATH 做成 GUI**：vienv（launchctl setenv + LaunchAgent + 往 .zshrc 注入函数）明确放弃 GUI PATH；menv（launchctl + 写 profile）存在严重 bug——PATH 只进 launchctl 不持久化、LaunchAgent 写入是死代码、README 宣称写 8 个 profile 实际只写 ~/.profile。
2. **带原生 GUI 的只有两个**：EnvPane（842★，pref pane，只管 launchd/environment.plist 层，不碰 shell rc，Ventura 起面板空白未修）和 CodingBuddy（Swift 原生，只管 shell 层，有唯一一个 PATH 可重排列表编辑器 + 标记块 + 字节级回写 + Touch ID 打码）。**「双层 + PATH 专用 UI + 原生 GUI」的组合在现有生态中是空位**，本工具定位成立。
3. **GUI 层持久化的唯一无 sudo 方案**已被 EnvPane/macenv/vienv/envctl 验证：RunAtLoad LaunchAgent 登录时重放 `launchctl setenv`。`launchctl config user path` 持久但需 sudo+重启且被部分 App 忽略，不用。
4. **shell 写入应学 CodingBuddy**：标记块整块替换、原子写/symlink 安全/保留权限/时间戳备份、复杂行只读、外部变更 live reload——menv 的逐变量 grep/sed 是反面教材。
5. **PATH 坑**：`path_helper`（/etc/zprofile）追加 /etc/paths 与 /etc/paths.d 条目且不去重、会把用户条目排后；建议标记块内用 `typeset -U path PATH` + UI 内重复诊断（menv analyze 思路）。
6. **要避免**：pref pane 形态（Ventura+ 空白）、`~/.MacOSX/environment.plist`（10.8 移除）、`/etc/launchd.conf`（Yosemite 移除）、写多个 shell 文件、卸载不清残留（EnvPane #17/#38）。
7. **UI 必须讲清生效语义**：只影响之后新启动的进程；重启时「重新打开窗口」恢复的 App 会丢变量（EnvPane #22）；登录自启 App 拿不到（vienv）。可加 launchctl getenv 验证面板。
8. **小功能可抄**：秘密值打码（EnvPane #32/CodingBuddy Touch ID）、导入导出（EnvPane #27）、变量插值 $VAR/$(cmd)（EnvPane）、多来源展示（menv SOURCES）。无签名分发的头号差评是 Gatekeeper quarantine（EnvPane #34/#35）。
