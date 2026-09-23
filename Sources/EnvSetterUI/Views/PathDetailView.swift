import EnvSetterCore
import SwiftUI

/// PATH 的就地编辑器：有序条目列表（拖拽 + ↑↓）、锚点行、重复条目警告。
struct PathDetailView: View {
    @ObservedObject var model: AppModel
    let record: VariableRecord

    @State private var newEntry = ""
    @FocusState private var focusedRow: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BannerBar(model: model)
                header
                layerToggles
                hint
                editor
                addRow
                warnings
                rawValueRow
                OrderSection(model: model, key: record.key)
                DeleteRecordButton(model: model, key: record.key)
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusIcon(status: model.rowStatus(for: record.key))
            Text(record.key).font(.title2.weight(.semibold))
            Spacer()
            LayerChips(layers: model.layerStates(for: record.key))
        }
    }

    private var layerToggles: some View {
        HStack(spacing: 20) {
            Toggle("写入 shell 层", isOn: model.shellBinding(for: record.key))
            Toggle("写入 GUI 层", isOn: model.guiBinding(for: record.key))
            Spacer()
        }
    }

    private var hint: some View {
        Text("拖动行或用 ↑↓ 排序；锚点行 = 继承既有 PATH，排在锚点之前即前插、之后即追加。一条一条添加；行里写下的 `:` 会在提交后拆成多条。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        List {
            ForEach(model.pathRows) { row in
                PathRowView(model: model, row: row, focusedRow: $focusedRow)
            }
            .onMove { offsets, destination in
                model.movePathRows(from: offsets, to: destination)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.25)))
        .onChange(of: focusedRow) { focused in
            // 失焦即提交：把行文本按 `:` 与 `$PATH` 归一化，看到的结构与写出去的一致。
            if focused == nil { model.commitPathRows() }
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("添加条目（目录或 $ 引用）", text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.pathHasAnchor {
                HStack(spacing: 8) {
                    Button {
                        model.addPathAnchor()
                    } label: {
                        Label("添加 $PATH 锚点", systemImage: "link")
                    }
                    Text("当前没有锚点：整条 PATH 会被替换，不继承既有 PATH。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var warnings: some View {
        if let warning = model.pathAnchorWarning {
            WarningLabel(text: warning)
        }
        if let warning = model.pathQuoteWarning {
            WarningLabel(text: warning)
        }
        if !model.pathDuplicateIDs.isEmpty {
            WarningLabel(
                text: "有重复条目：shell 层标记块内的 typeset -U path PATH 会兜底去重；GUI 层不去重，建议在这里清理。"
            )
        }
    }

    private var rawValueRow: some View {
        LabeledContent("写入的原始值") {
            HStack(spacing: 6) {
                Text(model.maskedPreview(record))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                if record.secret {
                    Button {
                        model.toggleReveal(record.key)
                    } label: {
                        Image(systemName: model.revealedKey == record.key ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func add() {
        model.addPathRow(newEntry)
        newEntry = ""
    }
}

/// PATH 列表的一行：锚点（虚线标识、不可编辑）或字面量条目（可编辑、可拖、可删）。
/// 动作一律按 `row.id` 定位，不用渲染时的下标——提交时的归一化会拆行、重排。
struct PathRowView: View {
    @ObservedObject var model: AppModel
    let row: PathRow
    @FocusState.Binding var focusedRow: UUID?

    private var index: Int? { model.pathRowIndex(of: row.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("拖动或用 ↑↓ 排序")

            if row.isAnchor {
                Text("$PATH — 锚点（继承既有 PATH）")
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .help("""
                        锚点之前 = 前插，之后 = 追加。shell 层展开为登录时的既有 PATH；\
                        GUI 层展开为 launchd 的默认 PATH（/usr/bin:/bin:/usr/sbin:/sbin）。
                        """)
            } else {
                TextField("目录或 $ 引用", text: model.pathRowTextBinding(forRow: row.id))
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedRow, equals: row.id)
                    .onSubmit { model.commitPathRows() }
            }

            if model.pathDuplicateIDs.contains(row.id) {
                Label("重复", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("同一目录出现多次；shell 层有 typeset -U 兜底，GUI 层不去重")
            }

            Spacer(minLength: 4)

            Button {
                model.nudgePathRow(row.id, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                model.nudgePathRow(row.id, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == nil || index == model.pathRows.count - 1)

            Button {
                model.removePathRow(row.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(!model.canRemovePathRow(row.id))
        }
        .padding(.vertical, 2)
    }
}
