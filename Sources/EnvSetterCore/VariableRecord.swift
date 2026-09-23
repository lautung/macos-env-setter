import Foundation

/// 记录来源：工具创建，或从用户手写配置收编（导入）。
public enum RecordSource: String, Codable, Equatable, Sendable {
    case toolCreated
    case adopted
}

/// 原始值的引用语义：`.double` 里的 `$` 是要展开的引用；`.single` 里的 `$` 是字面量。
/// 写回时按原样式重新加引号，保证登录 shell 求值结果与原文一致。
public enum QuoteStyle: String, Codable, Equatable, Sendable {
    case double
    case single
}

/// 一条被工具管理的环境变量。
/// `rawValue` 是原始值：保留 `$` 引用与 `${…}` 展开原文，不预展开。
public struct VariableRecord: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var rawValue: String
    /// shell 层（~/.zprofile 标记块）开关
    public var shellEnabled: Bool
    /// GUI 层（launchctl）开关
    public var guiEnabled: Bool
    /// 秘密值：只影响界面展示（列表与预览打码），不影响两层的写入内容。
    /// 与 `guiEnabled`/`source` 一样属于本地状态，不写进标记块。
    public var secret: Bool
    public var source: RecordSource
    public var quoteStyle: QuoteStyle

    public init(
        key: String,
        rawValue: String,
        shellEnabled: Bool = true,
        guiEnabled: Bool = false,
        secret: Bool = false,
        source: RecordSource = .toolCreated,
        quoteStyle: QuoteStyle = .double
    ) {
        self.key = key
        self.rawValue = rawValue
        self.shellEnabled = shellEnabled
        self.guiEnabled = guiEnabled
        self.secret = secret
        self.source = source
        self.quoteStyle = quoteStyle
    }

    public var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, rawValue, shellEnabled, guiEnabled, secret, source, quoteStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        rawValue = try container.decode(String.self, forKey: .rawValue)
        shellEnabled = try container.decode(Bool.self, forKey: .shellEnabled)
        guiEnabled = try container.decode(Bool.self, forKey: .guiEnabled)
        source = try container.decode(RecordSource.self, forKey: .source)
        // 早期 store.json 没有这两个字段：缺省按「非秘密、双引号（展开引用）」处理。
        secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        quoteStyle = try container.decodeIfPresent(QuoteStyle.self, forKey: .quoteStyle) ?? .double
    }
}

/// 「秘密值」标记的启发式判断：收编用户既有配置时用，把一眼就是凭据的 key 默认打码。
/// 只影响展示，判断错了代价是「多打一次码」，判断漏了才是真泄露——所以宁可宽一点。
public enum SecretKeys {
    static let patterns = [
        "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "API_KEY", "APIKEY",
        "ACCESS_KEY", "PRIVATE_KEY", "AUTH", "SESSION",
    ]

    public static func looksSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        return patterns.contains { upper.contains($0) }
    }
}

/// 标记块内的一个条目：要么是工具管理的变量记录，要么是逐字保留的行。
/// 逐字行用于保存块内无法解析为简单 export 的内容（用户手写的复杂行），
/// 写回时原样输出、绝不重写——CodingBuddy 的纪律。
public enum ManagedEntry: Codable, Equatable, Sendable {
    case record(VariableRecord)
    case verbatim(line: String)

    public var key: String? {
        switch self {
        case .record(let record): return record.key
        case .verbatim: return nil
        }
    }
}

/// 工具的持久化状态：全部条目（列表顺序即声明顺序）+ 最后写入的标记块快照（漂移检测基准）。
public struct EnvStore: Codable, Equatable, Sendable {
    public var entries: [ManagedEntry]
    public var blockSnapshot: String?
    /// 待清理残留（见 CONTEXT.md）：已确认由本工具拥有、但 launchd 尚未成功清除的变量。
    public var pendingGuiRemovals: [String]

    public init(
        entries: [ManagedEntry] = [],
        blockSnapshot: String? = nil,
        pendingGuiRemovals: [String] = []
    ) {
        self.entries = entries
        self.blockSnapshot = blockSnapshot
        self.pendingGuiRemovals = pendingGuiRemovals
    }

    private enum CodingKeys: String, CodingKey {
        case entries, blockSnapshot, pendingGuiRemovals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([ManagedEntry].self, forKey: .entries)
        blockSnapshot = try container.decodeIfPresent(String.self, forKey: .blockSnapshot)
        // store.json 由旧版创建时没有这个字段。
        pendingGuiRemovals = try container.decodeIfPresent([String].self, forKey: .pendingGuiRemovals) ?? []
    }
}

public enum StorePersistence {
    public static func load(from url: URL) throws -> EnvStore {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EnvStore.self, from: data)
    }

    public static func save(_ store: EnvStore, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try AtomicFile.write(data, to: url)
    }
}
