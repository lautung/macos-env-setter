// PROTOTYPE — in-memory sample data + simulated actions. No persistence.

import SwiftUI

enum SourceKind: String {
    case created = "工具创建"
    case imported = "导入"
}

struct VarRecord: Identifiable, Equatable {
    enum Status { case pending, synced, off }

    var id = UUID()
    var key: String
    var rawValue: String
    var shellOn: Bool
    var guiOn: Bool
    var source: SourceKind
    var shellWritten = false
    var guiWritten = false
    var secret = false
    var pending = false

    var status: Status {
        if pending { return .pending }
        let anyOn = shellOn || guiOn
        let written = (shellOn ? shellWritten : true) && (guiOn ? guiWritten : true)
        return anyOn && written ? .synced : .off
    }
}

struct PathEntry: Identifiable, Equatable {
    enum Kind { case anchor, user }
    var id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
final class Store: ObservableObject {
    @Published var records: [VarRecord] = []
    @Published var pathEntries: [PathEntry] = []
    @Published var pathDirty = false
    @Published var showSecrets = false
    @Published var banner: String?
    @Published var lastApplied = "今天 14:32"
    @Published var agentRegistered = true
    @Published var loginItemEnabled = true

    init() {
        records = [
            VarRecord(key: "PATH",
                      rawValue: "/Users/lautung/bin:/opt/homebrew/bin:$PATH:/usr/local/bin",
                      shellOn: true, guiOn: true, source: .created,
                      shellWritten: true, guiWritten: true),
            VarRecord(key: "JAVA_HOME", rawValue: "/opt/homebrew/opt/openjdk@21",
                      shellOn: true, guiOn: true, source: .created,
                      shellWritten: true, guiWritten: true),
            VarRecord(key: "HTTP_PROXY", rawValue: "http://127.0.0.1:7890",
                      shellOn: true, guiOn: true, source: .created,
                      shellWritten: true, guiWritten: true, pending: true),
            VarRecord(key: "GOPATH", rawValue: "$HOME/go",
                      shellOn: true, guiOn: true, source: .imported,
                      shellWritten: true, guiWritten: true),
            VarRecord(key: "EDITOR", rawValue: "nvim",
                      shellOn: true, guiOn: false, source: .imported,
                      shellWritten: true, guiWritten: false),
            VarRecord(key: "OPENAI_API_KEY", rawValue: "sk-proj-9f3a81c7d2e5b40a",
                      shellOn: false, guiOn: true, source: .created,
                      shellWritten: false, guiWritten: true, secret: true),
            VarRecord(key: "GITHUB_TOKEN", rawValue: "ghp_1a2b3c4d5e6f7g8h",
                      shellOn: true, guiOn: true, source: .imported,
                      shellWritten: true, guiWritten: true, secret: true),
            VarRecord(key: "MY_TOOL_HOME", rawValue: "~/tools/mytool",
                      shellOn: false, guiOn: false, source: .imported),
        ]
        pathEntries = [
            PathEntry(kind: .user, text: "/Users/lautung/bin"),
            PathEntry(kind: .user, text: "/opt/homebrew/bin"),
            PathEntry(kind: .anchor, text: "$PATH"),
            PathEntry(kind: .user, text: "/usr/local/bin"),
            PathEntry(kind: .user, text: "/opt/homebrew/bin"),
        ]
    }

    var pathRecord: VarRecord? { records.first { $0.key == "PATH" } }

    var pendingCount: Int {
        records.filter { $0.pending && $0.key != "PATH" }.count + (pathDirty ? 1 : 0)
    }

    func status(_ r: VarRecord) -> VarRecord.Status {
        if r.key == "PATH" && pathDirty { return .pending }
        return r.status
    }

    func display(_ value: String, secret: Bool) -> String {
        secret && !showSecrets ? String(value.prefix(4)) + "••••••••" : value
    }

    func markPending(_ id: VarRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if records[i].key == "PATH" {
            pathDirty = true
        } else {
            records[i].pending = true
        }
    }

    func binding(for id: VarRecord.ID, fallback: VarRecord) -> Binding<VarRecord> {
        Binding(
            get: { self.records.first { $0.id == id } ?? fallback },
            set: { newValue in
                if let i = self.records.firstIndex(where: { $0.id == id }) {
                    self.records[i] = newValue
                    self.markPending(id)
                }
            }
        )
    }

    func applyAll() {
        for i in records.indices where records[i].pending {
            records[i].shellWritten = records[i].shellOn
            records[i].guiWritten = records[i].guiOn
            records[i].pending = false
        }
        pathDirty = false
        lastApplied = Date().formatted(date: .omitted, time: .shortened)
        banner = "已写入两层（~/.zprofile 标记块 + LaunchAgent setenv.sh）。只影响之后新启动的 App——已运行的 App 需退出重开。"
    }

    func add(key: String, value: String, shell: Bool, gui: Bool, secret: Bool) {
        records.append(VarRecord(key: key, rawValue: value, shellOn: shell, guiOn: gui,
                                 source: .created, secret: secret, pending: true))
        banner = "已添加 \(key)（待生效）——点「应用」才写入两层。"
    }

    // MARK: PATH editor

    var pathDuplicateIDs: Set<PathEntry.ID> {
        let users = pathEntries.filter { $0.kind == .user && !$0.text.isEmpty }
        let grouped = Dictionary(grouping: users) { $0.text.lowercased() }
        return Set(grouped.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }

    func movePath(from: IndexSet, to: Int) {
        pathEntries.move(fromOffsets: from, toOffset: to)
        pathDirty = true
    }

    func nudgePath(_ id: PathEntry.ID, delta: Int) {
        guard let i = pathEntries.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard pathEntries.indices.contains(j) else { return }
        pathEntries.swapAt(i, j)
        pathDirty = true
    }

    func removePath(_ id: PathEntry.ID) {
        pathEntries.removeAll { $0.id == id }
        pathDirty = true
    }

    func addPath(_ text: String) {
        pathEntries.append(PathEntry(kind: .user, text: text))
        pathDirty = true
    }

    // MARK: simulated auxiliary actions

    func restart(app: String) {
        banner = "已请求退出并重启 \(app)（原型模拟）——新进程将读到 GUI 层最新值。"
    }

    func collected(n: Int) {
        banner = "已收编 \(n) 条：原行已注释、记录已入列表（原型模拟）。"
    }

    func restored(file: String) {
        banner = "已从「\(file)」恢复标记块并重新载入（原型模拟）。"
    }

    func regenerateAgent() {
        banner = "已重新生成 setenv.sh 并重新注册 LaunchAgent（原型模拟）。"
    }
}
