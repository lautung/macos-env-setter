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
///
/// 夹具里的 `$PATH` 取值与回读自检同处一条测试：plist 给 agent 钉住了 PATH（见 `LaunchAgent.plistData`），
/// 所以「agent 重放」与「应用时即时注入」按同一个基线算，期望值对两个写入者都成立——本机 gui 域里
/// 已有本工具注入的 PATH 也不影响。
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

    /// 重新注册，让 agent 自己跑一遍脚本（`RunAtLoad`）。
    private func reRegisterAgent(_ layer: GuiLayer) {
        _ = launchctl(["bootout", "\(layer.domain)/\(label)"])
        let reboot = launchctl(["bootstrap", layer.domain, layer.plistURL.path])
        #expect(reboot.succeeded, "\(reboot.message)")
    }

    /// 轮询等 agent 的 RunAtLoad 跑完：固定 sleep 是在赌时序。
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            Thread.sleep(forTimeInterval: 0.1)
        }
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
            // 非 PATH 的变量引用 `$PATH`：观察 `$PATH` 锚点在这一层解析成什么
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
        // `$PATH` 锚点 = launchd 的默认 PATH（agent 的 PATH 由 plist 钉住，与域里已有的 PATH 无关），
        // 不是终端里的 PATH。
        #expect(getenv("ENVSETTER_ACCEPT_DEFAULT_PATH") == LaunchAgent.defaultPath)

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

        // 重新注册后 agent 自己跑一遍（RunAtLoad）会把值放回来。
        // 先把值清掉再重注册——值还在的话，下面的断言就算 agent 没跑也成立。
        // `ENVSETTER_ACCEPT_DEFAULT_PATH` 一并清掉：它由 agent 重放时算出，必须仍是 launchd 的默认 PATH。
        // 这条的鉴别力取决于「域里的 PATH 不是默认值」——本工具启用 GUI 层后就是如此；域里没有 PATH 时
        // 钉不钉住算出的都是默认值，那种机器上「plist 确实钉住了」由 `LaunchAgentTests` 的单测保证。
        for key in ["ENVSETTER_ACCEPT_TOOLS", "ENVSETTER_ACCEPT_LITERAL", "ENVSETTER_ACCEPT_DEFAULT_PATH"] {
            _ = launchctl(["unsetenv", key])
        }
        reRegisterAgent(layer)
        waitUntil {
            getenv("ENVSETTER_ACCEPT_TOOLS") == toolsPath
                && getenv("ENVSETTER_ACCEPT_LITERAL") == "pa$$word"
                && getenv("ENVSETTER_ACCEPT_DEFAULT_PATH") == LaunchAgent.defaultPath
        }
        #expect(getenv("ENVSETTER_ACCEPT_TOOLS") == toolsPath)
        #expect(getenv("ENVSETTER_ACCEPT_LITERAL") == "pa$$word")
        #expect(getenv("ENVSETTER_ACCEPT_DEFAULT_PATH") == LaunchAgent.defaultPath)
    }
}
