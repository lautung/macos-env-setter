import EnvSetterCore
import SwiftUI

/// 主窗口：侧栏（变量列表 + 工具入口）+ 详情（编辑表单 / PATH 编辑器）。
public struct MainWindow: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            DetailPane(model: model)
        }
        .navigationTitle("EnvSetter")
        .navigationSubtitle(model.zprofileLabel)
        .toolbar { toolbar }
        .overlay(alignment: .top) { bannerOverlay }
        .sheet(item: $model.sheet) { sheet in sheetContent(sheet) }
        .alert(dialogTitle, isPresented: dialogBinding, presenting: model.dialog) { dialog in
            dialogButtons(dialog)
        } message: { dialog in
            Text(dialog.message)
        }
        .task { await model.start() }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let label = model.busyLabel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                model.sheet = .newRecord
            } label: {
                Label("新建变量", systemImage: "plus")
            }
            .disabled(model.isBusy)
            .help("新建一条变量（⌘N）")

            Button {
                model.requestReload()
            } label: {
                Label("重新载入", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isBusy)
            .help("以 \(model.zprofileLabel) 为准重新载入（⌘R）")

            Button {
                Task { await model.apply() }
            } label: {
                Label(model.pendingCount > 0 ? "应用 (\(model.pendingCount))" : "应用", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApply)
            .help(applyHelp)
        }
    }

    private var applyHelp: String {
        if !model.validationIssues.isEmpty {
            return "有 \(model.validationIssues.count) 处需要先修正（见列表里的红色标记）"
        }
        var text = "显式应用：先备份，再一次性写入 \(model.zprofileLabel) 标记块与 GUI 层。只影响之后新启动的 App。"
        if let last = model.lastAppliedText {
            text += "（本次会话上次应用：\(last)）"
        }
        return text
    }

    // MARK: - 横幅

    @ViewBuilder private var bannerOverlay: some View {
        if let banner = model.banner {
            BannerView(banner: banner) { model.banner = nil }
                .padding(.top, 10)
                .task(id: banner.id) {
                    // 信息类自己退场；警告类留着，等用户看明白了再关。
                    guard banner.kind == .info else { return }
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    if model.banner?.id == banner.id { model.banner = nil }
                }
        }
    }

    // MARK: - 面板

    @ViewBuilder private func sheetContent(_ sheet: AppModel.Sheet) -> some View {
        switch sheet {
        case .newRecord:
            NewRecordSheet(model: model)
        case .adoption:
            if let plan = model.adoptionPlan {
                AdoptionSheet(model: model, plan: plan)
            } else {
                EmptyPane(icon: "square.and.arrow.down.on.square", title: "没有可收编的内容", message: "请重新执行收编。")
                    .frame(width: 420, height: 240)
            }
        case .backups:
            BackupSheet(model: model)
        case .restart:
            RestartSheet(model: model)
        case .diagnostics:
            DiagnosticsSheet(model: model)
        }
    }

    // MARK: - 确认与错误

    private var dialogTitle: String { model.dialog?.title ?? "" }

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { model.dialog != nil },
            set: { presented in
                if !presented { model.dismissDialog() }
            }
        )
    }

    @ViewBuilder private func dialogButtons(_ dialog: Dialog) -> some View {
        if let confirmTitle = dialog.confirmTitle {
            Button(confirmTitle, role: dialog.isDestructive ? .destructive : nil) {
                Task { await model.perform(dialog) }
            }
            Button("取消", role: .cancel) { model.dismissDialog() }
        } else {
            Button("好", role: .cancel) { model.dismissDialog() }
        }
    }
}
