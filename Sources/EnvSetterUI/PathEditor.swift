import EnvSetterCore
import Foundation

/// PATH 编辑器里的一行。`id` 只为界面稳定（拖拽、↑↓、输入焦点）而存在，不参与写入。
public struct PathRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// 字面量文本；锚点行恒为 `$PATH`，不可编辑。
    public var text: String
    public var isAnchor: Bool

    public init(id: UUID = UUID(), text: String, isAnchor: Bool = false) {
        self.id = id
        self.text = text
        self.isAnchor = isAnchor
    }
}

/// PATH 有序列表的编辑逻辑：与 `PathList`（`:` 拼接语义）互转。
///
/// 编辑中的行按原样保存文本——敲进一个 `:` 不会当场把行拆开、把输入焦点甩掉；
/// 语义归一化（拆行、识别 `$PATH` 锚点）在提交时（回车或失焦）由 `normalized` 完成。
public enum PathEditor {
    public static func rows(fromRawValue raw: String) -> [PathRow] {
        PathList.entries(fromRawValue: raw).map { entry in
            switch entry {
            case .anchor: return PathRow(text: "$PATH", isAnchor: true)
            case .literal(let text): return PathRow(text: text)
            }
        }
    }

    public static func rawValue(from rows: [PathRow]) -> String {
        rows.map { $0.isAnchor ? "$PATH" : $0.text }.joined(separator: ":")
    }

    public static func normalized(_ rows: [PathRow]) -> [PathRow] {
        Self.rows(fromRawValue: Self.rawValue(from: rows))
    }

    /// 两串行的结构是否一样（忽略 `id`）：用来判断「这次提交要不要重建行」——
    /// 结构没变就不重建，免得每次失焦都换一批 id、把输入焦点和拖拽状态甩掉。
    public static func sameStructure(_ lhs: [PathRow], _ rhs: [PathRow]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy { $0.text == $1.text && $0.isAnchor == $1.isAnchor }
    }

    /// 重复条目：不区分大小写（macOS 文件系统默认不区分），空条目是「当前目录」语义、不参与判重。
    public static func duplicateIDs(_ rows: [PathRow]) -> Set<UUID> {
        let literals = rows.filter { !$0.isAnchor && !$0.text.isEmpty }
        let grouped = Dictionary(grouping: literals) { $0.text.lowercased() }
        return Set(grouped.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }

    public static func anchorCount(_ rows: [PathRow]) -> Int {
        rows.filter(\.isAnchor).count
    }

    /// 行的文本提交后是否产生语义变化：用来判断「这次编辑要不要写回原始值」。
    /// 只有语义真的变了才写——否则一次单纯的失焦会把 `${PATH}` 重排成 `$PATH`，白白标成「待生效」。
    public static func changesSemantics(currentRawValue: String, rows: [PathRow]) -> Bool {
        let edited = Self.rawValue(from: rows)
        return edited != Self.rawValue(from: Self.rows(fromRawValue: currentRawValue))
    }
}
