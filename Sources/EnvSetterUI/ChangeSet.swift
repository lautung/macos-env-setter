import EnvSetterCore
import Foundation

/// 影响两层写入内容的字段。
///
/// `secret`（打码）与 `source`（来源）只影响展示，改它们不会改变任何写入结果——
/// 它们也就不会让一条记录变成「待生效」。界面上所有「待生效」都由此判定。
public struct WriteSignature: Equatable, Sendable {
    public var key: String
    public var rawValue: String
    public var shellEnabled: Bool
    public var guiEnabled: Bool
    public var quoteStyle: QuoteStyle

    public init(_ record: VariableRecord) {
        self.key = record.key
        self.rawValue = record.rawValue
        self.shellEnabled = record.shellEnabled
        self.guiEnabled = record.guiEnabled
        self.quoteStyle = record.quoteStyle
    }
}

public extension Array where Element == ManagedEntry {
    var records: [VariableRecord] {
        compactMap { entry in
            guard case .record(let record) = entry else { return nil }
            return record
        }
    }

    /// 按 key 找记录（重复 key 时取第一条——重复本身是校验错误，界面会拦住应用）。
    func record(named key: String) -> VariableRecord? {
        records.first { $0.key == key }
    }

    func hasRecord(named key: String) -> Bool {
        record(named: key) != nil
    }
}

/// 一条记录在某一层上的状态。
public enum LayerState: Equatable, Sendable {
    /// 该层未启用，不写入
    case off
    /// 已启用，但写入内容与已应用状态不一致
    case pending
    /// 已启用且与已应用状态一致
    case written
}

public struct LayerStates: Equatable, Sendable {
    public var shell: LayerState
    public var gui: LayerState

    public init(shell: LayerState, gui: LayerState) {
        self.shell = shell
        self.gui = gui
    }
}

/// 一行的整体状态（列表图标 / 详情状态区共用）。
public enum RowStatus: Equatable, Sendable {
    case pending
    case synced
    case off
}

/// 草稿（内存里的编辑）与已应用状态（磁盘上的快照）之间的差异。
/// 界面的「待生效」标识、工具栏计数、应用按钮的可用性全部由它派生。
public struct ChangeSet: Equatable, Sendable {
    /// 新增或写入内容有变的 key。
    public var pendingKeys: Set<String>
    /// 已应用、但草稿里被删掉的记录（列表里划掉显示，可撤销）。
    public var removedRecords: [VariableRecord]
    /// 共同 key 之间的相对顺序变了。
    public var orderChanged: Bool
    /// 已应用状态按 key 索引，供逐层状态判定使用。
    public var savedByKey: [String: VariableRecord]

    public init(draft: [ManagedEntry], saved: [ManagedEntry]) {
        let savedRecords = saved.records
        let draftRecords = draft.records
        // 重复 key 不能崩：草稿里可能有重复（校验会拦住应用），这里后写覆盖前写。
        let savedByKey = savedRecords.reduce(into: [String: VariableRecord]()) { $0[$1.key] = $1 }
        let savedKeys = Set(savedRecords.map(\.key))
        let draftKeys = Set(draftRecords.map(\.key))

        var pending = Set<String>()
        for record in draftRecords {
            guard let applied = savedByKey[record.key] else {
                pending.insert(record.key)
                continue
            }
            if WriteSignature(applied) != WriteSignature(record) {
                pending.insert(record.key)
            }
        }
        self.savedByKey = savedByKey
        pendingKeys = pending
        removedRecords = savedRecords.filter { !draftKeys.contains($0.key) }

        // 顺序只看双方都有的 key，且按首次出现去重：重复 key 是校验错误，
        // 不该顺带把「顺序变了」也点亮（那会让计数和提示都失真）。
        let draftOrder = Self.uniqueKeys(draftRecords, limitedTo: savedKeys)
        let savedOrder = Self.uniqueKeys(savedRecords, limitedTo: draftKeys)
        orderChanged = draftOrder != savedOrder
    }

    private static func uniqueKeys(_ records: [VariableRecord], limitedTo allowed: Set<String>) -> [String] {
        var seen = Set<String>()
        return records.map(\.key).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    public var count: Int {
        pendingKeys.count + removedRecords.count + (orderChanged ? 1 : 0)
    }

    public var isEmpty: Bool { count == 0 }

    public func isPending(_ key: String) -> Bool { pendingKeys.contains(key) }

    /// 逐层状态：只看这一层开关与写入内容，另一层的变化不该把它也染成橙色。
    public func layerStates(for record: VariableRecord) -> LayerStates {
        let saved = savedByKey[record.key]
        let valueChanged = saved == nil
            || saved?.rawValue != record.rawValue
            || saved?.quoteStyle != record.quoteStyle

        func state(enabled: Bool, wasEnabled: Bool) -> LayerState {
            guard enabled else { return .off }
            return (valueChanged || !wasEnabled) ? .pending : .written
        }
        return LayerStates(
            shell: state(enabled: record.shellEnabled, wasEnabled: saved?.shellEnabled ?? false),
            gui: state(enabled: record.guiEnabled, wasEnabled: saved?.guiEnabled ?? false)
        )
    }
}

/// 侧栏一行的内容。记录行可选中编辑；逐字保留行只读；已删除未应用的行划掉显示、可就地撤销。
public enum SidebarRow: Identifiable, Equatable, Sendable {
    case record(RecordRow)
    case removed(RemovedRow)
    case verbatim(VerbatimRow)

    public var id: String {
        switch self {
        case .record(let row): return "record:\(row.id)"
        case .removed(let row): return "removed:\(row.id)"
        case .verbatim(let row): return "verbatim:\(row.id)"
        }
    }
}

public struct RecordRow: Identifiable, Equatable, Sendable {
    public var record: VariableRecord
    public var status: RowStatus
    public var layers: LayerStates
    /// 列表里的值预览（秘密值已打码）。
    public var preview: String
    /// 校验问题；非 nil 时行内显示红色提示。
    public var issue: String?
    /// GUI 层引用警告；非空时行内显示橙色提示（非阻塞，不挡「应用」）。
    public var warnings: [GuiReferenceWarning]
    public var isPath: Bool

    public var id: String { record.key }
}

public struct RemovedRow: Identifiable, Equatable, Sendable {
    public var record: VariableRecord

    public var id: String { record.key }
}

/// 标记块内无法解析为简单 export、被工具逐字保留的行（工具不重写它们，也不管理它们）。
public struct VerbatimRow: Identifiable, Equatable, Sendable {
    public var line: String
    public var index: Int

    public var id: Int { index }
}
