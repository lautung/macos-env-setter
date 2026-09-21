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

    func run(executable: String, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        return outcomes[[executable] + arguments] ?? defaultOutcome
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

        // 只有 shell 层变量：不装 agent，也不碰 gui 域
        let report = layer.apply(entries: [record("TOOLS", "/opt/tools", gui: false)])

        #expect(report.outcome == .skipped)
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: layer.plistURL.path))
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
        #expect(diagnosis.checks.map(\.name).contains("值已注入当前会话"))
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
        let disabled = try #require(diagnosis.checks.first { $0.name == "后台项未被禁用" })
        #expect(disabled.status == .failed)
        #expect(disabled.detail.contains("登录项与扩展"))
        let agent = try #require(diagnosis.checks.first { $0.name == "LaunchAgent" })
        #expect(agent.status == .failed)
        let registered = try #require(diagnosis.checks.first { $0.name == "agent 已注册" })
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

        let leftover = try #require(diagnosis.checks.first { $0.name == "无已关闭变量的残留" })
        #expect(leftover.status == .warning)
        #expect(leftover.detail.contains("OLD"))
    }
}
