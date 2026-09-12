// PROTOTYPE — small shared atoms, the record/PATH editors, mock sheets,
// and the floating variant switcher. Layouts live in the variant files.

import SwiftUI

// MARK: - Variant switcher (floating bottom bar)

struct PrototypeSwitcher: View {
    @Binding var index: Int
    let names: [String]

    var body: some View {
        HStack(spacing: 12) {
            Button { cycle(-1) } label: { Image(systemName: "chevron.left") }
            VStack(spacing: 1) {
                Text(names[index]).font(.callout.weight(.semibold))
                Text("← → 切换变体（输入框内无效）").font(.caption2).foregroundStyle(.secondary)
            }
            Button { cycle(1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.gray.opacity(0.3)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .buttonStyle(.bordered)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func cycle(_ d: Int) { index = (index + d + names.count) % names.count }
}

// MARK: - Status atoms

struct StatusIcon: View {
    let status: VarRecord.Status

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .help("待生效：修改尚未应用")
        case .synced:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("所有启用的层均已写入")
        case .off:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .help("未启用任何层，不写入")
        }
    }
}

struct LayerChips: View {
    let shellOn: Bool, guiOn: Bool, shellWritten: Bool, guiWritten: Bool

    var body: some View {
        HStack(spacing: 4) {
            chip("shell", on: shellOn, written: shellWritten)
            chip("GUI", on: guiOn, written: guiWritten)
        }
    }

    private func chip(_ label: String, on: Bool, written: Bool) -> some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(on ? (written ? Color.green.opacity(0.18) : Color.orange.opacity(0.25))
                           : Color.gray.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? (written ? Color.green : Color.orange) : Color.secondary)
            .help(on ? (written ? "已写入该层" : "计划写入该层，待应用") : "该层未启用")
    }
}

// MARK: - Record edit fields (embedded differently by each variant)

struct RecordFields: View {
    @EnvironmentObject var store: Store
    @Binding var record: VarRecord
    var lockKey = false
    @State private var revealThis = false

    var body: some View {
        Form {
            TextField("变量名 KEY", text: $record.key)
                .disabled(lockKey)
            HStack(alignment: .firstTextBaseline) {
                if record.secret && !revealThis && !store.showSecrets {
                    Text(String(record.rawValue.prefix(4)) + "••••••••")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button { revealThis = true } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help("临时显示一次")
                } else {
                    TextField("原始值（保留 $ 引用原文，不预展开）", text: $record.rawValue)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("秘密值（打码显示）", isOn: $record.secret).toggleStyle(.checkbox)
            }
            Section("作用层（各自独立开关）") {
                Toggle("shell 层 — 写入 ~/.zprofile 标记块", isOn: $record.shellOn)
                Toggle("GUI 层 — 写入 launchctl（Dock/Finder/Spotlight 启动的 App）", isOn: $record.guiOn)
            }
            Section("写入状态") {
                LabeledContent("来源") { Text(record.source.rawValue) }
                statusLine
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        let st = store.status(record)
        HStack(spacing: 8) {
            StatusIcon(status: st)
            switch st {
            case .pending:
                Text("待生效 — 修改仅在内存；点「应用」才写入两层，写入后只影响之后新启动的进程")
                    .font(.caption).foregroundStyle(.orange)
            case .synced:
                Text("所有启用的层均已写入").font(.caption).foregroundStyle(.secondary)
            case .off:
                Text("未启用任何层，不写入").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - PATH list editor (List + drag in full mode, plain rows in compact)

struct PathListEditor: View {
    @EnvironmentObject var store: Store
    var compact = false
    @State private var newText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact { compactRows } else { fullList }
            if !store.pathDuplicateIDs.isEmpty { duplicateWarning }
            HStack {
                TextField("添加条目（目录或 $引用）", text: $newText)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    store.addPath(newText.trimmingCharacters(in: .whitespaces))
                    newText = ""
                }
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("写入时按此顺序展开：shell 层 → export PATH=…；GUI 层 → launchctl setenv PATH。锚点 $PATH 展开为继承的既有 PATH。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fullList: some View {
        List {
            ForEach(store.pathEntries) { row($0) }
                .onMove { store.movePath(from: $0, to: $1) }
        }
        .listStyle(.inset)
        .frame(minHeight: 200)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.25)))
    }

    private var compactRows: some View {
        VStack(spacing: 4) {
            ForEach(store.pathEntries) { row($0) }
        }
    }

    private func row(_ entry: PathEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            if entry.kind == .anchor {
                Text("$PATH — 锚点（继承既有 PATH）")
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .help("用户条目排在锚点之前 = 前插；之后 = 追加。GUI 层此处展开为 launchd 默认 PATH。")
            } else {
                Text(entry.text).font(.system(.body, design: .monospaced))
            }
            if store.pathDuplicateIDs.contains(entry.id) {
                Label("重复", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("同一目录出现多次；shell 层有 typeset -U 兜底，GUI 层不去重")
            }
            Spacer()
            Button { store.nudgePath(entry.id, delta: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(entry.id == store.pathEntries.first?.id)
            Button { store.nudgePath(entry.id, delta: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .disabled(entry.id == store.pathEntries.last?.id)
            Button { store.removePath(entry.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).foregroundStyle(.red)
                .disabled(entry.kind == .anchor)
        }
        .padding(.vertical, 2)
    }

    private var duplicateWarning: some View {
        Label("有重复条目。shell 层标记块内的 typeset -U path PATH 会兜底去重；GUI 层不去重，建议在此清理。",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
    }
}

// MARK: - New record sheet (shared by all variants)

struct NewRecordSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var shell = true
    @State private var gui = true
    @State private var secret = false

    private var duplicate: Bool { store.records.contains { $0.key == key } }

    var body: some View {
        VStack(spacing: 12) {
            Text("新建变量").font(.headline)
            Form {
                TextField("变量名 KEY", text: $key)
                TextField("原始值（保留 $ 引用原文）", text: $value)
                    .font(.system(.body, design: .monospaced))
                Toggle("秘密值（打码显示）", isOn: $secret).toggleStyle(.checkbox)
                Section("作用层") {
                    Toggle("shell 层（~/.zprofile 标记块）", isOn: $shell)
                    Toggle("GUI 层（launchctl）", isOn: $gui)
                }
            }
            if duplicate { Text("同名变量已存在").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加（待生效）") {
                    store.add(key: key, value: value, shell: shell, gui: gui, secret: secret)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || duplicate)
            }
        }
        .padding(16).frame(width: 500)
    }
}

// MARK: - Mock auxiliary sheets (静态样例，回答「入口要不要进 v1」)

enum MockSheet: String, Identifiable {
    case restart, diagnostics, backup, collect
    var id: String { rawValue }
    @ViewBuilder var content: some View {
        switch self {
        case .restart: RestartAppSheet()
        case .diagnostics: DiagnosticsSheet()
        case .backup: BackupSheet()
        case .collect: CollectSheet()
        }
    }
}

struct SheetHeader: View {
    let title: String
    let icon: String
    var body: some View { Label(title, systemImage: icon).font(.headline) }
}

struct RestartAppSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    private let apps = [
        ("Safari", "safari.fill"),
        ("Visual Studio Code", "chevron.left.forwardslash.chevron.right"),
        ("Slack", "bubble.left.and.bubble.right.fill"),
        ("微信", "person.2.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "重启指定 App", icon: "arrow.clockwise.circle")
            Text("已运行的 App 不会自动读到新变量（进程环境在启动时固定）。退出重开后，新进程即读到 GUI 层最新值。")
                .font(.callout).foregroundStyle(.secondary)
            List(apps, id: \.0) { app in
                HStack {
                    Image(systemName: app.1).frame(width: 26)
                    Text(app.0)
                    Spacer()
                    Button("退出并重启") {
                        store.restart(app: app.0)
                        dismiss()
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 190)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.25)))
        }
        .padding(16).frame(width: 480, height: 360)
    }
}

struct DiagnosticsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "诊断 — GUI 层持久化", icon: "stethoscope")
            List {
                checkRow("LaunchAgent plist",
                         "com.lautung.env-setter.plist 已注册", ok: store.agentRegistered)
                if store.loginItemEnabled {
                    checkRow("登录项（后台项 BTM）", "已启用——登录时会重放 setenv.sh", ok: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("登录项（后台项 BTM）已被你在系统设置里关闭",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        HStack {
                            Text("登录后变量不会重放，GUI 层将停留在上次的值。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("打开系统设置（模拟）") { store.loginItemEnabled = true }
                        }
                    }
                }
                checkRow("setenv.sh", "7 条变量，按声明顺序展开 $ 引用", ok: true)
                checkRow("抽查 launchctl getenv PATH", "与工具写入一致", ok: true)
                checkRow("抽查 launchctl getenv OPENAI_API_KEY", "与工具写入一致", ok: true)
            }
            .listStyle(.inset)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.25)))
            HStack {
                Button("重新生成 setenv.sh 并重注册") { store.regenerateAgent() }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 580, height: 400)
    }

    private func checkRow(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading) {
                Text(label)
                Text(value).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct BackupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    private let backups: [(String, Bool)] = [
        ("基线备份 — 2026-09-01 09:12", true),
        ("备份 — 2026-09-11 21:40", false),
        ("备份 — 2026-09-12 14:31（上次应用前）", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "备份与恢复", icon: "clock.arrow.circlepath")
            List(backups, id: \.0) { item in
                HStack {
                    Image(systemName: item.1 ? "lock.fill" : "archivebox")
                        .foregroundStyle(item.1 ? Color.orange : Color.secondary)
                    VStack(alignment: .leading) {
                        Text(item.0)
                        if item.1 {
                            Text("首次接管 ~/.zprofile 时创建，永不随清理轮转删除")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("恢复") {
                        store.restored(file: item.0)
                        dismiss()
                    }
                }
            }
            .listStyle(.inset)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.25)))
            Text("每次应用前自动做时间戳备份，存于 ~/Library/Application Support/EnvSetter/Backups。恢复 = 用备份覆盖标记块并重新载入列表。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 560, height: 380)
    }
}

struct CollectSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = [0, 1]
    private let lines = [
        "export ANDROID_HOME=$HOME/Library/Android/sdk",
        "export NVM_DIR=\"$HOME/.nvm\"",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "收编已有配置", icon: "square.and.arrow.down.on.square")
            Text("在 ~/.zprofile 标记块外发现这些手写的 export 行。收编后：原行被注释（保留手工回退），变量进入列表由工具接管；PATH 行会合并进 PATH 编辑器。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(lines.indices, id: \.self) { i in
                Toggle(isOn: Binding(
                    get: { selected.contains(i) },
                    set: { if $0 { selected.insert(i) } else { selected.remove(i) } }
                )) {
                    Text(lines[i]).font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
            HStack {
                Text("选中 \(selected.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("收编选中") {
                    store.collected(n: selected.count)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(16).frame(width: 580, height: 330)
    }
}
