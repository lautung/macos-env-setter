import Foundation

public enum EngineError: Error, Equatable, Sendable {
    /// 标记块只有开始或只有结束标记，或出现重复标记——无法安全改写，工具保持只读。
    case malformedMarkerBlock
    /// 应用前漂移检测发现标记块被手工改动过，需要先以文件为准重新载入。
    case driftDetected
    /// 收编计划里的块外行在写入时已对不上原文（文件在此期间变过）。
    case fileChangedSincePlan
    case invalidKey(String)
    case invalidRawValue(String)
    case backupNotFound(String)
    case backupFileUnreadable(String)
    case fileNotUTF8
}

public struct LoadResult: Equatable, Sendable {
    public var entries: [ManagedEntry]
    /// 本次 load 发现了漂移，并已按「以文件为准」完成重新载入。
    public var driftDetected: Bool
    /// 首次遇到已存在的标记块（无快照），已把块内容收编为当前状态。
    public var adoptedExistingBlock: Bool
    public var hasMarkerBlock: Bool

    public static func == (lhs: LoadResult, rhs: LoadResult) -> Bool {
        lhs.entries == rhs.entries && lhs.driftDetected == rhs.driftDetected
            && lhs.adoptedExistingBlock == rhs.adoptedExistingBlock
            && lhs.hasMarkerBlock == rhs.hasMarkerBlock
    }
}
