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
/// 两条测试共用一个 label，故串行跑（`.serialized`）：并行会抢同一个注册。
///
/// 夹具分两种，因为**本工具自己启用 GUI 层之后，gui 域里就有它注入的 PATH 了**（本机常态，不是外来状态）：
/// 回读自检与诊断用不依赖环境的取值，`$PATH` 锚点单独观察一条。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENVSETTER_LIVE_LAUNCHD"] == "1"))
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

    /// 域里的 PATH——agent 启动时继承到的就是它（脚本不写 PATH）。
    ///
    /// 不能写死 `LaunchAgent.defaultPath`：那是「gui 域里还没人设过 PATH」时的观察值，不是契约。
    /// 契约是「脚本里的 `$PATH` 解析成 agent 继承到的 PATH」——域里没有 PATH 时它才等于 launchd 的默认值。
    private func guiDomainPath() -> String {
        getenv("PATH") ?? LaunchAgent.defaultPath
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

        // 取值都不依赖环境：agent 继承到的环境与 `GuiLayer.launchdLikeEnvironment` 算期望值用的环境
        // 在这些 key 上一致，回读自检与诊断才断言得起。
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
        // 先把值清掉再重注册——值还在的话，下面两条断言就算 agent 没跑也成立。
        for key in ["ENVSETTER_ACCEPT_TOOLS", "ENVSETTER_ACCEPT_LITERAL"] {
            _ = launchctl(["unsetenv", key])
        }
        reRegisterAgent(layer)
        waitUntil {
            getenv("ENVSETTER_ACCEPT_TOOLS") == toolsPath && getenv("ENVSETTER_ACCEPT_LITERAL") == "pa$$word"
        }
        #expect(getenv("ENVSETTER_ACCEPT_TOOLS") == toolsPath)
        #expect(getenv("ENVSETTER_ACCEPT_LITERAL") == "pa$$word")
    }

    /// GUI 层的 `$PATH` 锚点解析成 **agent 进程继承到的 PATH**，不是终端里的 PATH。
    ///
    /// 本机 gui 域里已经有本工具注入的 PATH（它自己写的），agent 继承到的通常**不是** launchd 的默认 PATH。
    @Test func pathAnchorResolvesToThePathTheAgentInherits() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let layer = GuiLayer(paths: paths, label: label, uid: getuid())
        tearDown(layer: layer)
        defer { tearDown(layer: layer) }

        let entries: [ManagedEntry] = [
            .record(VariableRecord(key: "ENVSETTER_ACCEPT_DEFAULT_PATH", rawValue: "$PATH", guiEnabled: true))
        ]

        let inherited = guiDomainPath()
        print("agent 继承到的 PATH = \(inherited)")

        _ = layer.apply(entries: entries)
        // 让 agent 自己跑一遍：它继承的是 gui 域的实时环境，而 apply 的即时注入用的是固定的
        // launchd-like 环境（见 `GuiLayer.launchdLikeEnvironment`）——这一条要看的正是两者的差别。
        // 先把值清掉再重注册：域里没有 PATH 的机器上两个环境算出的是同一个默认 PATH，
        // 值还在的话这条断言就算 agent 没跑也成立。
        _ = launchctl(["unsetenv", "ENVSETTER_ACCEPT_DEFAULT_PATH"])
        reRegisterAgent(layer)
        waitUntil { getenv("ENVSETTER_ACCEPT_DEFAULT_PATH") == inherited }
        #expect(getenv("ENVSETTER_ACCEPT_DEFAULT_PATH") == inherited)
    }
}
