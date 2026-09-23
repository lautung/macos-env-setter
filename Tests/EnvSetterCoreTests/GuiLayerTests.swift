import Testing
import Foundation
@testable import EnvSetterCore

/// 记录调用、按「可执行文件 + 参数」回答的假执行器：让 GUI 层的流程可在不碰真 launchd 的前提下断言。
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    private(set) var calls: [Call] = []
    /// 键为「可执行文件 + 参数」，未命中则用 `defaultOutcome`（成功、空输出）。
    var outcomes: [[String]: ProcessOutcome] = [:]
    var defaultOutcome = ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
    /// 注册状态的模型：设为非 nil 后，`print gui/<uid>/<label>` 由它回答，`bootstrap` / `bootout` 相应增删。
    /// nil（默认）= 不建模，照旧看 `outcomes` / `defaultOutcome`。
    /// 有了它，「取消注册真的生效」才断言得出来——常量应答下 bootout 前后是同一个答案。
    var registeredLabels: Set<String>?

    func run(executable: String, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        if let outcome = outcomes[[executable] + arguments] { return outcome }
        if let registration = registrationAnswer(executable: executable, arguments: arguments) { return registration }
        return defaultOutcome
    }

    /// 按 `registeredLabels` 回答与注册有关的调用；nil = 这个假执行器没在建模注册状态。
    private func registrationAnswer(executable: String, arguments: [String]) -> ProcessOutcome? {
        guard var labels = registeredLabels, executable == LaunchAgent.launchctlPath else { return nil }
        switch arguments.first {
        case "bootstrap" where arguments.count == 3:
            labels.insert(Self.label(ofPlistAt: arguments[2]))
            registeredLabels = labels
            return defaultOutcome
        case "bootout" where arguments.count == 2:
            labels.remove(Self.label(inService: arguments[1]))
            registeredLabels = labels
            return defaultOutcome
        case "print" where arguments.count == 2:
            return labels.contains(Self.label(inService: arguments[1]))
                ? ProcessOutcome(exitCode: 0, stdout: "service = \(arguments[1])", stderr: "")
                : ProcessOutcome(exitCode: 113, stdout: "", stderr: "Could not find service")
        default:
            return nil
        }
    }

    /// `gui/501/com.example.label` → `com.example.label`
    private static func label(inService service: String) -> String {
        String(service.split(separator: "/").last ?? "")
    }

    /// `/…/com.example.label.plist` → `com.example.label`
    private static func label(ofPlistAt path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    func called(_ executable: String, _ arguments: [String]) -> Bool {
        calls.contains { $0.executable == executable && $0.arguments == arguments }
    }

    func calls(matching executable: String, firstArgument: String) -> [Call] {
        calls.filter { $0.executable == executable && $0.arguments.first == firstArgument }
    }

    /// 某次调用之后发生的调用（断言「这一次没有再重注册」）。
    func callsSince(_ count: Int) -> [Call] { Array(calls.dropFirst(count)) }

    func called(_ executable: String, _ arguments: [String], since count: Int) -> Bool {
        callsSince(count).contains { $0.executable == executable && $0.arguments == arguments }
    }
}

struct GuiLayerTests {
    private let label = "com.example.envsetter-test"

    private func makeLayer(
        home: URL,
        paths: EnginePaths,
        runner: FakeProcessRunner,
        uid: uid_t = 501
    ) -> GuiLayer {
        GuiLayer(
            paths: paths,
            label: label,
            runner: runner,
            environment: ["HOME": home.path, "PATH": LaunchAgent.defaultPath],
            uid: uid
        )
    }

    private func record(_ key: String, _ value: String, gui: Bool = true) -> ManagedEntry {
        .record(VariableRecord(key: key, rawValue: value, shellEnabled: true, guiEnabled: gui))
    }

    /// 让假执行器回答「没注册」：本工具没装过任何东西时的正常状态。
    private func stubUnregistered(_ runner: FakeProcessRunner) {
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
    }

    /// 让假执行器对 GUI 层的正常流程给出「一切正常」的应答：未注册、脚本值正确、回读一致。
    private func stubHappyPath(_ runner: FakeProcessRunner, paths: EnginePaths, entries: [ManagedEntry]) -> [String: String] {
        let script = SetenvScript.generate(entries: entries, label: label)
        let values = SetenvScript.parsePrintedValues(
            SetenvScript.enabledKeys(entries: entries)
                .map { "\($0)=\(stubbedValue(of: $0, script: script))" }
                .joined(separator: "\n")
        )
        runner.outcomes[[LaunchAgent.shellPath, paths.guiScriptURL.path, SetenvScript.printFlag]] = ProcessOutcome(
            exitCode: 0, stdout: values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"), stderr: ""
        )
        for (key, value) in values {
            runner.outcomes[[LaunchAgent.launchctlPath, "getenv", key]] = ProcessOutcome(
                exitCode: 0, stdout: value + "\n", stderr: ""
            )
        }
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
        return values
    }

    /// 从脚本里读出某个 key 的赋值原文（假执行器不跑真 shell，这里只做「值原样」的近似）。
    private func stubbedValue(of key: String, script: String) -> String {
        for line in script.split(separator: "\n") {
            let prefix = "\(key)="
            guard line.hasPrefix(prefix) else { continue }
            var value = String(line.dropFirst(prefix.count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return ""
    }

    @Test func applyWritesScriptAndAgentThenInjectsAndVerifies() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools"), record("JAVA_HOME", "/opt/tools/jdk")]
        let expected = stubHappyPath(runner, paths: paths, entries: entries)
        let layer = makeLayer(home: home, paths: paths, runner: runner)

        let report = layer.apply(entries: entries)

        #expect(report.outcome == .applied, "\(report.warning ?? "")")
        #expect(report.scriptWritten)
        #expect(report.agentInstalled)
        #expect(report.agentRegistered)
        #expect(report.liveSynced)
        #expect(report.keys == ["TOOLS", "JAVA_HOME"])
        #expect(report.mismatches.isEmpty)

        // 脚本落盘且内容与生成器一致；脚本含变量原文 → 0600
        #expect(try TestSupport.read(paths.guiScriptURL) == layer.scriptContent(entries: entries))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.guiScriptURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        // plist 落盘且内容正确
        let plistData = try Data(contentsOf: layer.plistURL)
        #expect(LaunchAgent.label(inPlist: plistData) == label)
        #expect(
            LaunchAgent.plistMatches(
                existing: plistData, label: label, scriptPath: paths.guiScriptURL.path
            )
        )
        #expect(layer.plistURL == paths.launchAgentsDirectory.appending(path: "\(label).plist"))

        // 注册流程：先 bootout 再 bootstrap；随后跑脚本注入、逐 key 回读
        #expect(runner.called(LaunchAgent.launchctlPath, ["bootout", "gui/501/\(label)"]))
        #expect(runner.called(LaunchAgent.launchctlPath, ["bootstrap", "gui/501", layer.plistURL.path]))
        #expect(runner.called(LaunchAgent.shellPath, [paths.guiScriptURL.path]))
        for key in expected.keys {
            #expect(runner.called(LaunchAgent.launchctlPath, ["getenv", key]))
        }
    }

    /// 跑脚本（算期望值 + 即时注入）用的是固定的 launchd-like 环境，不是本进程继承到的环境。
    ///
    /// 这条撑住 apply 的幂等：PATH 记录里的 `$PATH` 锚点若跟着本进程的 PATH 走，每应用一次就会把目录再前插一遍
    /// ——本工具注入的 PATH 恰恰是本进程 PATH 的来源之一（Dock 启动的 App 继承的就是 gui 域）。
    @Test func scriptRunsInTheLaunchdLikeEnvironmentNotTheCallers() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("PATH", "/opt/tools/bin:$PATH")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        // 不传 environment：走 GuiLayer 自己的 launchd-like 默认值
        let layer = GuiLayer(paths: paths, label: label, runner: runner, uid: 501)

        _ = layer.apply(entries: entries)

        let runs = runner.calls(matching: LaunchAgent.shellPath, firstArgument: paths.guiScriptURL.path)
        #expect(!runs.isEmpty)
        for run in runs {
            #expect(run.environment["PATH"] == LaunchAgent.defaultPath)
        }
    }

    @Test func applyDoesNotReinstallOrRebootstrapWhenNothingChanged() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        let layer = makeLayer(home: home, paths: paths, runner: runner)

        // 第一次：装好并注册
        let first = layer.apply(entries: entries)
        #expect(first.agentInstalled)

        // 第二次：内容没变 + 已注册 → 不重写 plist、不 bootout/bootstrap
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 0, stdout: "service = \(label)", stderr: ""
        )
        let callsBefore = runner.calls.count
        let second = layer.apply(entries: entries)
        #expect(second.outcome == .applied, "\(second.warning ?? "")")
        #expect(!second.agentInstalled)
        #expect(second.agentRegistered)
        #expect(!runner.called(LaunchAgent.launchctlPath, ["bootout", "gui/501/\(label)"], since: callsBefore))
    }

    @Test func applyClearsOnlyKeysItPreviouslyInjected() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        // 上一次同步写下的脚本：A、B 是工具写过的，FOREIGN 不是本工具的记录
        let previous: [ManagedEntry] = [record("A", "1"), record("B", "2")]
        try TestSupport.write(
            SetenvScript.generate(entries: previous, label: label)
                + "\n\(LaunchAgent.launchctlPath) setenv FOREIGN \"$FOREIGN\"\n",
            to: paths.guiScriptURL
        )
        // 这次 B 关了 GUI 开关
        let entries: [ManagedEntry] = [record("A", "1"), record("B", "2", gui: false)]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "A"]] = ProcessOutcome(exitCode: 0, stdout: "1\n", stderr: "")
        let layer = makeLayer(home: home, paths: paths, runner: runner)

        let report = layer.apply(entries: entries)

        #expect(report.removedKeys == ["B"])
        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "B"]))
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "FOREIGN"]))
        #expect(report.outcome == .applied, "\(report.warning ?? "")")
    }

    @Test func applyReportsReadbackMismatchInsteadOfThrowing() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("JAVA_HOME", "/opt/tools/jdk")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        // gui 域里是旧值
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "JAVA_HOME"]] = ProcessOutcome(
            exitCode: 0, stdout: "/opt/old/jdk\n", stderr: ""
        )
        let layer = makeLayer(home: home, paths: paths, runner: runner)

        let report = layer.apply(entries: entries)

        #expect(report.outcome == .partial)
        #expect(report.mismatches == [ValueMismatch(key: "JAVA_HOME", expected: "/opt/tools/jdk", actual: "/opt/old/jdk")])
        let warning = try #require(report.warning)
        #expect(warning.contains("JAVA_HOME"))
    }

    @Test func applySkipsEntirelyWhenThereIsNothingToSync() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        stubUnregistered(runner)

        // 只有 shell 层变量：不装 agent，也不动 gui 域
        let report = layer.apply(entries: [record("TOOLS", "/opt/tools", gui: false)])

        #expect(report.outcome == .skipped)
        // 唯一的 launchd 交互是那次只读的注册查询——本来就没装过，什么都不动
        #expect(runner.calls.map(\.arguments) == [["print", "gui/501/\(label)"]])
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: layer.plistURL.path))
    }

    // MARK: - 整体撤回（没有 GUI 层变量就没有残留）

    /// 关掉最后一条 GUI 层变量并应用：脚本、plist、注册一并撤掉。
    @Test func applyUninstallsScriptAndAgentWhenTheLastGuiVariableTurnsOff() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        let on: [ManagedEntry] = [record("TOOLS", "/opt/tools"), record("JAVA_HOME", "/opt/tools/jdk")]
        _ = stubHappyPath(runner, paths: paths, entries: on)

        // 先真的装起来：脚本、plist、注册都在
        let installed = layer.apply(entries: on)
        #expect(installed.outcome == .applied, "\(installed.warning ?? "")")
        #expect(FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
        #expect(FileManager.default.fileExists(atPath: layer.plistURL.path))

        // 两条都关掉 GUI 开关（记录还在，只是不再进 GUI 层）
        let callsBefore = runner.calls.count
        let report = layer.apply(entries: [record("TOOLS", "/opt/tools", gui: false), record("JAVA_HOME", "/opt/tools/jdk", gui: false)])

        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: layer.plistURL.path))
        #expect(runner.called(LaunchAgent.launchctlPath, ["bootout", "gui/501/\(label)"], since: callsBefore))
        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "TOOLS"], since: callsBefore))
        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "JAVA_HOME"], since: callsBefore))
        #expect(report.outcome == .uninstalled)
        #expect(report.removedKeys == ["TOOLS", "JAVA_HOME"])
        #expect(report.warning == nil)
    }

    /// 撤回只清本工具写过的 key：脚本里手工加的那一行不碰（gui 域里别的工具设的同名变量不受影响）。
    @Test func uninstallClearsOnlyKeysTheToolInjected() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        try TestSupport.write(
            SetenvScript.generate(entries: [record("A", "1")], label: label)
                + "\n\(LaunchAgent.launchctlPath) setenv FOREIGN \"$FOREIGN\"\n",
            to: paths.guiScriptURL
        )
        stubUnregistered(runner)

        let report = layer.apply(entries: [record("A", "1", gui: false)])

        #expect(report.removedKeys == ["A"])
        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"]))
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "FOREIGN"]))
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
    }

    /// 本来就没有 GUI 层变量（纯 shell 层用户、或刚撤干净）：重复应用也不改动什么。
    @Test func applyStaysQuietWhenNoGuiVariableEverExisted() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        stubUnregistered(runner)
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools", gui: false)]

        _ = layer.apply(entries: entries)
        let second = layer.apply(entries: entries)

        #expect(second.outcome == .skipped)
        // 每次只查一次注册（只读），没有 bootstrap / bootout / unsetenv 这类改动
        #expect(runner.calls.map(\.arguments) == [["print", "gui/501/\(label)"], ["print", "gui/501/\(label)"]])
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: layer.plistURL.path))
    }

    /// 取消注册没做成：文件照删（不留脚本），但报告成 partial 并说清注册还在。
    @Test func uninstallReportsPartialWhenTheRegistrationSurvives() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        try TestSupport.write(
            SetenvScript.generate(entries: [record("A", "1")], label: label), to: paths.guiScriptURL
        )
        // bootout 没起作用：print 一直成功
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 0, stdout: "service", stderr: ""
        )

        let report = layer.apply(entries: [record("A", "1", gui: false)])

        #expect(report.outcome == .partial)
        #expect(try #require(report.warning).contains("取消注册"))
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
    }

    /// 撤回之后诊断不再有需要修的项：脚本、plist、注册、后台项、注入值、残留六行全绿。
    @Test func diagnosisIsCleanAfterTheGuiLayerIsUninstalled() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        let on: [ManagedEntry] = [record("TOOLS", "/opt/tools")]
        _ = stubHappyPath(runner, paths: paths, entries: on)
        _ = layer.apply(entries: on)

        let off: [ManagedEntry] = [record("TOOLS", "/opt/tools", gui: false)]
        _ = layer.apply(entries: off)
        let diagnosis = layer.diagnose(entries: off)

        #expect(diagnosis.isHealthy, "\(diagnosis.checks.filter { $0.status != .ok })")
        let registration = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.agentRegistration })
        #expect(registration.detail.contains("尚未注册"))
    }

    /// 没有 GUI 层变量却还留着脚本 / plist / 注册：诊断按「残留」报警，并说明应用后会撤掉。
    @Test func diagnosisFlagsLeftoversAndOrphanRegistrationWithoutGuiVariables() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        try TestSupport.write(
            SetenvScript.generate(entries: [record("OLD", "stale")], label: label), to: paths.guiScriptURL
        )
        try AtomicFile.write(
            try LaunchAgent.plistData(label: label, scriptPath: paths.guiScriptURL.path), to: layer.plistURL
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 0, stdout: "service", stderr: ""
        )

        let diagnosis = layer.diagnose(entries: [record("OLD", "stale", gui: false)])

        let script = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.script })
        #expect(script.status == .warning)
        #expect(script.detail.contains("应用后会删除"))
        let agentFile = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.agentFile })
        #expect(agentFile.status == .warning)
        #expect(agentFile.detail.contains("应用后会删除"))
        let registration = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.agentRegistration })
        #expect(registration.status == .warning)
        #expect(registration.detail.contains("应用后会取消注册"))
    }

    /// 空态下系统设置里留着本工具的禁用记录（上次安装的遗留）：不该报警——
    /// 「没有 GUI 层变量」时这个开关已经无影响。
    @Test func diagnosisDoesNotAlarmOnAStaleDisabledLoginItemWithoutGuiVariables() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        stubUnregistered(runner)
        runner.outcomes[[LaunchAgent.launchctlPath, "print-disabled", "gui/501"]] = ProcessOutcome(
            exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"\(label)\" => disabled\n\t}\n", stderr: ""
        )

        let diagnosis = makeLayer(home: home, paths: paths, runner: runner).diagnose(entries: [])

        let backgroundItem = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.backgroundItem })
        #expect(backgroundItem.status == .ok)
        #expect(diagnosis.isHealthy, "\(diagnosis.checks.filter { $0.status != .ok })")
    }

    /// 文件被手工删过、只剩一个孤立注册：应用照样把它取消掉——不变式的第三项（没有注册）也要守住。
    @Test func applyClearsAnOrphanRegistrationLeftWithoutFiles() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        runner.registeredLabels = [label]

        let report = layer.apply(entries: [])

        #expect(runner.called(LaunchAgent.launchctlPath, ["bootout", "gui/501/\(label)"]))
        #expect(runner.registeredLabels?.isEmpty == true)
        #expect(report.outcome == .uninstalled)
        #expect(report.warning == nil)
    }

    /// 值没清干净时留着脚本：它是「注入过哪些 key」的唯一依据——
    /// 下次应用据此重试清理，诊断据此报出残留，而不是无从查起。
    @Test func uninstallKeepsTheScriptWhenDomainValuesCouldNotBeCleared() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        try TestSupport.write(
            SetenvScript.generate(entries: [record("A", "1")], label: label), to: paths.guiScriptURL
        )
        stubUnregistered(runner)
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "Unsetenv failed"
        )
        // 域里还留着 A 的值（诊断据此报残留）
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "1\n", stderr: ""
        )

        let report = layer.apply(entries: [record("A", "1", gui: false)])

        #expect(report.outcome == .partial)
        #expect(try #require(report.warning).contains("unsetenv A"))
        #expect(FileManager.default.fileExists(atPath: paths.guiScriptURL.path), "脚本留着才能重试清理")

        let leftovers = layer.diagnose(entries: [record("A", "1", gui: false)])
            .checks.first { $0.name == GuiCheckTitle.disabledLeftovers }
        #expect(leftovers?.status == .warning)
        #expect(leftovers?.detail.contains("A") == true)

        // 清得掉之后再应用一次：这次撤干净
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "", stderr: ""
        )
        let retry = layer.apply(entries: [record("A", "1", gui: false)])
        #expect(retry.outcome == .uninstalled, "\(retry.warning ?? "")")
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
    }

    @Test func registrationFailureIsReportedNotThrown() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        runner.outcomes[[LaunchAgent.launchctlPath, "bootstrap", "gui/501", LaunchAgent.plistURL(label: label, paths: paths).path]] =
            ProcessOutcome(exitCode: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error")
        let layer = makeLayer(home: home, paths: paths, runner: runner)

        let report = layer.apply(entries: entries)

        #expect(report.outcome == .partial)
        #expect(!report.agentRegistered)
        #expect(try #require(report.warning).contains("bootstrap"))
        // 脚本仍然写成了，即时注入仍然做过
        #expect(report.scriptWritten)
        #expect(report.liveSynced)
    }

    // MARK: - 诊断

    @Test func diagnoseReportsHealthyWhenEverythingMatches() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools"), record("JAVA_HOME", "/opt/tools/jdk")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(exitCode: 0, stdout: "service", stderr: "")
        runner.outcomes[[LaunchAgent.launchctlPath, "print-disabled", "gui/501"]] = ProcessOutcome(
            exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"\(label)\" => enabled\n\t}\n", stderr: ""
        )
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        _ = layer.apply(entries: entries)

        let diagnosis = layer.diagnose(entries: entries)

        #expect(diagnosis.isHealthy, "\(diagnosis.checks.filter { $0.status != .ok })")
        #expect(diagnosis.checks.map(\.name).contains(GuiCheckTitle.injectedValues))
    }

    @Test func diagnoseSurfacesDisabledLoginItemAndMissingAgent() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools")]
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        // 什么都没装：未注册 → launchctl print 失败；后台项被系统设置关掉
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "print-disabled", "gui/501"]] = ProcessOutcome(
            exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"\(label)\" => disabled\n\t}\n", stderr: ""
        )

        let diagnosis = layer.diagnose(entries: entries)

        #expect(diagnosis.hasFailure)
        let disabled = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.backgroundItem })
        #expect(disabled.status == .failed)
        #expect(disabled.detail.contains("登录项与扩展"))
        let agent = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.agentFile })
        #expect(agent.status == .failed)
        let registered = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.agentRegistration })
        #expect(registered.status == .warning)
    }

    @Test func diagnoseReportsLeftoverKeysOfDisabledVariables() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        // 上次同步了 TOOLS 与 OLD；这次 OLD 关了开关，但 gui 域里还留着旧值
        try TestSupport.write(
            SetenvScript.generate(entries: [record("TOOLS", "/opt/tools"), record("OLD", "stale")], label: label),
            to: paths.guiScriptURL
        )
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools"), record("OLD", "stale", gui: false)]
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(exitCode: 0, stdout: "service", stderr: "")
        runner.outcomes[[LaunchAgent.shellPath, paths.guiScriptURL.path, SetenvScript.printFlag]] = ProcessOutcome(
            exitCode: 0, stdout: "TOOLS=/opt/tools\n", stderr: ""
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "TOOLS"]] = ProcessOutcome(exitCode: 0, stdout: "/opt/tools\n", stderr: "")
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "OLD"]] = ProcessOutcome(exitCode: 0, stdout: "stale\n", stderr: "")
        let layer = makeLayer(home: home, paths: paths, runner: runner)

        let diagnosis = layer.diagnose(entries: entries)

        let leftover = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.disabledLeftovers })
        #expect(leftover.status == .warning)
        #expect(leftover.detail.contains("OLD"))
    }

    // MARK: - 清单标题的契约

    /// 空态：没有任何 GUI 层变量，也没装过任何东西。
    private func emptyStateDiagnosis() throws -> GuiDiagnosis {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
        return makeLayer(home: home, paths: paths, runner: runner).diagnose(entries: [])
    }

    /// 健康态：脚本、plist、注册、后台项、注入值、残留逐项通过。
    private func healthyStateDiagnosis() throws -> GuiDiagnosis {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools"), record("JAVA_HOME", "/opt/tools/jdk")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 0, stdout: "service", stderr: ""
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "print-disabled", "gui/501"]] = ProcessOutcome(
            exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"\(label)\" => enabled\n\t}\n", stderr: ""
        )
        let layer = makeLayer(home: home, paths: paths, runner: runner)
        _ = layer.apply(entries: entries)
        return layer.diagnose(entries: entries)
    }

    /// 故障态：脚本在、plist 不在、没注册、后台项被系统设置关掉、gui 域里还是旧值。
    private func faultyStateDiagnosis() throws -> GuiDiagnosis {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools"), record("JAVA_HOME", "/opt/tools/jdk")]
        try TestSupport.write(SetenvScript.generate(entries: entries, label: label), to: paths.guiScriptURL)
        runner.outcomes[[LaunchAgent.shellPath, paths.guiScriptURL.path, SetenvScript.printFlag]] = ProcessOutcome(
            exitCode: 0, stdout: "TOOLS=/opt/tools\nJAVA_HOME=/opt/tools/jdk\n", stderr: ""
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "TOOLS"]] = ProcessOutcome(
            exitCode: 0, stdout: "/opt/tools\n", stderr: ""
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "JAVA_HOME"]] = ProcessOutcome(
            exitCode: 0, stdout: "/opt/old/jdk\n", stderr: ""
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "print-disabled", "gui/501"]] = ProcessOutcome(
            exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"\(label)\" => disabled\n\t}\n", stderr: ""
        )
        return makeLayer(home: home, paths: paths, runner: runner).diagnose(entries: entries)
    }

    /// 标题是清单的行身份（界面以 `name` 作 `id`）：空态、健康态、故障态下都是同一串标题。
    /// 标题只说「在查什么」，不随状态变化——空态才不会读出「标题说已注册、详情说尚未注册」这种矛盾句。
    @Test func diagnosisTitlesAreUniqueAndConstantAcrossStates() throws {
        let empty = try emptyStateDiagnosis()
        let healthy = try healthyStateDiagnosis()
        let faulty = try faultyStateDiagnosis()

        // 三种状态各自成立：空态没有要修的项，健康态全绿，故障态有失败项。
        #expect(empty.isHealthy, "空态不该有需要修的项：\(empty.checks.filter { $0.status != .ok })")
        #expect(healthy.isHealthy, "健康态应当全绿：\(healthy.checks.filter { $0.status != .ok })")
        #expect(faulty.hasFailure, "故障态应当有失败项")

        for (state, diagnosis) in [("空态", empty), ("健康态", healthy), ("故障态", faulty)] {
            let titles = diagnosis.checks.map(\.name)
            #expect(titles == GuiCheckTitle.checklist, "\(state)：固定六行、顺序固定（脚本 → plist → 注册 → 后台项 → 注入值 → 残留）")
            #expect(Set(titles).count == titles.count, "\(state)：标题在同一份诊断里唯一")
        }

        // 后台项契约：含「后台项」三字的标题仍然存在（界面的登录项面板按钮按这个常量判定显示与否）。
        #expect(GuiCheckTitle.backgroundItem.contains("后台项"))
    }

    /// 每一行的详情只说这一行量到的事：agent 缺失时，后台项那一行不能替上面两行宣称「登录时会重放变量」。
    @Test func backgroundItemRowDoesNotSpeakForTheAgentRows() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let entries: [ManagedEntry] = [record("TOOLS", "/opt/tools")]
        _ = stubHappyPath(runner, paths: paths, entries: entries)
        // 开关没被关掉（不在禁用表里），但 plist 不在、也没注册
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(label)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "print-disabled", "gui/501"]] = ProcessOutcome(
            exitCode: 0, stdout: "\tdisabled services = {\n\t\t\"\(label)\" => enabled\n\t}\n", stderr: ""
        )

        let diagnosis = makeLayer(home: home, paths: paths, runner: runner).diagnose(entries: entries)

        let backgroundItem = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.backgroundItem })
        #expect(backgroundItem.status == .ok)
        #expect(!backgroundItem.detail.contains("重放"))
        let agentFile = try #require(diagnosis.checks.first { $0.name == GuiCheckTitle.agentFile })
        #expect(agentFile.detail.contains("登录时不会重放变量"))
    }
}
