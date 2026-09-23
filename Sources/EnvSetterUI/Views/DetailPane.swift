import EnvSetterCore
import SwiftUI

/// 详情区：选中 PATH 时展开 PATH 专用编辑器，其余记录是普通编辑表单。
struct DetailPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let record = model.selectedRecord {
            Group {
                if record.key == VariableKeys.path {
                    PathDetailView(model: model, record: record)
                } else {
                    RecordDetailView(model: model, record: record)
                }
            }
            // 换一条记录就重建视图：变量名草稿、焦点这些局部状态不该跨记录残留。
            .id(record.key)
        } else {
            emptyState
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.entries.isEmpty {
            VStack(spacing: 0) {
                BannerBar(model: model)
                EmptyPane(
                    icon: "list.bullet.rectangle",
                    title: "还没有变量",
                    message: """
                        可以从「收编已有配置」开始，把 \(model.zprofileLabel) 里手写的 export 行接管进来；\
                        也可以点右上角 + 新建一条。
                        """,
                    actionTitle: "收编已有配置…",
                    action: { Task { await model.planAdoption() } }
                )
            }
        } else {
            VStack(spacing: 0) {
                BannerBar(model: model)
                EmptyPane(
                    icon: "hand.point.left",
                    title: "选择一个变量",
                    message: "左侧选择变量查看与编辑，或点右上角 + 新建一条。编辑只改内存，点「应用」才写入两层。"
                )
            }
        }
    }
}

/// 普通变量的编辑表单。
struct RecordDetailView: View {
    @ObservedObject var model: AppModel
    let record: VariableRecord

    @State private var draftKey: String
    @FocusState private var keyFocused: Bool

    init(model: AppModel, record: VariableRecord) {
        self.model = model
        self.record = record
        _draftKey = State(initialValue: record.key)
    }

    private var revealed: Bool { model.revealedKey == record.key }
    private var keyIssue: String? { model.issueForRename(draftKey, from: record.key) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BannerBar(model: model)
                header
                Form {
                    keyRow
                    valueRow
                    LayerToggles(model: model, key: record.key)
                    StatusSection(model: model, record: record)
                    OrderSection(model: model, key: record.key)
                }
                .formStyle(.grouped)

                Label(
                    "「待生效」= 改动还在内存里。应用会先备份，再一次性写入 \(model.zprofileLabel) 的标记块与 GUI 层；写入只影响之后新启动的 App。",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    private var keyRow: some View {
        LabeledContent("变量名") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("KEY", text: $draftKey)
                        .font(.system(.body, design: .monospaced))
                        .focused($keyFocused)
                        .onSubmit(commitKey)
                        .onChange(of: keyFocused) { focused in
                            if !focused { commitKey() }
                        }
                    if keyIssue != nil {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
                if let keyIssue {
                    Text(keyIssue).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var valueRow: some View {
        LabeledContent("原始值") {
            HStack(spacing: 6) {
                if record.secret, !revealed {
                    Text(SecretMasking.masked(record.rawValue))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        model.toggleReveal(record.key)
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.borderless)
                    .help("临时显示明文（换一条记录就重新打码）")
                } else {
                    TextField("原始值（保留 $ 引用原文，不预展开）", text: model.rawValueBinding(for: record.key))
                        .font(.system(.body, design: .monospaced))
                    if record.secret {
                        Button {
                            model.toggleReveal(record.key)
                        } label: {
                            Image(systemName: "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help("重新打码")
                    }
                }
            }
        }
        Toggle("秘密值（列表与预览打码）", isOn: model.secretBinding(for: record.key))
            // 打码标记是同步写本地状态的：应用进行中也写会跟应用那次保存抢同一份文件。
            .disabled(model.isBusy)
    }

    private func commitKey() {
        let newKey = draftKey.trimmingCharacters(in: .whitespaces)
        guard newKey != record.key else {
            draftKey = record.key
            return
        }
        guard model.issueForRename(newKey, from: record.key) == nil else {
            draftKey = record.key
            return
        }
        model.setKey(newKey, for: record.key)
    }
}
