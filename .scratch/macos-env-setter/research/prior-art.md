# Prior Art：macOS 环境变量管理工具调研

- 日期：2026-09-12
- 票：`issues/02-research-prior-art.md`
- 方法：优先一手来源（各项目官方 README / 源码 / GitHub issue 区、man page），逐条标注来源。
- 本项目背景假设：SwiftUI 原生 macOS 单窗口 App，非沙盒、不签名，单一全局变量列表，管理两层：shell 配置（~/.zprofile 标记块）+ GUI 应用层（launchctl setenv + LaunchAgent），PATH 有专用排序 UI。

---

## 结论（对本工具的建议清单）

1. **双层共享同一条写入路径，避免 menv 式分叉**。GUI 层持久化的唯一无 sudo 方案就是「RunAtLoad LaunchAgent 在登录时对每个变量执行 `launchctl setenv`」——EnvPane、macenv、vienv、envctl 全部采用此模式。menv 的反面教材：PATH 类变量只进 launchctl 不写持久层，重启即丢。本工具的每次保存必须原子地同时完成：zprofile 标记块回写 + launchctl setenv 即时生效 + LaunchAgent 自身即持久层（agent 只需读工具自己的存储后批量 setenv，不必逐变量生成 plist，参考 EnvPane 的 agent 模式而非 menv 的逐变量 plist）。
2. **shell 写入用标记块 + 整块替换**，如 CodingBuddy 的 `# >>> CodingBuddy >>> … # <<< CodingBuddy <<<`。逐变量 sed/grep 删除（menv 做法）无法覆盖多行值、非 export 写法、fish 语法等，会留下垃圾行。保存前先做字节级 round-trip 校验：无法安全解析的内容保持只读并提示，绝不重写标记块之外的内容。
3. **写文件必须是：原子写 + 保留权限 + symlink 安全 + 时间戳备份 + 外部变更监听**。这套组合 CodingBuddy 已验证可行；menv/EnvPane 的安装、卸载、备份类 issue 是最常见的差评来源。
4. **PATH 专用 UI 是真实空白点**：vienv 明说「不知道怎么为 GUI App 设 PATH」并让用户改用 /etc/paths.d；EnvPane 把 PATH 当普通字符串。CodingBuddy 的「冒号分隔 → 可重排列表」编辑器是唯一先例，值得作为本工具核心差异化功能。实现上注意：
   - zsh 的 `path_helper`（`/etc/zprofile` 登录时调用）会把 `/etc/paths` 与 `/etc/paths.d` 的条目**追加在现有 PATH 之后且不去重**，导致用户自设条目被排到系统条目后面、且重复添加来源会产生重复条目；zsh 惯用解法是 `typeset -U path PATH`。工具的 zprofile 块应内置去重（`typeset -U` 或 guard），UI 中提供「重复条目检测」（menv `analyze` 的思路，但 menv 只诊断不修复）。
   - GUI 层 PATH：`launchctl setenv PATH` 生效但不持久（必须靠 agent 重放）；`sudo launchctl config user path` 持久但系统级、需重启、且在新版 macOS 上被部分 App 忽略——不建议作为本工具路径。
5. **不要做 System Preferences pane，不要用 `~/.MacOSX/environment.plist`、`/etc/launchd.conf`**。前两个机制分别死于 10.8（environment.plist 被移除）和 Ventura（System Settings 中旧 pref pane 空白，EnvPane #31/#36/#37，且至今未修复）；`/etc/launchd.conf` 死于 Yosemite。用户计划的「普通窗口 App」方向正确。
6. **生效语义要在 UI 明说**：改动只对「之后新启动」的进程生效；已运行 App 保留旧环境副本；开机时「重新打开窗口」恢复的 App 可能拿不到变量（EnvPane #22）；登录时才自动启动的 App 也拿不到（vienv README）。可加一个「验证」面板直接展示 `launchctl getenv KEY` 的结果。
7. **无签名自用 App 的头号差评是 Gatekeeper quarantine**（EnvPane #34/#35，README 里补救命令还写错过一次 `xattr -d` vs `xattr -dr`）。自用可接受，但建议在 App 内或 README 给出一条正确的首次打开指引。
8. **卸载要干净、可测试**：EnvPane 的「无法卸载」（#38）、「卸载不清理变量」（#17）都是 issue 常客。本工具应提供显式 uninstall：还原标记块、`launchctl unsetenv` 全部变量、卸载并删除 LaunchAgent。
9. **值得抄的小功能**（按 issue 需求热度）：秘密值打码（EnvPane #32；CodingBuddy 用 Touch ID 解锁）、导入/导出（EnvPane #27，多机同步凭据）、变量值插值 `$VAR`/`${VAR}`/`$(cmd)`（EnvPane 已支持，可后置）、外部编辑实时刷新（CodingBuddy）、多来源展示（menv 的 SOURCES 列）。
10. **数据模型不要过度设计**：EnvPane/macenv/menv 都是平铺 KEY→VALUE 单列表，与用户需求一致。envctl 的多文件 cluster、bitrise envman 的命名环境集合只对多 profile 场景有价值，用户明确只要单一全局列表，平铺即可。

### 覆盖层对照表

| 工具 | shell rc 文件 | launchctl setenv | 登录持久化 | PATH 专用处理 | 形态 |
|---|---|---|---|---|---|
| EnvPane | 否 | 是（agent 调同一 API） | 是（LaunchAgent + WatchPath） | 无（普通字符串） | pref pane（842★，已半弃） |
| yuezk/macenv | 否 | 是（eval conf） | 是（`~/.launchd.conf` + RunAtLoad agent） | 无 | CLI 单脚本（30★） |
| vienv | 函数注入 ~/.zshrc（非标记块） | 是 | 是（agent） | **明确不做**，让用户用 /etc/paths.d 或 ~/.zprofile | CLI 脚本（1★） |
| menv | 宣称多文件，实际只写 ~/.profile（裸 export 行） | 是 | 名义有，实际死代码 | 追加/前置/替换三选一 + 重复诊断 | CLI 单脚本（1★） |
| envctl | 手工 sourcing 循环（用户自加） | 是 | 是（agent） | 无 | CLI + cluster .env 文件（0★ 镜像） |
| CodingBuddy | 是（~/.zshenv/.zprofile/.zshrc，标记块） | **否** | 否 | 有（可重排列表编辑器） | Swift 原生 GUI（0★，2026 活跃） |
| direnv | shell hook（.zshrc 等） | 否 | 不适用 | 无 | shell 扩展（高★） |
| bitrise envman | 否 | 否 | 不适用 | 无 | CI 场景 CLI |

**结论：没有任何现存工具同时做好两层 + PATH 专用 UI。** 覆盖双层的（vienv/menv/envctl）全是 CLI 小脚本且都把 PATH 放弃或做漏了；带 PATH 编辑器的（CodingBuddy）只管 shell 层。本工具的定位（双层 + PATH 排序 + 原生 GUI）在现有生态中是空位。

---

## 各工具逐个分析

### 1. EnvPane（hschmidt/EnvPane）

- 842★，Objective-C，2013 年创建，最后 push 2025-02，非 archived，13 个 open issue（[repo](https://github.com/hschmidt/EnvPane)、[repo API](https://api.github.com/repos/hschmidt/EnvPane)）。
- **形态**：System Preferences 偏好面板；UI 是「简单的两列表格」列出所有变量，`+`/`-` 增删、点击行编辑（README）。
- **覆盖层**：只管 GUI/launchd 层，**完全不碰 shell rc 文件**。数据存 `~/.MacOSX/environment.plist`（复活 Apple 在 10.8 移除的机制）；每用户安装一个 LaunchAgent（因 launchd 不支持 home 相对路径的 WatchPath，无法做系统级），该 agent 「在登录早期、以及 environment.plist 变化时」运行，把 plist 里的变量经「与 `launchctl setenv`/`unsetenv` 相同的 API」导出到用户 launchd（README）。
- **生效语义**：改动几秒后对**新启动的 App** 生效；旧终端只间接继承（launchd 把环境传给新开的 Terminal 进程）。10.9 及以下需 `eval \`launchctl export\``，10.10 删除了该功能（README）。
- **亮点**：支持值插值 `$VAR`、`${VAR}`（含嵌套）、命令替换 `$(date)`；watch plist 文件所以手工编辑 plist 也能同步；卸载干净但保留用户 plist（README）。
- **issue 区主要问题**：见下文「已知坑」。

### 2. yuezk/macenv（ticket 中说的 "MacENV"）

- 30★，单个 shell 脚本装到 `/usr/local/bin/macenv`，2026-04 仍在更新（[repo](https://github.com/yuezk/macenv)）。
- **形态/用法**：CLI，`macenv set KEY value`；README 只有 3 句话：「为 GUI 应用设置环境变量」「重启 GUI App 使其感知」「设置的变量跨重启持久」。
- **机制**（README 未写，来自[脚本源码](https://raw.githubusercontent.com/yuezk/macenv/main/macenv)）：变量存为 `~/.launchd.conf` 里的 `setenv KEY "value"` 行；LaunchAgent 写到 `~/Library/LaunchAgents/local.launchd.conf.plist`，`RunAtLoad=true`，`ProgramArguments = bash -l -c "macenv load"`，即登录时以登录 shell 重跑脚本自身，`eval "launchctl ${line}"` 逐行重放。`set` 时用 `sed` 按变量名改行或追加。
- **无 PATH 特殊处理**、不碰 shell rc。
- **已知瑕疵**：重启后变量生效有延迟，需重启 GUI App（README 自述）。

### 3. vienv（dlejay/vienv）

- 1★，shell 脚本 + piped curl 安装，2025-08 更新（[repo](https://github.com/dlejay/vienv)）。
- **唯一同时覆盖两层的微型工具**：用户编辑 `environment.txt`（`VARIABLE=/path` 一行一个），工具对每项执行 `launchctl setenv`，并写 `~/Library/LaunchAgents/environment.plist` 于每次登录重放（README，机制致谢 Ted Toal / EnvPane）。
- **shell 层**：安装时往 `~/.zshrc`（或 `$ZDOTDIR`）加一个 `vienv()` 函数——是**函数注入，不是标记块**；卸载说明是「从 .zshrc 里删掉 vienv()」（README）。
- **PATH 立场**（README 原文逻辑）：明确承认自己「不是为所有 GUI App 设 PATH 的正确工具」，并引用 scriptingosx：系统级 PATH 应加文件到 `/etc/paths.d`，本地改用 `~/.zprofile`；作者直说「我不知道怎么把 PATH 也设给 GUI App」。
- **其他提醒**：运行中的 App 必须重启才可见；「登录时自动启动的 App 也拿不到新变量」；README 对比了 `.zshrc`（交互 shell）vs `.zprofile`（非交互 + MacVim 等 GUI 会读）；并指出 EnvPane 的 `~/.MacOSX/environment.plist` 方案在「$HOME 不可写」时失败。

### 4. menv（thgossler/menv）

- 1★，单文件 shell 脚本（MIT），2026-01 更新（[repo](https://github.com/thgossler/menv)）。
- **目标**：「跨 GUI 与终端 App 管理 macOS 用户级环境变量」——GUI 走 launchctl、终端走 shell profiles、持久化靠「LaunchAgent plist 和 profile 文件」（README）。
- **PATH 处理是亮点**：对 PATH、LD_LIBRARY_PATH、PYTHONPATH 等 10 个「路径类变量」特殊对待——`add` 时交互询问「追加（推荐）/ 前置 / 整个替换（危险！）」，`add-path` 永远安全追加，`remove-path` 删除单条目；`analyze` 子命令找出**重复条目、失效目录、PATH 组成**——但只诊断不自动去重，故障排查建议是 remove 再 add（README）。
- **数据模型**：平铺单列表，`list` 输出 NAME / VALUE / **SOURCES** 列，同一变量可同时来自「launchctl, shell-profile」；继承的系统变量只读展示「Context only」（README）。
- **README 与源码的严重不一致（重要教训）**（[menv.sh 源码](https://raw.githubusercontent.com/thgossler/menv/main/menv.sh)）：
  - README 宣称写 8 个 profile 文件（.zshrc/.zprofile/.bashrc/...），实际写入函数 `update_shell_var()` **硬编码只写 `~/.profile`**——macOS 默认 zsh 根本不会读它，除非用户自己 source；
  - shell 写入无标记块：按变量名 `grep -v "^export VAR="` 删旧行再**追加裸 `export NAME="value"` 行**，匹配不了 `PATH="$PATH:…"`、fish `set --export` 等任何其他写法；
  - `update_plist()`（生成 `~/Library/LaunchAgents/environment.plist`，`ProgramArguments=["/bin/launchctl","setenv",KEY,VALUE]`、`RunAtLoad=true`）**是死代码，从未被调用**；每次调用还会用单变量覆盖整个 plist；`remove_from_plist()` 则「如果包含我们的变量就删除整个 plist」；
  - **PATH 类变量只 `launchctl setenv`、跳过 profile 写入**（源码注释："PATH-like variable set in launchctl only to avoid duplication"）→ 重启后丢失；写 profile 前有 `.backup.YYYYmmdd_HHMMSS` 备份。

### 5. envctl（LangeVC/envctl，自托管仓库的公开镜像）

- Apache-2.0，shell，2026-07 更新（[repo](https://github.com/LangeVC/envctl)）。
- **数据模型**：变量按 **cluster** 组织——`~/.config/envctl/` 下多个标准 `.env` 文件（`ai.env`、`cloud.env`、`dev.env` + 自定义），纯 `KEY=VALUE` + `#` 注释。
- **macOS GUI 层**：`envctl install` 写 `~/Library/LaunchAgents/com.user.envctl.plist`，登录时运行 loader 脚本对每个 cluster 的每个 key `launchctl setenv KEY VALUE`；改动后 `envctl reload`，GUI App 只需重启 App 无需登出（README）。
- **Linux**：`~/.config/environment.d/`（systemd --user 会话读取）——跨平台对照值得注意。
- **shell 层**：不自动写 rc，让用户在 `~/.zshrc` 手工加 sourcing 循环（`set -a; source ...; set +a`）。
- **PATH**：无任何特殊处理。安全建议：cluster 文件 `chmod 600`、别进 git（README）。

### 6. CodingBuddy（apps3k-com/CodingBuddy）

- 0★，Swift/Xcode 原生 macOS App，2026-08 更新，要求 macOS 26+，明确**不沙盒**、直接编辑 home 下 dotfile（[repo](https://github.com/apps3k-com/CodingBuddy)）。
- **覆盖层：只有 shell 层**（~/.zshenv、~/.zprofile、~/.zshrc），README 无任何 launchctl/GUI App 支持——与本项目互补性最强、也最接近本项目 shell 层设想的工具。
- **UI**：单窗口列表/搜索三个文件的**全部**变量并聚合展示；理解 zsh 加载顺序（last-assignment-wins），并**标出被遮蔽（shadowed）的值**；专用的 **PATH 编辑器**：「把 `:` 分隔的值作为可重排列表编辑」；`.env` 导入/导出；敏感值打码、用 Touch ID 或密码解锁；外部改动实时刷新；亮/暗主题。
- **写文件纪律（最佳实践样本）**：字节精确的 round-trip；自动时间戳备份（存 `~/Library/Application Support/CodingBuddy/Backups/`）；原子写、symlink 安全、保留文件权限；「把每条赋值分解为前缀 + export + NAME = 引号 + 值 + 后缀」以精确复现；**无法复现的复杂行（命令替换、多重赋值）只展示、永不重写**；新变量写入标记块 `# >>> CodingBuddy >>> … # <<< CodingBuddy <<<`（README）。

### 7. direnv（direnv/direnv）

- shell 扩展，高星（[官网](https://direnv.net/)）。**只覆盖 shell，且是按目录而非全局**：hook 进 .zshrc 等，每次 prompt 前在当前及父目录找 `.envrc`（bash 代码），新 `.envrc` 必须 `direnv allow` 批准（安全模型）；实现上开 bash 子进程跑 `.envrc`，只把**环境 diff** 导回当前 shell，所以 shell 函数/别名导不出去；全局自定义走 `~/.config/direnv/direnvrc`。README/官网完全没提 launchctl 或 GUI App。
- 对本工具的借鉴：审批/安全模型（工具首次接管变量列表时的确认）、diff 式生效（改了什么一目了然）；但定位（项目级、目录级）与本项目（全局、GUI 层）正交。

### 8. bitrise envman（bitrise-io/envman）

- CI/CD 场景 CLI（Go）（[repo](https://github.com/bitrise-io/envman)）。变量组「environment sets」存 `.envstore.yml`，`envman run -- CMD` 把集合注入**单次子进程**环境，`--sensitive` 在日志里打码；**不写 rc、不碰 launchctl**。仅作数据模型参考（命名集合/单次注入），与全局持久化场景无关。

### （附）Gunmetal 与其他

- [myrrhkhan/Gunmetal](https://github.com/myrrhkhan/Gunmetal)：Rust GUI，「类似 Windows 编辑环境变量对话框」，0★、2023 后无更新——「Windows 风格列表编辑」是同类 UI 参照，但无实质内容可考。
- RCEnvironment 等旧 `~/.MacOSX/environment.plist` 偏好面板：机制已死（10.8 移除，见 EnvPane README），仅作历史教训。

---

## 已知坑汇总

按主题归并（每条含来源）：

**A. 机制性限制（不可避免，但要 UI 明示）**
1. 已运行进程保留自己的环境副本，任何改动只影响之后新启动的 App（EnvPane README；vienv README）。
2. `launchctl setenv` 不跨重启持久，必须由 RunAtLoad LaunchAgent 在登录时重放（EnvPane README 机制；[minutes#314](https://github.com/silverstein/minutes/issues/314) 的登录 agent 实例；[Ask Different](https://apple.stackexchange.com/questions/315826/how-to-revert-launchctl-path-to-defaults)）。
3. `sudo launchctl config user path` 虽持久但系统级、需重启生效，且被部分 GUI App 忽略/在新 macOS 上不可靠（[polyscope-community#17](https://github.com/beyondcode/polyscope-community/issues/17)、[Ask Different](https://apple.stackexchange.com/questions/243322/set-path-variable-so-that-it-is-detected-in-all-applications-even-outside-termi)）——不要采用。
4. 登录时自启动的 App 拿不到后设的变量（vienv README）；重启时「重新打开窗口」恢复的 App 丢变量（[EnvPane #22](https://github.com/hschmidt/EnvPane/issues/22)）。
5. SIP 使 DYLD_* 类变量无法经 launchctl setenv 设置（[EnvPane #24](https://github.com/hschmidt/EnvPane/issues/24)）。

**B. PATH 专属坑**
6. `path_helper`（`/etc/zprofile`，登录 shell 调用）把 `/etc/paths` 再 `/etc/paths.d` 的条目**追加**到 PATH，不去重；man page 明言它「只供 shell profile 使用」（[path_helper(8) man page](https://keith.github.io/xcode-man-pages/path_helper.8.html)）。后果：用户 PATH 条目被排到系统条目之后（[jeffwidman gist](https://gist.github.com/jeffwidman/47dfc34c0ed504e27aa52beeaa5a981a)），且 .zshenv/.zprofile/.zshrc 多处设 PATH 或嵌套 shell 时条目重复（[unix.SE 78807](https://unix.stackexchange.com/questions/78807/path-duplication-issues)、[SO 59131915](https://stackoverflow.com/questions/59131915/)）；zsh 惯用修复 `typeset -U path PATH`。
7. GUI 层与 shell 层的 PATH 各自独立演化：GUI App 经 launchd PATH + 它们再起的 shell 子进程会再走 path_helper 重排（[jeffwidman gist](https://gist.github.com/jeffwidman/47dfc34c0ed504e27aa52beeaa5a981a)）；vienv 作者直接放弃 GUI PATH（vienv README）。
8. 同一变量多来源时只诊断不去重，用户会积累重复条目（menv `analyze` 只报告；源码里 PATH 类变量干脆只进 launchctl，重启即丢）。

**C. 文件写入/共存坑**
9. 手工编辑与工具写入冲突：menv 只按 `^export VAR=` 匹配清理，其他写法留下垃圾；EnvPane 用 WatchPath 监听手工编辑（README）；CodingBuddy 用 live reload + 字节级回写 + 复杂行只读解决。
10. 写 8 个 profile 文件却只对 ~/.profile 生效（menv README vs 源码不一致）；备份是好实践（menv、CodingBuddy 都有时间戳备份）。

**D. 安装/分发坑（对不签名的自用 App 尤其相关）**
11. Gatekeeper quarantine 挡住未签名分发，用户找不到入口；README 里的补救命令还有拼写级 bug（[EnvPane #34](https://github.com/hschmidt/EnvPane/issues/34)、[#35 xattr -d → xattr -dr](https://github.com/hschmidt/EnvPane/issues/35)、[#39 要求把安装说明放进 dmg](https://github.com/hschmidt/EnvPane/issues/39)）。
12. 偏好面板形态已死：Big Sur 空白（[#31](https://github.com/hschmidt/EnvPane/issues/31)）、Ventura 13.x 空白未修复（[#36](https://github.com/hschmidt/EnvPane/issues/36)、[#37](https://github.com/hschmidt/EnvPane/issues/37)）——新 macOS 的 System Settings 不再兼容旧 pref pane。
13. 架构/系统演进坑：Catalina 删 32 位（[#29](https://github.com/hschmidt/EnvPane/issues/29)）、M1 上旧 loader 崩溃（[#33](https://github.com/hschmidt/EnvPane/issues/33)）；网络家目录 / $HOME 不可写导致 LaunchAgent 装不上（[#13](https://github.com/hschmidt/EnvPane/issues/13)、vienv README）。
14. 卸载不干净：卸载失败（[#38](https://github.com/hschmidt/EnvPane/issues/38)）、卸载不清变量（[#17](https://github.com/hschmidt/EnvPane/issues/17)）、安装失败「Failed to write agent's launchd job description」（[#23](https://github.com/hschmidt/EnvPane/issues/23)、[#14](https://github.com/hschmidt/EnvPane/issues/14)）。

**E. 交互/体验坑**
15. 「改完要在新终端/重启 App 才生效」是最常见困惑（[EnvPane #30](https://github.com/hschmidt/EnvPane/issues/30)：Catalina 上新 shell 也读不到 TEST_VAR）。
16. 明文展示敏感值有泄露风险（[EnvPane #32](https://github.com/hschmidt/EnvPane/issues/32)；envctl 建议 chmod 600）；多机同步缺导入/导出（[#27](https://github.com/hschmidt/EnvPane/issues/27)）。

---

## 来源列表

一手来源（项目仓库/源码/issue/官方文档/man page）：

1. EnvPane README：https://github.com/hschmidt/EnvPane
2. EnvPane 仓库元数据（stars/活跃度）：https://api.github.com/repos/hschmidt/EnvPane
3. EnvPane issues（#13–#40）：https://api.github.com/repos/hschmidt/EnvPane/issues?state=all&per_page=60 （各 issue 链接形如 https://github.com/hschmidt/EnvPane/issues/N）
4. yuezk/macenv README：https://github.com/yuezk/macenv
5. yuezk/macenv 脚本源码：https://raw.githubusercontent.com/yuezk/macenv/main/macenv
6. vienv README：https://github.com/dlejay/vienv
7. menv README：https://github.com/thgossler/menv
8. menv.sh 源码：https://raw.githubusercontent.com/thgossler/menv/main/menv.sh
9. envctl README：https://github.com/LangeVC/envctl
10. CodingBuddy README：https://github.com/apps3k-com/CodingBuddy
11. direnv 官网（how it works）：https://direnv.net/
12. bitrise envman README：https://github.com/bitrise-io/envman
13. path_helper(8) man page（Apple man page 镜像）：https://keith.github.io/xcode-man-pages/path_helper.8.html
14. GitHub 仓库搜索（macos environment variables gui）：https://api.github.com/search/repositories?q=macos+environment+variables+gui&sort=stars&per_page=20

二手来源（佐证，非主要依据）：

15. jeffwidman「Properly setting $PATH for zsh on macOS」：https://gist.github.com/jeffwidman/47dfc34c0ed504e27aa52beeaa5a981a
16. unix.SE「Path duplication issues」：https://unix.stackexchange.com/questions/78807/path-duplication-issues
17. SO「ZSH PATH entries backwards on macOS Catalina」：https://stackoverflow.com/questions/59131915/
18. SO「/etc/launchd.conf no longer works in Yosemite」：https://stackoverflow.com/questions/25385934/
19. Ask Different「How to revert launchctl PATH to defaults」：https://apple.stackexchange.com/questions/315826/
20. Ask Different「Set PATH variable so it is detected in all applications」：https://apple.stackexchange.com/questions/243322/
21. minutes#314（登录 LaunchAgent 重放 launchctl setenv PATH 的实例）：https://github.com/silverstein/minutes/issues/314
22. polyscope-community#17（launchctl config user path 对部分 GUI App 无效）：https://github.com/beyondcode/polyscope-community/issues/17
