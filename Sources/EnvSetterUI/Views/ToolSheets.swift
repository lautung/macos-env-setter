import EnvSetterCore
import SwiftUI

// MARK: - 新建变量

struct NewRecordSheet: View {
    @ObservedObject var model: AppModel

    @State private var key = ""
    @State private var value = ""
    @State private var shell = true
    @State private var gui = true
    @State private var secret = false
    /// 用户自己动过「秘密值」勾选后，就不再按变量名自动建议。
    @State private var secretTouched = false
    @State private var quoteStyle: QuoteStyle = .double

    private var issue: String? { key.isEmpty ? nil : model.issueForNewKey(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "新建变量", icon: "plus")
            Form {
                TextField("变量名 KEY", text: $key)
                    .font(.system(.body, design: .monospaced))
                TextField("原始值（保留 $ 引用原文，不预展开）", text: $value)
                    .font(.system(.body, design: .monospaced))
                Picker("引用样式", selection: $quoteStyle) {
                    Text("双引号（$ 引用照常展开）").tag(QuoteStyle.double)
                    Text("单引号（$ 是字面量）").tag(QuoteStyle.single)
                }
                Toggle("秘密值（列表与预览打码）", isOn: secretBinding)
                Section("作用层（各自独立开关）") {
                    Toggle("shell 层（\(model.zprofileLabel) 标记块）", isOn: $shell)
                    Toggle("GUI 层（launchctl）", isOn: $gui)
                }
            }
            .formStyle(.grouped)

            if let issue {
                Text(issue).font(.caption).foregroundStyle(.red)
            }
            Text("添加后是「待生效」状态，点工具栏「应用」才写入两层。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    model.addRecord(
                        key: key.trimmingCharacters(in: .whitespaces),
                        rawValue: value,
                        shellEnabled: shell,
                        guiEnabled: gui,
                        secret: secret
                    )
                    model.setQuoteStyle(quoteStyle, for: key.trimmingCharacters(in: .whitespaces))
                    model.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(key.isEmpty || issue != nil)
            }
        }
        .padding(18)
        .frame(width: 540)
        .onChange(of: key) { newKey in
            // 一眼是凭据的变量名先替用户勾上打码——判断错了取消勾选即可，漏了才是真泄露。
            if !secretTouched, SecretKeys.looksSecret(newKey) { secret = true }
        }
    }

    private var secretBinding: Binding<Bool> {
        Binding(
            get: { secret },
            set: { newValue in
                secret = newValue
                secretTouched = true
            }
        )
    }
}

// MARK: - 收编

struct AdoptionSheet: View {
    @ObservedObject var model: AppModel
    let plan: AdoptionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "收编已有配置", icon: "square.and.arrow.down.on.square")
            Text("""
                在 \(model.zprofileLabel) 标记块外找到这些手写的 export 行。收编后：原行被注释掉（保留手工回退路径），\
                变量进入列表由工具接管；PATH 行按文件顺序语义保持地合并进 PATH 有序列表。收编的变量默认只写 shell 层。
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if !plan.adoptedKeys.isEmpty {
                    Section("接管为变量记录（\(plan.adoptedKeys.count) 条）") {
                        ForEach(plan.adoptedKeys, id: \.self) { key in
                            HStack(spacing: 8) {
                                Text(key).font(.system(.body, design: .monospaced))
                                Spacer()
                                Text(preview(for: key))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                if plan.mergedPathLineCount > 0 {
                    Section("PATH") {
                        Text("合并 \(plan.mergedPathLineCount) 行 PATH 进有序列表（收编后可在 PATH 编辑器里调整顺序）")
                            .font(.callout)
                    }
                }
                if !plan.outsideEdits.isEmpty {
                    Section("注释掉的块外行（\(plan.outsideEdits.count) 行）") {
                        ForEach(plan.outsideEdits.indices, id: \.self) { index in
                            Text(redacted(plan.outsideEdits[index].originalLine))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if !plan.skipped.isEmpty {
                    Section("跳过（保持原样，未收编）") {
                        ForEach(plan.skipped.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.skipped[index].line)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(plan.skipped[index].reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)

            HStack {
                Text("应用前会先备份 \(model.zprofileLabel)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("收编并应用") { Task { await model.confirmAdoption() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 640, height: 540)
    }

    private func preview(for key: String) -> String {
        guard let record = plan.entries.record(named: key) else { return "" }
        return SecretMasking.preview(record, revealed: false)
    }

    /// 块外原行里如果有刚被判定为秘密值的变量，这里也要打码——
    /// 否则下面这一栏会把它上面一栏刚码掉的值原样打出来。
    private func redacted(_ line: String) -> String {
        guard let parsed = ShellLine.parseExportLine(line),
            plan.entries.record(named: parsed.key)?.secret == true
        else { return line }
        return "export \(parsed.key)=\"\(SecretMasking.mask)\""
    }
}

// MARK: - 备份与恢复

struct BackupSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "备份与恢复", icon: "clock.arrow.circlepath")

            if model.backups.isEmpty {
                EmptyPane(
                    icon: "archivebox",
                    title: "还没有备份",
                    message: "每次应用前会自动把 \(model.zprofileLabel) 备份一份；首次接管时还会额外留一份永不删除的基线备份。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.backups) { backup in
                    HStack(spacing: 8) {
                        Image(systemName: backup.isBaseline ? "lock.fill" : "archivebox")
                            .foregroundStyle(backup.isBaseline ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.fileName).font(.system(.body, design: .monospaced))
                            Text(description(for: backup))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("恢复") { model.requestRestore(backup) }
                    }
                }
                .listStyle(.inset)
            }

            Text("""
                保留最近 \(BackupManager.retentionCount) 份时间戳备份，基线备份永不参与轮转；位置：\(model.backupsDirectoryLabel)。\
                恢复 = 用备份整份覆盖 \(model.zprofileLabel)（恢复前的内容也会先备份一份），然后以文件为准重新载入列表。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") { model.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 660, height: 480)
    }

    private func description(for backup: BackupInfo) -> String {
        if backup.isBaseline {
            return "基线备份 — 首次接管时创建，永不随清理轮转删除"
        }
        guard let date = backup.date else { return "时间戳读不出来" }
        return "备份于 " + date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - 重启指定 App

struct RestartSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "重启指定 App", icon: "arrow.clockwise.circle")
            Text("已运行的 App 不会自动读到新变量——进程环境在启动时就固定了。退出重开后，新进程读到的才是 GUI 层当前值。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.runningApps.isEmpty {
                EmptyPane(
                    icon: "app.dashed",
                    title: "没有可重启的 App",
                    message: "当前没有正在运行的常规 App。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.runningApps) { app in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            if let identifier = app.bundleIdentifier {
                                Text(identifier).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if model.restartingPID == app.pid {
                            ProgressView().controlSize(.small)
                            Text("等待退出…").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("退出并重启") { Task { await model.restart(app) } }
                            .disabled(model.restartingPID != nil || !app.canRestart)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("刷新") { model.refreshRunningApps() }
                Text("没在 5 秒内退出的 App 不会被强杀（可能有未保存的文档）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { model.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 500)
    }
}

// MARK: - 诊断 LaunchAgent

struct DiagnosticsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "诊断 — GUI 层（launchd）", icon: "stethoscope")
            Text("\(model.guiLabel) · \(model.guiDomain)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let diagnosis = model.diagnosis {
                List(diagnosis.checks, id: \.name) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: symbol(for: check.status))
                            .foregroundStyle(color(for: check.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.name)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .listStyle(.inset)

                Text(diagnosis.isHealthy ? "全部正常。" : "有需要注意的项（见上）。")
                    .font(.caption)
                    .foregroundStyle(diagnosis.isHealthy ? Color.secondary : Color.orange)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("重新体检") { Task { await model.openDiagnostics() } }
                Button("重试 GUI 同步") { Task { await model.retryGuiSync() } }
                    .disabled(!model.canRetryGuiSync)
                    .help(model.guiRetryHelp)
                if backgroundItemIssue {
                    Button("打开系统设置的登录项面板") { model.openLoginItemsSettings() }
                }
                Spacer()
                Button("完成") { model.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
            if model.pendingCount > 0 {
                Text(model.draftBlockedNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(width: 680, height: 500)
    }

    /// 后台项那一行不通过时才给出去系统设置的入口（判定见 `GuiDiagnosis.hasBackgroundItemProblem`）。
    private var backgroundItemIssue: Bool {
        model.diagnosis?.hasBackgroundItemProblem ?? false
    }

    private func symbol(for status: GuiCheckStatus) -> String {
        switch status {
        case .ok: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for status: GuiCheckStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}
