// PROTOTYPE — 变体 A：侧栏列表 + 右侧详情表单（NavigationSplitView）。
// PATH 在详情区就地展开专用编辑器；备份/收编/诊断/重启入口收在侧栏「工具」区。

import SwiftUI

struct VariantA: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var selection: VarRecord.ID?
    @State private var mock: MockSheet?
    @State private var newSheet = false

    private var filtered: [VarRecord] {
        search.isEmpty
            ? store.records
            : store.records.filter { $0.key.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    TextField("搜索变量", text: $search).textFieldStyle(.roundedBorder)
                }
                Section("变量") {
                    ForEach(filtered) { r in
                        HStack(spacing: 8) {
                            StatusIcon(status: store.status(r))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.key).fontWeight(r.key == "PATH" ? .semibold : .regular)
                                Text(store.display(r.rawValue, secret: r.secret))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            LayerChips(shellOn: r.shellOn, guiOn: r.guiOn,
                                       shellWritten: r.shellWritten, guiWritten: r.guiWritten)
                        }
                        .tag(r.id)
                    }
                }
                Section("工具") {
                    Button { mock = .collect } label: {
                        Label("收编已有配置…", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button { mock = .backup } label: {
                        Label("备份与恢复…", systemImage: "clock.arrow.circlepath")
                    }
                    Button { mock = .restart } label: {
                        Label("重启指定 App…", systemImage: "arrow.clockwise.circle")
                    }
                    Button { mock = .diagnostics } label: {
                        Label("诊断 LaunchAgent…", systemImage: "stethoscope")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detailPane
        }
        .navigationTitle("A · 侧栏 + 详情")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { newSheet = true } label: {
                    Label("新建变量", systemImage: "plus")
                }
                Button { store.applyAll() } label: {
                    Label(store.pendingCount > 0 ? "应用 (\(store.pendingCount))" : "应用",
                          systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.pendingCount == 0)
                .help("显式应用：先备份，再一次性写入两层")
            }
        }
        .sheet(item: $mock) { $0.content }
        .sheet(isPresented: $newSheet) { NewRecordSheet() }
    }

    @ViewBuilder private var detailPane: some View {
        if let id = selection, let rec = store.records.first(where: { $0.id == id }) {
            if rec.key == "PATH" {
                PathDetailA(record: rec)
            } else {
                RecordDetailA(record: rec)
            }
        } else {
            ContentUnavailableView("选择一个变量", systemImage: "list.bullet.rectangle",
                                   description: Text("左侧选择变量查看与编辑，或新建一条。"))
        }
    }
}

struct RecordDetailA: View {
    @EnvironmentObject var store: Store
    let record: VarRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    StatusIcon(status: store.status(record))
                    Text(record.key).font(.title2.weight(.semibold))
                    Spacer()
                    Text("编辑只改内存；点工具栏「应用」才落盘").font(.caption).foregroundStyle(.secondary)
                }
                RecordFields(record: store.binding(for: record.id, fallback: record), lockKey: true)
                Label("「待生效」= 修改还在内存里。应用会先备份再写 ~/.zprofile 标记块与 LaunchAgent；写入只影响之后新启动的 App，已运行的 App 需退出重开（可用侧栏「重启指定 App」）。",
                      systemImage: "lightbulb")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct PathDetailA: View {
    @EnvironmentObject var store: Store
    let record: VarRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    StatusIcon(status: store.status(record))
                    Text("PATH").font(.title2.weight(.semibold))
                    Spacer()
                    LayerChips(shellOn: record.shellOn, guiOn: record.guiOn,
                               shellWritten: record.shellWritten, guiWritten: record.guiWritten)
                }
                HStack(spacing: 20) {
                    Toggle("写入 shell 层", isOn: store.binding(for: record.id, fallback: record).shellOn)
                    Toggle("写入 GUI 层", isOn: store.binding(for: record.id, fallback: record).guiOn)
                    Spacer()
                }
                Text("拖动行或用 ↑↓ 排序；锚点行 = 继承既有 PATH，用户条目排在锚点之前即为前插。")
                    .font(.caption).foregroundStyle(.secondary)
                PathListEditor()
            }
            .padding(24)
        }
    }
}
