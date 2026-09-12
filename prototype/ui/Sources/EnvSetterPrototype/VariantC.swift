// PROTOTYPE — 变体 C：按两层状态分组的状态看板 + 底部工具带。
// 显式应用是第一视觉焦点（顶部横幅）；PATH 固定为顶部卡片；编辑在卡片内展开。

import SwiftUI

struct VariantC: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var expandedID: VarRecord.ID?
    @State private var mock: MockSheet?
    @State private var newSheet = false

    private enum Group { case pending, both, shellOnly, guiOnly, off }

    private func group(_ r: VarRecord) -> Group {
        if r.key == "PATH" { return .both } // PATH 有自己的固定卡片，不进分组
        if store.status(r) == .pending { return .pending }
        switch (r.shellOn, r.guiOn) {
        case (true, true): return .both
        case (true, false): return .shellOnly
        case (false, true): return .guiOnly
        default: return .off
        }
    }

    private func matches(_ r: VarRecord) -> Bool {
        search.isEmpty || r.key.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    if store.pendingCount > 0 { pendingBanner }
                    pathCard
                    section(.pending, "待生效", .orange)
                    section(.both, "两层", .green)
                    section(.shellOnly, "仅 shell", .blue)
                    section(.guiOnly, "仅 GUI", .purple)
                    section(.off, "未启用", .gray)
                }
                .padding(16)
            }
            Divider()
            toolStrip
        }
        .navigationTitle("C · 状态看板 + 工具带")
        .sheet(item: $mock) { $0.content }
        .sheet(isPresented: $newSheet) { NewRecordSheet() }
    }

    private var topBar: some View {
        HStack {
            Text("变量").font(.headline)
            Spacer()
            TextField("搜索变量", text: $search)
                .textFieldStyle(.roundedBorder).frame(width: 220)
            Button { newSheet = true } label: { Label("新建", systemImage: "plus") }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var pendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.pendingCount) 条修改待生效").font(.headline)
                Text("应用后写入两层；只影响之后新启动的 App，已运行的 App 需退出重开")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("应用 (\(store.pendingCount))") { store.applyAll() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.orange.opacity(0.5)))
    }

    private var pathCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("PATH").font(.headline)
                    if store.pathDirty {
                        Label("待生效", systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let rec = store.pathRecord {
                        LayerChips(shellOn: rec.shellOn, guiOn: rec.guiOn,
                                   shellWritten: rec.shellWritten, guiWritten: rec.guiWritten)
                    }
                    Spacer()
                    Text("专用编辑：↑↓ 或拖拽排序").font(.caption).foregroundStyle(.secondary)
                }
                PathListEditor(compact: true)
            }
        }
    }

    private func section(_ g: Group, _ title: String, _ color: Color) -> some View {
        let items = store.records.filter { group($0) == g && matches($0) }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title).font(.headline)
                    Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if items.isEmpty {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(items) { card($0) }
            }
        }
    }

    private func card(_ r: VarRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusIcon(status: store.status(r))
                Text(r.key).font(.body.weight(.semibold))
                LayerChips(shellOn: r.shellOn, guiOn: r.guiOn,
                           shellWritten: r.shellWritten, guiWritten: r.guiWritten)
                Spacer()
                if r.secret {
                    Button {
                        store.showSecrets.toggle()
                    } label: {
                        Image(systemName: store.showSecrets ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(store.showSecrets ? "重新打码" : "显示明文")
                }
                Button(expandedID == r.id ? "收起" : "编辑") {
                    expandedID = expandedID == r.id ? nil : r.id
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Text(store.display(r.rawValue, secret: r.secret))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
            if expandedID == r.id {
                Divider()
                RecordFields(record: store.binding(for: r.id, fallback: r), lockKey: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var toolStrip: some View {
        HStack(spacing: 18) {
            Button { mock = .collect } label: { Label("收编已有配置", systemImage: "square.and.arrow.down.on.square") }
                .buttonStyle(.borderless)
            Button { mock = .backup } label: { Label("备份与恢复", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
            Button { mock = .restart } label: { Label("重启指定 App", systemImage: "arrow.clockwise.circle") }
                .buttonStyle(.borderless)
            Button { mock = .diagnostics } label: { Label("诊断", systemImage: "stethoscope") }
                .buttonStyle(.borderless)
            Spacer()
            Text("上次应用：\(store.lastApplied)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
