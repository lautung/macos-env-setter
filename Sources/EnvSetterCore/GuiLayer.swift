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
    /// 本次从 gui 域清除的变量（此前由本工具写入、如今不再启用）。
    public var removedKeys: [String]
    public var scriptWritten: Bool
    public var agentInstalled: Bool
    public var agentRegistered: Bool
    /// 是否已把变量注入当前会话（不必等下次登录）。
    public var liveSynced: Bool
    public var mismatches: [ValueMismatch]
    /// 需要讲给用户听的失败说明（UI 横幅）；nil = 无事发生。
    public var warning: String?

    public var isFullyApplied: Bool { outcome == .applied }
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
/// 从不清除「自己没拥有过」的变量（既不在当前记录里、也不在上次应用的记录里），
/// 避免踩到别的工具往 gui 域注入的同名变量。
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
    /// 对齐是为了让「应用时即时注入」与「下次登录由 agent 重放」展开出同样的值。
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

    // MARK: - 同步

    /// 显式应用时的 GUI 层同步：写脚本 → 装/更新 LaunchAgent 并注册 → 立即注入当前会话 → 回读自检。
    ///
    /// `previouslyManagedKeys` 是上次应用时工具记录里的 key（由引擎从本地状态给出）。
    /// 它让「这次被移除的记录」也算本工具拥有过——否则移除一条 GUI 记录后，
    /// gui 域里会一直留着它的值，而界面上已经说了应用时会清掉。
    /// 不传（= 空）时只清仍在记录里的 key：不知道自己的历史时，这是安全的子集。
    public func apply(
        entries: [ManagedEntry],
        previouslyManagedKeys: Set<String> = []
    ) -> GuiApplyReport {
        let enabled = SetenvScript.enabledKeys(entries: entries)
        let known = entries.compactMap(\.key)
        let previous = SetenvScript.appliedKeys(in: readString(paths.guiScriptURL) ?? "")
        // 只清除本工具写过的 key：上次脚本注入过，且它当时或现在还在记录里。
        let removals = previous.filter { key in
            !enabled.contains(key) && (known.contains(key) || previouslyManagedKeys.contains(key))
        }

        var report = GuiApplyReport(
            outcome: .skipped,
            scriptURL: paths.guiScriptURL,
            keys: enabled,
            removedKeys: removals,
            scriptWritten: false,
            agentInstalled: false,
            agentRegistered: false,
            liveSynced: false,
            mismatches: [],
            warning: nil
        )
        // 没有 GUI 层变量、此前也没同步过：不必为此装一个后台项。
        guard !enabled.isEmpty || !previous.isEmpty else { return report }

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
        for key in removals {
            let outcome = runLaunchctl(["unsetenv", key])
            if !outcome.succeeded {
                problems.append("清除 GUI 域残留失败（launchctl unsetenv \(key)）：\(outcome.message)")
            }
        }

        // 5. 回读自检：gui 域里的值是否真的等于脚本算出的值
        if report.liveSynced, let expected {
            report.mismatches = mismatches(expected: expected, keys: enabled)
            if !report.mismatches.isEmpty {
                let names = report.mismatches.map(\.key).joined(separator: "、")
                problems.append(
                    "回读不一致：\(names)——GUI 域里的值不是脚本算出的值。"
                    + "可能 agent 未随登录运行（登录项被系统设置关掉），请运行诊断查看。"
                )
            }
        }

        report.outcome = problems.isEmpty ? .applied : .partial
        report.warning = problems.isEmpty ? nil : problems.joined(separator: "\n")
        return report
    }

    // MARK: - 诊断

    /// 只读体检：脚本、LaunchAgent、注册状态、后台项开关、注入值逐项检查。
    public func diagnose(entries: [ManagedEntry]) -> GuiDiagnosis {
        var checks: [GuiCheck] = []
        let enabled = SetenvScript.enabledKeys(entries: entries)
        let previous = SetenvScript.appliedKeys(in: readString(paths.guiScriptURL) ?? "")
        // 有 GUI 层变量、或脚本里还留着上次同步的变量时才需要一个 agent；
        // 都没有（纯 shell 层用户）时，「没装 agent」是正常状态，不该报警。
        let needsAgent = !enabled.isEmpty || !previous.isEmpty

        // 1. 脚本
        if let onDisk = readString(paths.guiScriptURL) {
            if onDisk == scriptContent(entries: entries) {
                checks.append(GuiCheck(name: "GUI 层脚本", detail: "\(enabled.count) 个变量，与当前配置一致", status: .ok))
            } else {
                checks.append(
                    GuiCheck(
                        name: "GUI 层脚本",
                        detail: "内容与当前配置不一致：被手工改过或配置有未应用的改动（应用时会整份重写）",
                        status: .warning
                    )
                )
            }
        } else {
            checks.append(
                GuiCheck(
                    name: "GUI 层脚本",
                    detail: enabled.isEmpty ? "尚未创建（当前没有启用 GUI 层的变量）" : "尚未创建：应用后会生成",
                    status: enabled.isEmpty ? .ok : .warning
                )
            )
        }

        // 2. LaunchAgent
        if let data = try? Data(contentsOf: plistURL) {
            let matches = LaunchAgent.plistMatches(
                existing: data, label: label, scriptPath: paths.guiScriptURL.path
            )
            checks.append(
                GuiCheck(
                    name: "LaunchAgent",
                    detail: matches
                        ? "\(plistURL.lastPathComponent) 内容正确"
                        : "\(plistURL.lastPathComponent) 内容与目标不符（应用时会重写并重新注册）",
                    status: matches ? .ok : .warning
                )
            )
        } else {
            checks.append(
                GuiCheck(
                    name: "LaunchAgent",
                    detail: needsAgent
                        ? "\(plistURL.path) 不存在，登录时不会重放变量"
                        : "尚未安装（当前没有启用 GUI 层的变量）",
                    status: needsAgent ? .failed : .ok
                )
            )
        }

        // 3. 注册
        let registered = isRegistered()
        checks.append(
            GuiCheck(
                name: "agent 已注册",
                detail: registered
                    ? "\(label) 已在 \(domain)"
                    : (needsAgent
                        ? "\(label) 不在 \(domain)：本次登录不会执行（重新登录或应用后注册）"
                        : "尚未注册（当前没有启用 GUI 层的变量）"),
                status: registered || !needsAgent ? .ok : .warning
            )
        )

        // 4. 后台项（BTM）：Ventura 起用户可在系统设置里关掉，关掉即登录不重放
        switch launchdDisabledState() {
        case .disabled:
            checks.append(
                GuiCheck(
                    name: "后台项未被禁用",
                    detail: "该登录项在系统设置里被关闭：登录时不会重放变量（系统设置 → 通用 → 登录项与扩展 → 后台允许）",
                    status: .failed
                )
            )
        case .enabled:
            checks.append(GuiCheck(name: "后台项未被禁用", detail: "launchd 未禁用该服务", status: .ok))
        case .unknown(let reason):
            checks.append(GuiCheck(name: "后台项未被禁用", detail: "无法判断：\(reason)", status: .warning))
        }

        // 5. 注入值
        if let expected = printedValues() {
            if enabled.isEmpty {
                checks.append(GuiCheck(name: "值已注入当前会话", detail: "当前没有启用 GUI 层的变量", status: .ok))
            } else {
                let mismatches = mismatches(expected: expected, keys: enabled)
                if mismatches.isEmpty {
                    checks.append(
                        GuiCheck(
                            name: "值已注入当前会话",
                            detail: "\(enabled.count)/\(enabled.count) 与脚本一致",
                            status: .ok
                        )
                    )
                } else {
                    let detail = mismatches.map { mismatch in
                        "\(mismatch.key)（域里：\(mismatch.actual ?? "（不存在）")，脚本算的是：\(mismatch.expected)）"
                    }.joined(separator: "；")
                    checks.append(GuiCheck(name: "值已注入当前会话", detail: detail, status: .failed))
                }
            }
            // 6. 残留：脚本此前注入过、如今已关闭，但域里还留着
            let leftovers = leftoverKeys(entries: entries)
            if !leftovers.isEmpty {
                checks.append(
                    GuiCheck(
                        name: "无已关闭变量的残留",
                        detail: "这些变量已关闭 GUI 层，但仍留在 gui 域（应用后清除）：\(leftovers.joined(separator: "、"))",
                        status: .warning
                    )
                )
            }
        } else {
            checks.append(
                GuiCheck(
                    name: "值已注入当前会话",
                    detail: "无法读取脚本内容，跳过回读比对",
                    status: enabled.isEmpty ? .ok : .warning
                )
            )
        }

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

    /// 脚本此前注入过、如今不再启用、且仍留在 gui 域里的变量。
    private func leftoverKeys(entries: [ManagedEntry]) -> [String] {
        let enabled = SetenvScript.enabledKeys(entries: entries)
        let known = entries.compactMap(\.key)
        let previous = SetenvScript.appliedKeys(in: readString(paths.guiScriptURL) ?? "")
        return previous.filter { key in
            known.contains(key) && !enabled.contains(key)
                && !runLaunchctl(["getenv", key]).stdout.trimmingCharacters(in: .newlines).isEmpty
        }
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

    private func bootout() {
        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
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
