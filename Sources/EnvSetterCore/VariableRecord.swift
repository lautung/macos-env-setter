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
    public var source: RecordSource
    public var quoteStyle: QuoteStyle

    public init(
        key: String,
        rawValue: String,
        shellEnabled: Bool = true,
        guiEnabled: Bool = false,
        source: RecordSource = .toolCreated,
        quoteStyle: QuoteStyle = .double
    ) {
        self.key = key
        self.rawValue = rawValue
        self.shellEnabled = shellEnabled
        self.guiEnabled = guiEnabled
        self.source = source
        self.quoteStyle = quoteStyle
    }

    public var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, rawValue, shellEnabled, guiEnabled, source, quoteStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        rawValue = try container.decode(String.self, forKey: .rawValue)
        shellEnabled = try container.decode(Bool.self, forKey: .shellEnabled)
        guiEnabled = try container.decode(Bool.self, forKey: .guiEnabled)
        source = try container.decode(RecordSource.self, forKey: .source)
        // 早期 store.json 没有该字段：缺省按双引号（展开引用）处理。
        quoteStyle = try container.decodeIfPresent(QuoteStyle.self, forKey: .quoteStyle) ?? .double
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

    public init(entries: [ManagedEntry] = [], blockSnapshot: String? = nil) {
        self.entries = entries
        self.blockSnapshot = blockSnapshot
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
