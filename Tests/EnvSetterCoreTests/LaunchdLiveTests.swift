import Testing
import Foundation
@testable import EnvSetterCore

/// 真机验收（默认不跑）：真的注册一个 LaunchAgent，向当前 gui 域注入变量，再用 `launchctl getenv` 回读。
/// 这是 #7 验收口径的自动化版本——不看脚本，直接问 launchd 要值。
///
/// 会临时改动本机状态，故用独立 label（不会碰到工具自己的 agent）并全部清理：
/// - `launchctl bootstrap` 注册一个指向沙盒脚本的 agent（用完 bootout）
/// - 注入 `ENVSETTER_ACCEPT_*` 变量（用完 unsetenv，不留残留）
///
/// 跑法：`ENVSETTER_LIVE_LAUNCHD=1 swift test --filter LaunchdLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENVSETTER_LIVE_LAUNCHD"] == "1"))
struct LaunchdLiveTests {
    private let label = "com.lautung.env-setter.acceptance"
    private let toolsPath = "/tmp/envsetter-acceptance-tools"
    private var injectedKeys: [String] {
        [
            "ENVSETTER_ACCEPT_TOOLS",
            "ENVSETTER_ACCEPT_JAVA_HOME",
            "ENVSETTER_ACCEPT_LITERAL",
            "ENVSETTER_ACCEPT_SELF",
            "ENVSETTER_ACCEPT_DEFAULT_PATH",
        ]
    }

    private func launchctl(_ arguments: [String]) -> ProcessOutcome {
        SystemProcessRunner().run(executable: LaunchAgent.launchctlPath, arguments: arguments, environment: [:])
    }

    private func getenv(_ key: String) -> String? {
        let value = launchctl(["getenv", key]).stdout.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    private func tearDown(layer: GuiLayer) {
        _ = launchctl(["bootout", "\(layer.domain)/\(label)"])
        for key in injectedKeys { _ = launchctl(["unsetenv", key]) }
    }

    @Test func agentInjectsExpandedValuesAndReadbackMatches() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let layer = GuiLayer(paths: paths, label: label, uid: getuid())
        tearDown(layer: layer)  // 上一轮若留下状态，先清干净
        defer { tearDown(layer: layer) }

        let entries: [ManagedEntry] = [
            .record(VariableRecord(key: "ENVSETTER_ACCEPT_TOOLS", rawValue: toolsPath, guiEnabled: true)),
            .record(
                VariableRecord(
                    key: "ENVSETTER_ACCEPT_JAVA_HOME",
                    rawValue: "$ENVSETTER_ACCEPT_TOOLS/jdk/jdk-21/Contents/Home",
                    guiEnabled: true
                )
            ),
            .record(
                VariableRecord(
                    key: "ENVSETTER_ACCEPT_LITERAL",
                    rawValue: "pa$$word",
                    guiEnabled: true,
                    quoteStyle: .single
                )
            ),
            .record(
                VariableRecord(
                    key: "ENVSETTER_ACCEPT_SELF",
                    rawValue: "-rlogger${ENVSETTER_ACCEPT_SELF:+ $ENVSETTER_ACCEPT_SELF}",
                    guiEnabled: true
                )
            ),
            // 非 PATH 的变量引用 `$PATH`：用来观察 agent 拿到的 PATH 到底是什么
            .record(
                VariableRecord(
                    key: "ENVSETTER_ACCEPT_DEFAULT_PATH",
                    rawValue: "$PATH",
                    guiEnabled: true
                )
            ),
        ]

        let report = layer.apply(entries: entries)
        #expect(report.outcome == .applied, "\(report.warning ?? "")")
        #expect(report.agentInstalled)
        #expect(report.agentRegistered)
        #expect(report.liveSynced)

        // 逐个向 launchd 要值：`$` 引用已按声明顺序展开
        #expect(getenv("ENVSETTER_ACCEPT_TOOLS") == toolsPath)
        #expect(getenv("ENVSETTER_ACCEPT_JAVA_HOME") == "\(toolsPath)/jdk/jdk-21/Contents/Home")
        #expect(getenv("ENVSETTER_ACCEPT_LITERAL") == "pa$$word")
        #expect(getenv("ENVSETTER_ACCEPT_SELF") == "-rlogger")
        let agentPath = getenv("ENVSETTER_ACCEPT_DEFAULT_PATH")
        print("agent 拿到的 PATH = \(agentPath ?? "（空）")")
        #expect(agentPath == LaunchAgent.defaultPath)

        // 诊断全绿：脚本、plist、注册、后台项、注入值逐项通过
        let diagnosis = layer.diagnose(entries: entries)
        #expect(diagnosis.isHealthy, "\(diagnosis.checks.filter { $0.status != .ok })")

        // 关闭一条变量的 GUI 开关：应用后该变量从 gui 域消失（不必等下次登录）
        var trimmed = entries
        trimmed[1] = .record(
            VariableRecord(key: "ENVSETTER_ACCEPT_JAVA_HOME", rawValue: "$ENVSETTER_ACCEPT_TOOLS/jdk", guiEnabled: false)
        )
        let second = layer.apply(entries: trimmed)
        #expect(second.removedKeys == ["ENVSETTER_ACCEPT_JAVA_HOME"])
        #expect(second.outcome == .applied, "\(second.warning ?? "")")
        #expect(getenv("ENVSETTER_ACCEPT_JAVA_HOME") == nil)

        // 重新注册后 agent 自己跑一遍（RunAtLoad）也应当把值放回去：
        // 直接 bootstrap 已验证过 RunAtLoad 会执行脚本，这里确认脚本本身可用同一个 sh 复跑。
        _ = launchctl(["bootout", "\(layer.domain)/\(label)"])
        let reboot = launchctl(["bootstrap", layer.domain, layer.plistURL.path])
        #expect(reboot.succeeded, "\(reboot.message)")
        Thread.sleep(forTimeInterval: 0.5)  // 让 RunAtLoad 跑完
        #expect(getenv("ENVSETTER_ACCEPT_TOOLS") == toolsPath)
        #expect(getenv("ENVSETTER_ACCEPT_LITERAL") == "pa$$word")
    }
}
