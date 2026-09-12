// PROTOTYPE — 变体 B：单栏密集表格（Table）+ 底部状态栏。
// 编辑走弹窗；PATH 弹出全宽编辑表；诊断/备份/重启/收编入口收在底部状态栏。

import SwiftUI

struct VariantB: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var selection: Set<VarRecord.ID> = []
    @State private var editTarget: EditTarget?
    @State private var showPath = false
    @State private var mock: MockSheet?
    @State private var newSheet = false

    struct EditTarget: Identifiable { let id: VarRecord.ID }

    private var filtered: [VarRecord] {
        search.isEmpty
            ? store.records
            : store.records.filter { $0.key.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Table(filtered, selection: $selection) {
                TableColumn("状态") { r in
                    StatusIcon(status: store.status(r))
                }
                .width(46)
                TableColumn("KEY") { r in
                    HStack(spacing: 8) {
                        Text(r.key).fontWeight(r.key == "PATH" ? .semibold : .regular)
                        if r.key == "PATH" {
                            Button("排列条目…") { showPath = true }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                TableColumn("原始值") { r in
                    Text(store.display(r.rawValue, secret: r.secret))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                TableColumn("shell") { r in
                    layerDot(on: r.shellOn, written: r.shellWritten)
                }
                .width(50)
                TableColumn("GUI") { r in
                    layerDot(on: r.guiOn, written: r.guiWritten)
                }
                .width(50)
                TableColumn("来源") { r in
                    Text(r.source.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                .width(80)
            }
            Divider()
            footer
        }
        .navigationTitle("B · 密集表格 + 状态栏")
        .sheet(item: $editTarget) { target in EditSheet(id: target.id) }
        .sheet(isPresented: $showPath) { PathSheet() }
        .sheet(item: $mock) { $0.content }
        .sheet(isPresented: $newSheet) { NewRecordSheet() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索变量", text: $search).textFieldStyle(.plain)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            Spacer()
            Button { newSheet = true } label: { Label("新建", systemImage: "plus") }
            Button {
                if let id = selection.first { editTarget = EditTarget(id: id) }
            } label: { Label("编辑", systemImage: "slider.horizontal.3") }
            .disabled(selection.count != 1)
            Button { store.applyAll() } label: {
                Label(store.pendingCount > 0 ? "应用 (\(store.pendingCount))" : "应用",
                      systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.pendingCount == 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: (store.agentRegistered && store.loginItemEnabled)
                    ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle((store.agentRegistered && store.loginItemEnabled)
                                 ? Color.green : Color.orange)
            Text((store.agentRegistered && store.loginItemEnabled)
                 ? "LaunchAgent 已注册 · 登录项已启用"
                 : "登录项已关闭——登录后不会重放变量")
                .font(.caption)
            Button("诊断…") { mock = .diagnostics }.buttonStyle(.link).font(.caption)
            Divider().frame(height: 12)
            Button("备份与恢复…") { mock = .backup }.buttonStyle(.link).font(.caption)
            Button("重启指定 App…") { mock = .restart }.buttonStyle(.link).font(.caption)
            Button("收编已有配置…") { mock = .collect }.buttonStyle(.link).font(.caption)
            Spacer()
            Text("上次应用：\(store.lastApplied)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func layerDot(on: Bool, written: Bool) -> some View {
        Circle()
            .fill(on ? (written ? Color.green : Color.orange) : Color.gray.opacity(0.35))
            .frame(width: 9, height: 9)
            .help(on ? (written ? "已写入该层" : "待应用") : "该层未启用")
    }
}

struct EditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: VarRecord.ID

    var body: some View {
        VStack(spacing: 12) {
            if let rec = store.records.first(where: { $0.id == id }) {
                RecordFields(record: store.binding(for: id, fallback: rec), lockKey: true)
                Text("「完成」只改内存；回主窗口点「应用」才写入两层。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("记录不存在")
            }
        }
        .padding(16).frame(width: 540)
    }
}

struct PathSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "PATH 专用编辑", icon: "arrow.triangle.branch")
            if let rec = store.pathRecord {
                HStack(spacing: 20) {
                    Toggle("写入 shell 层", isOn: store.binding(for: rec.id, fallback: rec).shellOn)
                    Toggle("写入 GUI 层", isOn: store.binding(for: rec.id, fallback: rec).guiOn)
                    if store.pathDirty {
                        Label("待生效", systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
            Text("拖动行或用 ↑↓ 排序；锚点行 = 继承既有 PATH，用户条目排在锚点之前即为前插。")
                .font(.caption).foregroundStyle(.secondary)
            PathListEditor()
            HStack {
                Text("关闭只改内存；点主窗口「应用」才写入两层。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 640, height: 520)
    }
}
