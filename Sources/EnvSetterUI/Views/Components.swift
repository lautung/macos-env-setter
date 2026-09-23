import EnvSetterCore
import SwiftUI

// MARK: - 状态原子

/// 「待生效 / 已写入 / 未启用」三态图标（列表与详情共用）。
struct StatusIcon: View {
    let status: RowStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .help("待生效：改动还没应用")
        case .synced:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("启用的层都已写入")
        case .off:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .help("两层都没启用，不写入")
        }
    }
}

/// 两层的行内 chip：绿 = 已写入 / 橙 = 待应用 / 灰 = 未启用。
struct LayerChips: View {
    let layers: LayerStates

    var body: some View {
        HStack(spacing: 4) {
            chip("shell", layers.shell)
            chip("GUI", layers.gui)
        }
    }

    private func chip(_ label: String, _ state: LayerState) -> some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color(state).opacity(0.16), in: Capsule())
            .foregroundStyle(color(state))
            .help(help(state))
    }

    private func color(_ state: LayerState) -> Color {
        switch state {
        case .off: return .gray
        case .pending: return .orange
        case .written: return .green
        }
    }

    private func help(_ state: LayerState) -> String {
        switch state {
        case .off: return "这一层未启用，不写入"
        case .pending: return "计划写入这一层，待应用"
        case .written: return "已写入这一层"
        }
    }
}

// MARK: - 横幅

/// 应用/收编/漂移之后的一次性提示卡片；信息类会自动消失，警告类留着等用户关掉。
/// 它由 `BannerBar` 放在详情内容顶上占一条位置（不是浮层），所以没有投影。
struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.kind == .warning ? Color.orange : Color.blue)
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gray.opacity(0.25)))
        .frame(maxWidth: 640)
    }
}

/// 提示条：详情内容顶上占一条位置、把内容往下推（原来是窗口级浮层，会盖住标题——验收缺陷 ②）。
/// 放在详情内容流里而不是浮在分栏上：分栏被推出窗口顶边时，macOS 26 会在详情栏滚动视图顶边
/// 套一层淡出把标题糊掉；给两栏内容加占位又会把分栏撑高、每启动一次再长一点。
struct BannerBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let banner = model.banner {
            BannerView(banner: banner) { model.banner = nil }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { Divider() }
                .task(id: banner.id) {
                    // 信息类自己退场；警告类留着，等用户看明白了再关。
                    // 别用 `try?`：视图被重建（例如换了选中的记录）时这个 task 会被取消，
                    // 被吞掉的取消会让 sleep 立刻返回、提示条当场被清掉，等于从不显示。
                    guard banner.kind == .info else { return }
                    do {
                        try await Task.sleep(nanoseconds: 12_000_000_000)
                    } catch {
                        return
                    }
                    if model.banner?.id == banner.id { model.banner = nil }
                }
        }
    }
}

// MARK: - 空态与提示

/// 手写的空态（`ContentUnavailableView` 要 macOS 14，本包按 13 构建）。
struct EmptyPane: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: 420)
        .padding(24)
    }
}

struct SheetHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon).font(.headline)
    }
}

/// 橙色提醒行（重复条目、锚点异常、单引号 PATH…）。
struct WarningLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 详情区共用的段落

/// 作用层双开关。
struct LayerToggles: View {
    @ObservedObject var model: AppModel
    let key: String

    var body: some View {
        Section("作用层（各自独立开关）") {
            Toggle("shell 层 — 写入 \(model.zprofileLabel) 标记块", isOn: model.shellBinding(for: key))
            Toggle("GUI 层 — 写入 launchctl（Dock / Finder / Spotlight 启动的 App）", isOn: model.guiBinding(for: key))
        }
    }
}

/// 写入状态：来源、状态、引用样式。
struct StatusSection: View {
    @ObservedObject var model: AppModel
    let record: VariableRecord

    var body: some View {
        Section("写入状态") {
            LabeledContent("来源") {
                Text(record.source == .adopted ? "导入（收编自手写配置）" : "工具创建")
            }
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    StatusIcon(status: model.rowStatus(for: record.key))
                    Text(statusText)
                        .foregroundStyle(model.rowStatus(for: record.key) == .pending ? Color.orange : Color.secondary)
                }
            }
            LabeledContent("引用样式") {
                Picker("", selection: model.quoteStyleBinding(for: record.key)) {
                    Text("双引号（$ 引用照常展开）").tag(QuoteStyle.double)
                    Text("单引号（$ 是字面量）").tag(QuoteStyle.single)
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
        }
    }

    private var statusText: String {
        switch model.rowStatus(for: record.key) {
        case .pending: return "待生效 — 改动只在内存，点「应用」才写入"
        case .synced: return "启用的层都已写入"
        case .off: return "两层都没启用，不写入"
        }
    }
}

/// 声明顺序：顺序就是写入顺序，`$` 引用只能看到排在它前面的变量。
struct OrderSection: View {
    @ObservedObject var model: AppModel
    let key: String

    var body: some View {
        Section("声明顺序") {
            HStack(spacing: 8) {
                Button {
                    model.moveRecord(key, by: -1)
                } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .disabled(isFirst)

                Button {
                    model.moveRecord(key, by: 1)
                } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .disabled(isLast)

                Spacer()

                if model.structureChanged {
                    Label("顺序已调整（待生效）", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("声明顺序就是写入顺序：值里的 `$` 引用只能看到排在它前面的变量（PATH 记录因此通常排在最后）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var index: Int? {
        model.entries.firstIndex { $0.key == key }
    }

    private var isFirst: Bool { (index ?? 0) == 0 }

    private var isLast: Bool {
        guard let index else { return true }
        return index == model.entries.count - 1
    }
}

struct DeleteRecordButton: View {
    @ObservedObject var model: AppModel
    let key: String

    var body: some View {
        Button(role: .destructive) {
            model.requestDelete(key)
        } label: {
            Label("从列表移除", systemImage: "trash")
        }
    }
}
