import EnvSetterCore
import SwiftUI

/// 侧栏：顶部搜索、变量列表（状态图标 + 两层 chip + 打码预览）、工具区四入口。
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: model.selectionBinding) {
            Section {
                TextField("搜索变量名", text: $model.search)
                    .textFieldStyle(.roundedBorder)
            }

            Section("变量") {
                if model.rows.isEmpty {
                    Text(model.search.isEmpty ? "（还没有变量）" : "（没有匹配的变量）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    switch row {
                    case .record(let record):
                        RecordRowView(row: record).tag(record.id)
                    case .removed(let removed):
                        RemovedRowView(model: model, row: removed)
                    case .verbatim(let verbatim):
                        VerbatimRowView(row: verbatim)
                    }
                }
            }

            Section("工具") {
                Button {
                    Task { await model.planAdoption() }
                } label: {
                    Label("收编已有配置…", systemImage: "square.and.arrow.down.on.square")
                }
                .help("扫描 \(model.zprofileLabel) 标记块外手写的 export 行，接管为变量记录")

                Button {
                    Task { await model.openBackups() }
                } label: {
                    Label("备份与恢复…", systemImage: "clock.arrow.circlepath")
                }
                .help("每次应用前自动备份；这里可以整份恢复")

                Button {
                    model.openRestartSheet()
                } label: {
                    Label("重启指定 App…", systemImage: "arrow.clockwise.circle")
                }
                .help("已运行的 App 不会自动读到新变量，退出重开才行")

                Button {
                    Task { await model.openDiagnostics() }
                } label: {
                    Label("诊断 LaunchAgent…", systemImage: "stethoscope")
                }
                .help("逐项检查 GUI 层：脚本 / LaunchAgent 文件 / 注册 / 后台项 / 注入值 / 残留")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 250, ideal: 290)
    }
}

struct RecordRowView: View {
    let row: RecordRow

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: row.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.record.key)
                        .fontWeight(row.isPath ? .semibold : .regular)
                        .lineLimit(1)
                    if let issue = row.issue {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .help(issue)
                    }
                }
                Text(row.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            LayerChips(layers: row.layers)
        }
        .padding(.vertical, 1)
    }
}

/// 已应用、但草稿里被删掉的记录：划掉显示，可就地撤销（免得误删后只能整体重载）。
struct RemovedRowView: View {
    @ObservedObject var model: AppModel
    let row: RemovedRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.record.key)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text("已从列表移除（待生效）")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            Button("撤销") { model.undoRemoval(row.record.key) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 1)
    }
}

/// 标记块里工具看不懂的行：原样保留、绝不重写，因此这里也不给编辑。
struct VerbatimRowView: View {
    let row: VerbatimRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.line)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("逐字保留（工具不管理这一行）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .help("标记块里无法解析为简单 export 的行。工具原样写回、不改写；要改请直接编辑 ~/.zprofile。")
    }
}
