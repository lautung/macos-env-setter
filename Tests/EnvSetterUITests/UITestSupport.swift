import EnvSetterCore
import EnvSetterUI
import Foundation
import Testing

enum UITestSupport {
    static func makeSandbox() throws -> (home: URL, paths: EnginePaths) {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "envsetter-ui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, EnginePaths.sandboxed(home: home))
    }

    @discardableResult
    static func write(_ content: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// 块外手写 export 的合成夹具（与真实 ~/.zprofile 同构：变量互引用 + 两条 PATH 行）。
    static let adoptionFile = """
    export TOOLS="/Users/tester/tools"
    export JAVA_HOME="$TOOLS/jdk-21"
    export GITHUB_TOKEN="ghp_1a2b3c4d5e6f7g8h"
    export PATH="$TOOLS/bin:$PATH"

    # OpenCode CLI
    export PATH="/Users/tester/.opencode/bin:$PATH"
    """
}

/// 记录调用、按「可执行文件 + 参数」回答的假执行器：让 GUI 层流程在测试里可断言。
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
    }

    private(set) var calls: [Call] = []
    var outcomes: [[String]: ProcessOutcome] = [:]
    var defaultOutcome = ProcessOutcome(exitCode: 0, stdout: "", stderr: "")

    func run(executable: String, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        calls.append(Call(executable: executable, arguments: arguments))
        return outcomes[[executable] + arguments] ?? defaultOutcome
    }
}

@MainActor
final class FakeAppController: AppController {
    var apps: [RunningApp] = []
    /// 非 nil 时 restart 返回这段失败说明。
    var restartFailure: String?
    private(set) var restarted: [RunningApp] = []
    private(set) var openedLoginItemsSettings = false

    func runningApps() -> [RunningApp] { apps }

    func restart(_ app: RunningApp) async -> String? {
        restarted.append(app)
        return restartFailure
    }

    func openLoginItemsSettings() { openedLoginItemsSettings = true }
}

/// 一套沙盒 + 模型：界面测试的统一起点。
@MainActor
struct Harness {
    let home: URL
    let paths: EnginePaths
    let runner: FakeProcessRunner
    let apps: FakeAppController
    let engine: EnvSetterEngine
    let model: AppModel

    /// `gui: false` 时引擎不接 GUI 层（只写 shell 层）。
    init(gui: Bool = true) throws {
        let sandbox = try UITestSupport.makeSandbox()
        home = sandbox.home
        paths = sandbox.paths
        runner = FakeProcessRunner()
        apps = FakeAppController()
        engine =
            gui
            ? EnvSetterEngine(
                paths: sandbox.paths,
                gui: GuiLayer(
                    paths: sandbox.paths,
                    runner: runner,
                    environment: ["HOME": sandbox.home.path, "PATH": LaunchAgent.defaultPath],
                    uid: 501
                )
            )
            : EnvSetterEngine(paths: sandbox.paths)
        model = AppModel(engine: engine, apps: apps)
    }

    func writeProfile(_ content: String) throws {
        try UITestSupport.write(content, to: paths.zprofileURL)
    }

    var profileContent: String {
        get throws { try UITestSupport.read(paths.zprofileURL) }
    }

    func storedEntries() throws -> [ManagedEntry] {
        try StorePersistence.load(from: paths.storeURL).entries
    }

    /// 造一条已应用的记录：走真实的「编辑 → 应用」路径，而不是直接写状态。
    func addApplied(_ key: String, _ value: String, shell: Bool = true, gui: Bool = false) async {
        model.addRecord(key: key, rawValue: value, shellEnabled: shell, guiEnabled: gui, secret: false)
        await model.apply()
    }
}
