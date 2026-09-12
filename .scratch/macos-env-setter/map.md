# Wayfinder 地图：macOS 环境变量配置工具（macos-env-setter）

Label: wayfinder:map

## Destination

一个 SwiftUI 原生的 macOS 窗口应用（v1，日常自用）：在单一全局列表里管理环境变量，写入两个互不相通的层——shell 配置（~/.zprofile 标记块）与 GUI 应用层（launchctl），PATH 有专用排序 UI。所有决策票关闭、实现无未决问题时，路即探明；应用能日常使用即到达目的地。

## Notes

- 用户环境：zsh 登录 shell，仅有 ~/.zprofile（无 ~/.zshrc）；macOS 26.x（darwin 25.6.0）arm64；已装完整 Xcode（Swift 6.3）与 Node 24，无 Rust。
- 技术栈：SwiftUI 原生（已定）。只给自己用：不签名、不公证、本地构建（已定）。
- Charting 会话中敲定的决策：两层都管（shell rc + launchctl）；标记块写入策略（工具只改自己的标记块，其余内容永不触碰，写入前自动备份）；PATH 专用 UI 进 v1；普通窗口应用形态；单一全局列表组织。
- 工作方式：grilling 票用 /grilling + /domain-modeling；research 票用 /research 子代理；prototype 票用 /prototype。与用户交流用中文。
- Tracker：本地 markdown（`.scratch/macos-env-setter/`），地图即本文件，票在 `issues/`。

## Decisions so far

- [launchctl 持久化机制调研](issues/01-research-launchctl-persistence.md) — GUI 层持久化采用 RunAtLoad LaunchAgent 重放 `launchctl setenv`（无 sudo、SIP 不碍事）；`config user path` 弃用；已运行 App 必须重启才读到新值；注意 BTM 登录项可被用户关掉，需诊断入口。
- [同类工具与已知坑调研](issues/02-research-prior-art.md) — 「双层 + PATH 专用 UI + 原生 GUI」组合在现有生态是空位，定位成立；shell 写入学 CodingBuddy（标记块整块替换、原子写、时间戳备份）；PATH 标记块内加 `typeset -U path PATH`；避免 pref pane 形态与逐变量 sed。

## Not yet specified

- 实现拆解与验收标准：核心 CRUD + 标记块读写先行，launchctl 层次之；拆票时以两张研究票的 findings（research/launchctl-persistence.md、research/prior-art.md）为实现输入——原子写、时间戳备份、`typeset -U path PATH`、`launchctl bootstrap/bootout` 注册流程。
- 备份与恢复细节：备份文件位置、保留策略、一键恢复入口——随「数据模型与双层同步语义」带出。
- 导入现有配置：~/.zprofile 标记块外已手写的 export 如何收编进工具——随「数据模型与双层同步语义」带出。
- 冲突与错误处理 UX：文件被外部修改（含 live reload）、launchctl 写入失败、变量名非法等——随数据模型与 UI 原型带出。

## Out of scope

- 菜单栏常驻形态——v1 已定普通窗口应用（charting 决策）。
- profile 分组切换——v1 已定单一全局列表（charting 决策）。
- 代码签名 / 公证 / 对外分发——只给自己用（charting 决策）。
- 非 zsh shell（bash/fish 等）支持——用户只用 zsh。
