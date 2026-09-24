import Foundation

/// 应用后回读自检发现的一条不一致：`launchctl getenv` 拿到的值与脚本算出的期望值不同。
public struct ValueMismatch: Equatable, Sendable {
    public var key: String
    public var expected: String
    /// gui 域里的实际值；nil 表示该变量在域里不存在（被清除或从未注入）。
    public var actual: String?

    public init(key: String, expected: String, actual: String?) {
        self.key = key
        self.expected = expected
        self.actual = actual
    }
}

/// GUI 层同步的总体结果。
public enum GuiApplyOutcome: String, Equatable, Sendable {
    /// 当前没有启用 GUI 层的变量、此前也没同步过——没装 agent，也没动 gui 域。
    case skipped
    /// 脚本、agent、即时注入、回读自检全部成功。
    case applied
    /// 当前没有启用 GUI 层的变量：脚本、plist 与注册都已撤掉（没有 GUI 层变量就没有残留）。
    case uninstalled
    /// 有没做成的部分（见 `warning`），脚本与 agent 可能已部分就位。
    case partial
    /// 脚本或 plist 没写成，GUI 层没有生效。
    case failed
}

/// 一次 GUI 层同步的结果。GUI 层是「非阻塞」的：它从不抛错，失败以报告形式交给界面做横幅警告。
public struct GuiApplyReport: Equatable, Sendable {
    public var outcome: GuiApplyOutcome
    public var scriptURL: URL
    /// 本次写入脚本的变量（声明顺序）。
    public var keys: [String]
    /// 需要从 gui 域清除的变量（此前由本工具写入、如今不再启用）；不代表本轮已尝试移除。
    public var removalCandidates: [String]
    /// 本轮 `launchctl unsetenv` 成功返回、已从 GUI 层移除的候选变量。
    public var clearedKeys: [String]
    /// 本次仍未清除的待清理残留（见 CONTEXT.md）；引擎据此更新本地状态，供下次重试。
    public var pendingGuiRemovals: [String]
    public var scriptWritten: Bool
    public var agentInstalled: Bool
    public var agentRegistered: Bool
    /// 是否已把变量注入当前会话（不必等下次登录）。
    public var liveSynced: Bool
    public var mismatches: [ValueMismatch]
    /// 需要讲给用户听的失败说明（UI 横幅）；nil = 无事发生。
    public var warning: String?

    public var isFullyApplied: Bool { outcome == .applied }

    /// 保留兼容入口；过去的字段实际表示移除候选项，并非已清除项。
    @available(*, deprecated, renamed: "removalCandidates")
    public var removedKeys: [String] {
        get { removalCandidates }
        set { removalCandidates = newValue }
    }
}

public enum GuiCheckStatus: String, Equatable, Sendable {
    case ok
    case warning
    case failed
}

/// 诊断里的一项检查（界面按此逐行呈现）。
public struct GuiCheck: Equatable, Sendable {
    public var name: String
    public var detail: String
    public var status: GuiCheckStatus

    public init(name: String, detail: String, status: GuiCheckStatus) {
        self.name = name
        self.detail = detail
        self.status = status
    }
}

/// 诊断清单的行标题：只说「在查什么」的名词短语，结论只由图标（`status`）与详情表达。
///
/// 三条契约（界面与测试都依赖，改动前先想清楚）：
/// 同一份诊断里标题唯一——清单以标题作行身份（`List(…, id: \.name)`）；
/// 标题跨状态恒定——空态、健康态、故障态下同一行是同一个标题，空态才不会读出「已注册 / 尚未注册」这种矛盾句；
/// 顺序即 `checklist` 的顺序（脚本 → plist → 注册 → 后台项 → 注入值 → 残留）。
public enum GuiCheckTitle {
    public static let script = "GUI 层脚本"
    public static let agentFile = "LaunchAgent 文件"
    public static let agentRegistration = "LaunchAgent 注册"
    public static let backgroundItem = "后台项状态"
    public static let injectedValues = "当前会话注入值"
    public static let disabledLeftovers = "已关闭变量的残留"

    /// 清单里六行的标题，按呈现顺序。
    public static let checklist = [
        script, agentFile, agentRegistration, backgroundItem, injectedValues, disabledLeftovers,
    ]
}

/// GUI 层的只读体检结果。
public struct GuiDiagnosis: Equatable, Sendable {
    public var checks: [GuiCheck]

    public init(checks: [GuiCheck]) {
        self.checks = checks
    }

    public var isHealthy: Bool { checks.allSatisfy { $0.status == .ok } }
    public var hasFailure: Bool { checks.contains { $0.status == .failed } }
}

/// GUI 层（launchd 域）的读写：生成/重写 setenv.sh、装并注册 LaunchAgent、应用时即时注入当前会话、回读自检与诊断。
///
/// 边界：本工具只拥有 `~/Library/LaunchAgents/<label>.plist` 与 `~/Library/Application Support/EnvSetter/setenv.sh`；
/// 从不清除「自己没拥有过」的变量——所有权有三种来源：当前记录、上次应用的记录、待清理残留（三者都只会是工具写过的 key），
/// 避免踩到别的工具往 gui 域注入的同名变量。
/// 这两样东西也只在有 GUI 层变量时存在：关掉最后一条并应用即整体撤掉（没有 GUI 层变量 ⇒ 没有脚本、没有 plist、没有注册）。
public final class GuiLayer: Sendable {
    public let paths: EnginePaths
    public let label: String

    private let runner: ProcessRunning
    private let environment: [String: String]
    private let uid: uid_t

    public init(
        paths: EnginePaths,
        label: String = LaunchAgent.defaultLabel,
        runner: ProcessRunning = SystemProcessRunner(),
        environment: [String: String]? = nil,
        uid: uid_t = getuid()
    ) {
        self.paths = paths
        self.label = label
        self.runner = runner
        self.uid = uid
        self.environment = environment ?? Self.launchdLikeEnvironment()
    }

    /// 跑脚本时的子进程环境，与 launchd 给 agent 的环境对齐（HOME + 默认 PATH）。
    /// 对齐是为了让「应用时即时注入」与「下次登录由 agent 重放」展开出同样的值：agent 那侧由 plist 的
    /// `EnvironmentVariables` 钉住 PATH（见 `LaunchAgent.plistData`），这一侧在这里钉住。
    /// 两侧都钉住，脚本的 `$PATH` 锚点才只取决于配置，不取决于跑脚本的进程恰好继承到什么。
    public static func launchdLikeEnvironment() -> [String: String] {
        let user = NSUserName()
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": LaunchAgent.defaultPath,
            "USER": user,
            "LOGNAME": user,
            "SHELL": LaunchAgent.shellPath,
        ]
    }

    public var domain: String { "gui/\(uid)" }
    public var plistURL: URL { LaunchAgent.plistURL(label: label, paths: paths) }

    /// 脚本内容（纯函数；诊断据此判断磁盘上的脚本是否与当前配置一致）。
    public func scriptContent(entries: [ManagedEntry]) -> String {
        SetenvScript.generate(entries: entries, label: label)
    }

    /// 在重写脚本前确定本工具拥有、且这次要清的待清理残留。
    /// 旧脚本只提供历史线索：必须仍对应当前或上次已管理的记录；已落盘的待清理残留本身则是所有权记录。
    func pendingRemovalKeys(
        entries: [ManagedEntry],
        previouslyManagedKeys: Set<String> = [],
        pendingGuiRemovals: [String] = []
    ) -> [String] {
        let context = ownershipContext(entries: entries)
        var result = pendingGuiRemovals.filter { !context.enabled.contains($0) }
        var included = Set(result)
        for key in context.staleScriptKeys(ownedBy: previouslyManagedKeys) where included.insert(key).inserted {
            result.append(key)
        }
        return result
    }

    /// 判定「这个 key 归不归本工具管」所需的三组 key：启用中的、记录里的、脚本历史里的。
    /// 三组一起算，所有权规则就只有一处——清理（`pendingRemovalKeys`）与诊断（`leftoverKeys`）不会各算各的。
    private struct OwnershipContext {
        let enabled: Set<String>
        let known: Set<String>
        let scriptKeys: [String]

        init(entries: [ManagedEntry], scriptContent: String) {
            enabled = Set(SetenvScript.enabledKeys(entries: entries))
            known = Set(entries.compactMap(\.key))
            scriptKeys = SetenvScript.appliedKeys(in: scriptContent)
        }

        /// 脚本历史里「本工具拥有过、如今不再启用」的 key：拥有 = 现在在记录里，或上次应用时在记录里。
        func staleScriptKeys(ownedBy previouslyManagedKeys: Set<String>) -> [String] {
            scriptKeys.filter { !enabled.contains($0) && (known.contains($0) || previouslyManagedKeys.contains($0)) }
        }
    }

    private func ownershipContext(entries: [ManagedEntry]) -> OwnershipContext {
        OwnershipContext(entries: entries, scriptContent: readString(paths.guiScriptURL) ?? "")
    }

    // MARK: - 同步

    /// 显式应用时的 GUI 层同步：写脚本 → 装/更新 LaunchAgent 并注册 → 立即注入当前会话 → 回读自检。
    ///
    /// `previouslyManagedKeys` 是上次应用时工具记录里的 key（由引擎从本地状态给出）。
    /// 它让「这次被移除的记录」也算本工具拥有过——否则移除一条 GUI 记录后，
    /// gui 域里会一直留着它的值，而界面上已经说了应用时会清掉。
    /// 不传（= 空）时只清仍在记录里的 key：不知道自己的历史时，这是安全的子集。
    ///
    /// 没有启用 GUI 层的变量时走卸载（见 `uninstall`），而不是「什么都不装」——
    /// 不变式是**没有 GUI 层变量 ⇒ 没有脚本、没有 plist、没有注册**。
    public func apply(
        entries: [ManagedEntry],
        previouslyManagedKeys: Set<String> = [],
        pendingGuiRemovals: [String]? = nil
    ) -> GuiApplyReport {
        let enabled = SetenvScript.enabledKeys(entries: entries)
        // 引擎传入的列表已在脚本覆盖前持久化；独立使用 GUI 层时才从旧脚本补充历史 key。
        let removals = pendingGuiRemovals.map { keys in
            keys.filter { !enabled.contains($0) }
        } ?? self.pendingRemovalKeys(
            entries: entries,
            previouslyManagedKeys: previouslyManagedKeys
        )

        var report = GuiApplyReport(
            outcome: .skipped,
            scriptURL: paths.guiScriptURL,
            keys: enabled,
            removalCandidates: removals,
            clearedKeys: [],
            pendingGuiRemovals: removals,
            scriptWritten: false,
            agentInstalled: false,
            agentRegistered: false,
            liveSynced: false,
            mismatches: [],
            warning: nil
        )
        // 没有 GUI 层变量：不装 agent，并把上次装下的东西撤干净。
        guard !enabled.isEmpty else { return uninstall(report) }

        var problems: [String] = []

        // 1. 脚本（含变量原文，0600）
        do {
            try AtomicFile.write(Data(scriptContent(entries: entries).utf8), to: paths.guiScriptURL, mode: 0o600)
            report.scriptWritten = true
        } catch {
            report.outcome = .failed
            report.warning =
                "GUI 层脚本写入失败（\(paths.guiScriptURL.path)）：\(error.localizedDescription)。"
                + "shell 层写入不受影响；已运行的 App 仍会走终端层。"
            return report
        }

        // 2. LaunchAgent plist（内容一致就不动，避免无谓的重注册）
        do {
            let expected = try LaunchAgent.plistData(label: label, scriptPath: paths.guiScriptURL.path)
            let onDisk = try? Data(contentsOf: plistURL)
            let isCurrent = onDisk.map {
                LaunchAgent.plistMatches(existing: $0, label: label, scriptPath: paths.guiScriptURL.path)
            } ?? false
            if !isCurrent {
                try AtomicFile.write(expected, to: plistURL)
                report.agentInstalled = true
            }
        } catch {
            problems.append("LaunchAgent 写入失败（\(plistURL.path)）：\(error.localizedDescription)")
        }

        // 3. 注册（重复注册会失败，先 bootout；plist 刚更新过则必须重注册）
        if report.agentInstalled || !isRegistered() {
            bootout()
            var bootstrap = runLaunchctl(["bootstrap", domain, plistURL.path])
            if !bootstrap.succeeded, report.agentInstalled {
                // bootout 与 bootstrap 之间的时序偶发失败：稍等重试一次。
                Thread.sleep(forTimeInterval: 0.3)
                bootstrap = runLaunchctl(["bootstrap", domain, plistURL.path])
            }
            report.agentRegistered = bootstrap.succeeded
            if !bootstrap.succeeded {
                problems.append("LaunchAgent 注册失败（launchctl bootstrap \(domain)）：\(bootstrap.message)")
            }
        } else {
            report.agentRegistered = true
        }

        // 4. 即时生效：跑一次脚本，并清掉已关闭的残留（不必等下次登录）
        let expected = printedValues()
        let injected = runScript()
        if injected.succeeded {
            report.liveSynced = true
        } else {
            problems.append("把变量注入当前会话失败：\(injected.message)")
        }
        let clearResult = clearInjectedValues(removals)
        report.clearedKeys = clearResult.clearedKeys
        report.pendingGuiRemovals = clearResult.failedKeys
        problems += clearResult.problems

        // 5. 回读自检：gui 域里的值是否真的等于脚本算出的值
        if report.liveSynced, let expected {
            report.mismatches = mismatches(expected: expected, keys: enabled)
            if !report.mismatches.isEmpty {
                let names = report.mismatches.map(\.key).joined(separator: "、")
                problems.append(
                    "回读不一致：\(names)——GUI 域里的值不是脚本算出的值。期望值刚由本次应用写入，"
                    + "读到别的值说明这次写入没生效、或之后被别的工具/手工改过。请运行诊断查看。"
                )
            }
        }

        report.outcome = problems.isEmpty ? .applied : .partial
        report.warning = problems.isEmpty ? nil : problems.joined(separator: "\n")
        return report
    }

    /// 卸载：没有启用 GUI 层的变量时，把上次装下的脚本、plist 与注册一并撤掉。
    ///
    /// 本来就没装过（纯 shell 层用户、或刚撤干净）、也没有待清理残留时，只查一次注册，什么都不动，`skipped` 原样返回。
    /// 已关闭变量的残留（`removalCandidates`）照旧只清本工具写过的 key：launchd 没有标记块那样的隔离区。
    private func uninstall(_ report: GuiApplyReport) -> GuiApplyReport {
        var report = report
        let scriptExists = FileManager.default.fileExists(atPath: paths.guiScriptURL.path)
        let plistExists = FileManager.default.fileExists(atPath: plistURL.path)
        let wasRegistered = isRegistered()
        // 注册也要算：文件被手工删过而 agent 还挂着时，只有注册能说明「这里还有本工具的东西」。
        guard scriptExists || plistExists || wasRegistered || !report.removalCandidates.isEmpty else { return report }

        var problems: [String] = []

        // 1. 注册（先做：plist 一删，注册就成了没有着落的孤立项，要到重新登录才随域消失）
        let unregister = bootout()
        report.agentRegistered = isRegistered()
        if report.agentRegistered {
            problems.append(
                "LaunchAgent 取消注册失败（launchctl bootout \(domain)/\(label)）：\(unregister.message)。"
                + "注册仍在——重新登录后消失。"
            )
        }

        // 2. LaunchAgent plist（登录项本身）
        if plistExists {
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch {
                problems.append("LaunchAgent 文件删除失败（\(plistURL.path)）：\(error.localizedDescription)")
            }
        }

        // 3. gui 域里的值：只清本工具写过的 key
        let clearResult = clearInjectedValues(report.removalCandidates)
        report.clearedKeys = clearResult.clearedKeys
        report.pendingGuiRemovals = clearResult.failedKeys
        problems += clearResult.problems

        // 4. 脚本：保留它作为历史记录与排查现场；待清理残留已在覆盖脚本前落盘，是跨重启重试的依据。
        //    值没清干净时仍留着脚本，方便检查；下次重试也能从落盘的残留清单找回 key。
        if scriptExists {
            if clearResult.failedKeys.isEmpty {
                do {
                    try FileManager.default.removeItem(at: paths.guiScriptURL)
                } catch {
                    problems.append("GUI 层脚本删除失败（\(paths.guiScriptURL.path)）：\(error.localizedDescription)")
                }
            } else {
                problems.append("GUI 层脚本保留（\(paths.guiScriptURL.path)）：待清理变量已记录，下次重试会继续清除")
            }
        }

        report.outcome = problems.isEmpty ? .uninstalled : .partial
        report.warning = problems.isEmpty ? nil : problems.joined(separator: "\n")
        return report
    }

    /// 把上次注入的变量从 gui 域里清掉；返回没清成的 key（= 待清理残留）与对应的说明。
    private struct ClearResult {
        var clearedKeys: [String]
        var failedKeys: [String]
        var problems: [String]
    }

    private func clearInjectedValues(_ keys: [String]) -> ClearResult {
        var clearedKeys: [String] = []
        var failedKeys: [String] = []
        var problems: [String] = []
        for key in keys {
            let outcome = runLaunchctl(["unsetenv", key])
            if outcome.succeeded {
                clearedKeys.append(key)
                continue
            }
            failedKeys.append(key)
            problems.append("清除 GUI 域残留失败（launchctl unsetenv \(key)）：\(outcome.message)")
        }
        return ClearResult(clearedKeys: clearedKeys, failedKeys: failedKeys, problems: problems)
    }

    // MARK: - 诊断

    /// 只读体检：脚本、LaunchAgent、注册状态、后台项开关、注入值、已关闭变量的残留逐项检查。
    ///
    /// 六行恒定：每行的标题是名词短语、不随状态变化（见 `GuiCheckTitle`），
    /// 结论只写在详情里——空态下才读不出「标题说已注册、详情说尚未注册」这类矛盾句。
    ///
    /// 判定基准是**当前配置**（本地状态里的作用层开关），不是磁盘上碰巧有什么：
    /// 没有启用 GUI 层的变量时，脚本 / plist / 注册反过来成了「残留」检查——
    /// 本工具的东西不该还在系统里，应用会撤掉（不变式见 `apply` 的卸载路径），
    /// 后台项开关也不再影响什么（空态下不该为此报警）。
    public func diagnose(
        entries: [ManagedEntry],
        pendingGuiRemovals: [String] = []
    ) -> GuiDiagnosis {
        var checks: [GuiCheck] = []
        let enabled = SetenvScript.enabledKeys(entries: entries)
        // 当前配置要不要 GUI 层：不要的时候，「没装 agent」是正常状态，不该报警。
        let expectsGuiLayer = !enabled.isEmpty
        let scriptOnDisk = readString(paths.guiScriptURL)
        let plistOnDisk = try? Data(contentsOf: plistURL)

        // 1. 脚本
        if let onDisk = scriptOnDisk {
            if !expectsGuiLayer {
                checks.append(
                    GuiCheck(
                        name: GuiCheckTitle.script,
                        detail: "当前没有启用 GUI 层的变量：应用后会删除",
                        status: .warning
                    )
                )
            } else if onDisk == scriptContent(entries: entries) {
                checks.append(
                    GuiCheck(name: GuiCheckTitle.script, detail: "\(enabled.count) 个变量，与当前配置一致", status: .ok)
                )
            } else {
                checks.append(
                    GuiCheck(
                        name: GuiCheckTitle.script,
                        detail: "内容与当前配置不一致：被手工改过或配置有未应用的改动（应用时会整份重写）",
                        status: .warning
                    )
                )
            }
        } else {
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.script,
                    detail: expectsGuiLayer ? "尚未创建：应用后会生成" : "尚未创建（当前没有启用 GUI 层的变量）",
                    status: expectsGuiLayer ? .warning : .ok
                )
            )
        }

        // 2. LaunchAgent 文件
        if let data = plistOnDisk {
            if !expectsGuiLayer {
                checks.append(
                    GuiCheck(
                        name: GuiCheckTitle.agentFile,
                        detail: "\(plistURL.lastPathComponent) 仍在，但当前没有启用 GUI 层的变量（应用后会删除）",
                        status: .warning
                    )
                )
            } else {
                let matches = LaunchAgent.plistMatches(
                    existing: data, label: label, scriptPath: paths.guiScriptURL.path
                )
                checks.append(
                    GuiCheck(
                        name: GuiCheckTitle.agentFile,
                        detail: matches
                            ? "\(plistURL.lastPathComponent) 内容正确"
                            : "\(plistURL.lastPathComponent) 内容与目标不符（应用时会重写并重新注册）",
                        status: matches ? .ok : .warning
                    )
                )
            }
        } else {
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.agentFile,
                    detail: expectsGuiLayer
                        ? "\(plistURL.path) 不存在，登录时不会重放变量"
                        : "尚未安装（当前没有启用 GUI 层的变量）",
                    status: expectsGuiLayer ? .failed : .ok
                )
            )
        }

        // 3. 注册
        let registered = isRegistered()
        if registered, !expectsGuiLayer {
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.agentRegistration,
                    detail: "\(label) 仍注册在 \(domain)，但当前没有启用 GUI 层的变量（应用后会取消注册）",
                    status: .warning
                )
            )
        } else {
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.agentRegistration,
                    detail: registered
                        ? "\(label) 已在 \(domain)"
                        : (expectsGuiLayer
                            ? "\(label) 不在 \(domain)：本次登录不会执行（重新登录或应用后注册）"
                            : "尚未注册（当前没有启用 GUI 层的变量）"),
                    status: registered || !expectsGuiLayer ? .ok : .warning
                )
            )
        }

        // 4. 后台项（BTM）：Ventura 起用户可在系统设置里关掉，关掉即登录不重放
        switch launchdDisabledState() {
        case .disabled:
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.backgroundItem,
                    detail: expectsGuiLayer
                        ? "该登录项在系统设置里被关闭：登录时不会重放变量（系统设置 → 通用 → 登录项与扩展 → 后台允许）"
                        : "系统设置里该登录项被关闭，但当前没有启用 GUI 层的变量：这一开关已无影响",
                    status: expectsGuiLayer ? .failed : .ok
                )
            )
        case .enabled:
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.backgroundItem,
                    // 只说这一行量到的东西：系统设置里的开关没被关掉。
                    // 「登录时会重放变量」是装没装、注册没注册的事，那是上面两行的结论——
                    // 在这里替它们下结论，agent 缺失时就会读出自相矛盾的清单。
                    detail: expectsGuiLayer ? "未被系统设置禁用" : "未被系统设置禁用（当前没有启用 GUI 层的变量）",
                    status: .ok
                )
            )
        case .unknown(let reason):
            checks.append(
                GuiCheck(name: GuiCheckTitle.backgroundItem, detail: "无法判断：\(reason)", status: .warning)
            )
        }

        // 5. 注入值
        if enabled.isEmpty {
            checks.append(
                GuiCheck(name: GuiCheckTitle.injectedValues, detail: "当前没有启用 GUI 层的变量", status: .ok)
            )
        } else if let expected = printedValues() {
            let mismatches = mismatches(expected: expected, keys: enabled)
            if mismatches.isEmpty {
                checks.append(
                    GuiCheck(
                        name: GuiCheckTitle.injectedValues,
                        detail: "\(enabled.count)/\(enabled.count) 与脚本一致",
                        status: .ok
                    )
                )
            } else {
                let detail = mismatches.map { mismatch in
                    "\(mismatch.key)（域里：\(mismatch.actual ?? "（不存在）")，脚本算的是：\(mismatch.expected)）"
                }.joined(separator: "；")
                checks.append(GuiCheck(name: GuiCheckTitle.injectedValues, detail: detail, status: .failed))
            }
        } else {
            checks.append(
                GuiCheck(
                    name: GuiCheckTitle.injectedValues,
                    detail: "无法读取脚本内容，跳过回读比对",
                    status: .warning
                )
            )
        }

        // 6. 残留：脚本此前注入过、如今已关闭，但域里还留着
        let leftovers = leftoverKeys(entries: entries, pendingGuiRemovals: pendingGuiRemovals)
        checks.append(
            leftovers.isEmpty
                ? GuiCheck(name: GuiCheckTitle.disabledLeftovers, detail: "没有——已关闭 GUI 层的变量都不在 gui 域里", status: .ok)
                : GuiCheck(
                    name: GuiCheckTitle.disabledLeftovers,
                    detail: "这些变量已关闭 GUI 层，仍留在 gui 域或有待清理残留（重试 GUI 同步时清除）：\(leftovers.joined(separator: "、"))",
                    status: .warning
                )
        )

        return GuiDiagnosis(checks: checks)
    }

    // MARK: - Private

    private enum DisabledState {
        case enabled
        case disabled
        case unknown(String)
    }

    private func mismatches(expected: [String: String], keys: [String]) -> [ValueMismatch] {
        keys.compactMap { key in
            // 拿不到期望值的 key 不比对：宁可沉默，也不误报。
            guard let want = expected[key] else { return nil }
            let actual = runLaunchctl(["getenv", key]).stdout.trimmingCharacters(in: .newlines)
            guard actual != want else { return nil }
            return ValueMismatch(key: key, expected: want, actual: actual.isEmpty ? nil : actual)
        }
    }

    /// 找出脚本历史里仍存在于 gui 域的停用变量，以及落盘的待清理残留。
    private func leftoverKeys(entries: [ManagedEntry], pendingGuiRemovals: [String]) -> [String] {
        let context = ownershipContext(entries: entries)
        // 脚本历史这一支要查域里还有没有值（清成功过就不报了）；待清理残留本身即「没清成」，不必再查。
        var leftovers = context.staleScriptKeys(ownedBy: []).filter { key in
            !runLaunchctl(["getenv", key]).stdout.trimmingCharacters(in: .newlines).isEmpty
        }
        for key in pendingGuiRemovals where !context.enabled.contains(key) && !leftovers.contains(key) {
            leftovers.append(key)
        }
        return leftovers
    }

    /// 跑脚本的 `--print` 分支拿期望值（不调用 launchctl）；脚本不存在或跑不起来返回 nil。
    private func printedValues() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: paths.guiScriptURL.path) else { return nil }
        let outcome = runner.run(
            executable: LaunchAgent.shellPath,
            arguments: [paths.guiScriptURL.path, SetenvScript.printFlag],
            environment: environment
        )
        guard outcome.succeeded else { return nil }
        return SetenvScript.parsePrintedValues(outcome.stdout)
    }

    private func runScript() -> ProcessOutcome {
        runner.run(
            executable: LaunchAgent.shellPath,
            arguments: [paths.guiScriptURL.path],
            environment: environment
        )
    }

    private func isRegistered() -> Bool {
        runLaunchctl(["print", "\(domain)/\(label)"]).succeeded
    }

    /// 取消注册。没注册时它会失败，这是正常结果——调用方按 `isRegistered()` 判断成败。
    @discardableResult
    private func bootout() -> ProcessOutcome {
        runLaunchctl(["bootout", "\(domain)/\(label)"])
    }

    private func launchdDisabledState() -> DisabledState {
        let outcome = runLaunchctl(["print-disabled", domain])
        guard outcome.succeeded else { return .unknown(outcome.message) }
        for line in outcome.stdout.split(separator: "\n") {
            // 形如：\t"com.lautung.env-setter" => disabled
            guard let range = line.range(of: "\"\(label)\" =>") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("disabled") ? .disabled : .enabled
        }
        return .enabled  // 不在禁用表里 = 没有被显式禁用
    }

    private func runLaunchctl(_ arguments: [String]) -> ProcessOutcome {
        runner.run(executable: LaunchAgent.launchctlPath, arguments: arguments, environment: environment)
    }

    private func readString(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
