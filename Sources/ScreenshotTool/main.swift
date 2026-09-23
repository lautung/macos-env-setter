// 生成 README 用的界面截图。
//
// 由 Scripts/make-screenshots.sh 调用（它负责把本工具包成临时 .app 再启动——见那个脚本里的说明）。
//
// 做法：把**真实视图**（EnvSetterUI 的 `MainWindow`）套进一个窗口，喂一份合成数据
// （`~/.envsetter-demo` 沙盒，跑完由脚本删掉），再把窗口自己的合成结果抓下来。
// 因此：不碰真实 `~/.zprofile`、不需要屏幕录制权限、也不可能把用户的变量截进图里。
//
// 抓图用 `CGWindowListCreateImage` 抓**自己**的窗口——它走窗口服务器的合成结果，图层、材质、
// 强调色都在（`cacheDisplay` 只走 drawRect，会把 `.borderedProminent` 的填充与侧栏材质画丢）。
// 抓自己的窗口不需要任何授权；抓别人的窗口才需要。

import AppKit
import EnvSetterCore
import EnvSetterUI
import SwiftUI

/// 假执行器：演示里所有 `launchctl` / `sh` 调用都不落地（真跑会动到本机的 gui 域）。
private final class DemoRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
    }
}

private func log(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

/// 演示数据：全是编出来的，键名与路径都一眼看得出不是真的。
/// 刻意留成「待生效」——那正是 README 要讲的事（编辑只改内存，点「应用」才落盘）。
@MainActor
private func makeDemoModel() async throws -> AppModel {
    let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".envsetter-demo")
    try? FileManager.default.removeItem(at: home)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let paths = EnginePaths.sandboxed(home: home)

    // 块外留一行手写配置，让侧栏/详情里的「块外内容工具永不触碰」有东西可指。
    try Data("""
    # 我自己手写的
    export EDITOR=vim

    """.utf8).write(to: paths.zprofileURL)

    let engine = EnvSetterEngine(
        paths: paths,
        gui: GuiLayer(
            paths: paths,
            runner: DemoRunner(),
            environment: ["HOME": home.path, "PATH": LaunchAgent.defaultPath],
            uid: getuid()
        )
    )
    let model = AppModel(engine: engine)
    await model.start()

    model.addRecord(
        key: "JAVA_HOME", rawValue: "/opt/demo/jdk-21",
        shellEnabled: true, guiEnabled: true, secret: false
    )
    model.addRecord(
        key: "MAVEN_HOME", rawValue: "$JAVA_HOME/maven",
        shellEnabled: true, guiEnabled: true, secret: false
    )
    model.addRecord(
        key: "ANDROID_HOME", rawValue: "/opt/demo/android-sdk",
        shellEnabled: true, guiEnabled: false, secret: false
    )
    model.addRecord(
        key: "NPM_CONFIG_REGISTRY", rawValue: "https://registry.example.com/",
        shellEnabled: true, guiEnabled: true, secret: false
    )
    model.addRecord(
        key: "DEMO_API_KEY", rawValue: "sk-demo-0000000000000000",
        shellEnabled: true, guiEnabled: true, secret: true
    )
    model.addRecord(
        key: "PATH", rawValue: "/opt/demo/bin:/opt/demo/tools/bin:$PATH",
        shellEnabled: true, guiEnabled: true, secret: false
    )
    return model
}

@MainActor
private func makeWindow(model: AppModel, appearance: NSAppearance.Name) -> (NSWindow, NSHostingView<MainWindow>) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.appearance = NSAppearance(named: appearance)

    let hosting = NSHostingView(rootView: MainWindow(model: model))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "EnvSetter"
    window.contentView = hosting
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    return (window, hosting)
}

/// 抓窗口自己的合成结果；`cacheDisplay` 只作退路。
@MainActor
private func capture(_ window: NSWindow, _ hosting: NSView, settle: TimeInterval, to url: URL) throws {
    RunLoop.current.run(until: Date().addingTimeInterval(settle))
    hosting.layoutSubtreeIfNeeded()

    var rep: NSBitmapImageRep?
    let id = CGWindowID(window.windowNumber)
    if id > 0,
        let shot = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]
        )
    {
        rep = NSBitmapImageRep(cgImage: shot)
    } else {
        log("⚠️  抓不到窗口合成结果，退回 cacheDisplay（材质与强调色会失真）")
        let frame = hosting.superview ?? hosting
        guard let fallback = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            throw NSError(domain: "screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "拿不到位图"])
        }
        frame.cacheDisplay(in: frame.bounds, to: fallback)
        rep = fallback
    }
    let image = rep!
    try image.representation(using: .png, properties: [:])!.write(to: url)
    log("已写出 \(url.lastPathComponent)（\(image.pixelsWide)x\(image.pixelsHigh)）")
}

@MainActor
private func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: environment["SHOT_DIR"] ?? FileManager.default.currentDirectoryPath)
    let dark = environment["SHOT_APPEARANCE"] == "dark"
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let model = try await makeDemoModel()
    let (window, hosting) = makeWindow(model: model, appearance: dark ? .darkAqua : .aqua)

    model.select("JAVA_HOME")
    try capture(window, hosting, settle: 2.0, to: directory.appending(path: "main-window.png"))

    model.select("PATH")
    try capture(window, hosting, settle: 1.0, to: directory.appending(path: "path-editor.png"))
}

try await run()
exit(0)
