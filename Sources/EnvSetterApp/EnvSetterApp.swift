import EnvSetterCore
import EnvSetterUI
import SwiftUI

/// v1 的正式入口：SwiftUI 窗口应用。核心逻辑在 `EnvSetterCore`，界面状态与视图在 `EnvSetterUI`。
/// 本地构建、不签名、不沙盒（要写 ~/.zprofile 与 ~/Library/LaunchAgents）。
@main
struct EnvSetterApp: App {
    @StateObject private var model: AppModel

    init() {
        let paths = EnginePaths.standard()
        _model = StateObject(
            wrappedValue: AppModel(engine: EnvSetterEngine(paths: paths, gui: GuiLayer(paths: paths)))
        )
    }

    var body: some Scene {
        Window("EnvSetter", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建变量") { model.sheet = .newRecord }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .saveItem) {
                Button("应用（写入两层）") { Task { await model.apply() } }
                    .keyboardShortcut("s")
                    .disabled(!model.canApply)
                Button("重新载入") { model.requestReload() }
                    .keyboardShortcut("r")
            }
        }
    }
}
