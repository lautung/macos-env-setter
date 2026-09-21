import EnvSetterCore
import Foundation

/// 一条要给人看的错误/确认。界面上只有一个 alert 修饰符，靠它统一呈现。
public struct Dialog: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// 只有「好」。
        case acknowledge
        /// 以文件为准重新载入（漂移之后，或丢弃未应用改动）。
        case reloadFromDisk
        /// 从列表移除一条记录（尚未落盘，应用后才从文件删除）。
        case deleteRecord(String)
        /// 用备份覆盖 ~/.zprofile。
        case restoreBackup(BackupInfo)
    }

    public let id: UUID
    public var title: String
    public var message: String
    /// nil = 只有「好」按钮；否则是确认按钮的标题。
    public var confirmTitle: String?
    public var isDestructive: Bool
    public var action: Action

    public init(
        title: String,
        message: String,
        confirmTitle: String? = nil,
        isDestructive: Bool = false,
        action: Action = .acknowledge
    ) {
        self.id = UUID()
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// 引擎错误 → 人话。默认的 `localizedDescription` 对 Swift 枚举错误只会给出一串无用的占位文本。
public enum EngineErrorMessages {
    public static func dialog(for error: Error) -> Dialog {
        guard let error = error as? EngineError else {
            return Dialog(title: "操作失败", message: error.localizedDescription)
        }
        switch error {
        case .driftDetected:
            return Dialog(
                title: "配置文件被手工改动过",
                message: """
                    ~/.zprofile 的标记块内容与工具上次写入的不一致（漂移）。按既定原则以文件为准：\
                    重新载入会读到手工改动后的内容，并丢弃你在应用内未应用的编辑。
                    """,
                confirmTitle: "重新载入",
                isDestructive: true,
                action: .reloadFromDisk
            )
        case .malformedMarkerBlock:
            return Dialog(
                title: "标记块不完整",
                message: """
                    ~/.zprofile 里只有开始或结束标记（或标记重复），工具无法安全改写，也不会去猜。\
                    请手工补齐 \(MarkerBlock.beginMarker) / \(MarkerBlock.endMarker) 这一对标记后重新载入。
                    """
            )
        case .fileChangedSincePlan:
            return Dialog(
                title: "文件在收编计划之后被改动过",
                message: "计划要注释掉的行已对不上原文，本次收编已放弃（文件未写入）。请重新执行收编。"
            )
        case .invalidKey(let key):
            return Dialog(title: "变量名不合法", message: "「\(key)」不是合法的环境变量名，未写入。")
        case .invalidRawValue(let key):
            return Dialog(
                title: "原始值不合法",
                message: "「\(key)」的值无法安全写回（含换行，或单引号样式里含撇号），未写入。"
            )
        case .backupNotFound(let path):
            return Dialog(title: "找不到备份", message: path)
        case .backupFileUnreadable(let path):
            return Dialog(title: "备份读不出来", message: "\(path) 不是 UTF-8 文本。")
        case .fileNotUTF8:
            return Dialog(title: "配置文件不是 UTF-8 文本", message: "~/.zprofile 读不出 UTF-8 内容，工具未做任何改动。")
        }
    }
}
