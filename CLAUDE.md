# CLAUDE.md

macOS 环境变量配置工具（SwiftUI 原生窗口应用）：在一个全局列表里管理环境变量，写入两个互不相通的层——shell 配置（`~/.zprofile` 标记块）与 GUI 应用层（launchd）。

## 结构

| Target | 角色 |
|---|---|
| `EnvSetterCore` | 引擎：数据模型、标记块读写、漂移、备份、收编、GUI 层（LaunchAgent + `setenv.sh`） |
| `EnvSetterUI` | 界面状态（`AppModel`）与 SwiftUI 视图；纯逻辑（差异判定、校验、PATH 编辑、打码）不依赖 SwiftUI，可直接测 |
| `EnvSetterApp` | SwiftUI 窗口应用，正式入口 |
| `envsetter` | CLI：供验收与诊断（`status` / `adopt` / `restore` / `gui`） |

## 构建与运行

- 应用：`./Scripts/build-app.sh`（构建 `.build/EnvSetter.app` 并打开；`--no-open` 只构建，`--debug` 用 debug 配置）
- 安装：`./Scripts/install-app.sh`（构建后装到 `~/Applications/EnvSetter.app`；覆盖安装，不打断正在运行的实例）
- 发布包：`./Scripts/package-app.sh`（release 构建 → `dist/EnvSetter-<版本>.zip`；版本号取自 `Scripts/Info.plist`，本地构建、不签名）
- 图标：`Scripts/make-icon.swift` 画出 `.icns`，构建时由 `build-app.sh` 生成进包并自检（生成失败即构建失败）。仓库不存图片二进制，见 `docs/adr/0002`
- CLI：`swift run envsetter status`
- 测试：`swift test`
- 真机 launchd 验收（默认不跑，会临时注册一个独立 label 的 agent 并全部清理）：
  `ENVSETTER_LIVE_LAUNCHD=1 swift test --filter LaunchdLiveTests`

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`lautung/macos-env-setter`), managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage` … `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
