import Foundation

public struct BackupInfo: Equatable, Sendable, Identifiable {
    public let url: URL
    public let date: Date?
    public let isBaseline: Bool

    public var id: String { url.lastPathComponent }
    public var fileName: String { url.lastPathComponent }
}

/// 时间戳备份：每次应用前把配置文件备份到 `~/.env-setter/backups/`，
/// 保留最近 20 份；首次接管时创建的基线备份永不参与轮转。
public struct BackupManager: Sendable {
    public static let retentionCount = 20
    public static let baselineFileName = "zprofile-baseline.zprofile"

    public let backupsDirectory: URL

    public init(backupsDirectory: URL) {
        self.backupsDirectory = backupsDirectory
    }

    /// 备份文件名内的时间戳格式（同一秒内的多份备份以 -2、-3 后缀区分）。
    private static func makeStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return formatter
    }

    /// 首次接管时创建基线备份；已有基线则不动。
    /// 返回是否新建了基线。文件不存在时不创建（没有可接管的内容）。
    @discardableResult
    public func ensureBaseline(currentContent: String?) throws -> Bool {
        guard let currentContent else { return false }
        try makeDirectoryIfNeeded()
        let baseline = backupsDirectory.appending(path: Self.baselineFileName)
        if FileManager.default.fileExists(atPath: baseline.path) { return false }
        try Data(currentContent.utf8).write(to: baseline, options: .atomic)
        return true
    }

    /// 每次应用前的时间戳备份，随后裁剪到保留上限。
    /// 文件不存在时不备份（首次创建无从备份）。
    @discardableResult
    public func timestampedBackup(currentContent: String?) throws -> URL? {
        guard let currentContent else { return nil }
        try makeDirectoryIfNeeded()
        let formatter = Self.makeStampFormatter()
        var name = "zprofile-\(formatter.string(from: Date())).zprofile"
        var url = backupsDirectory.appending(path: name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            name = "zprofile-\(formatter.string(from: Date()))-\(suffix).zprofile"
            url = backupsDirectory.appending(path: name)
        }
        try Data(currentContent.utf8).write(to: url, options: .atomic)
        try prune()
        return url
    }

    public func list() throws -> [BackupInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backupsDirectory.path) else {
            return []
        }
        let formatter = Self.makeStampFormatter()

        return names
            .filter { $0.hasPrefix("zprofile-") && $0.hasSuffix(".zprofile") }
            .sorted()
            .map { name in
                let url = backupsDirectory.appending(path: name)
                let isBaseline = name == Self.baselineFileName
                // 同一秒的碰撞后缀（-2、-3，一至两位数字）不参与时间解析；
                // 日期与时间之间的连字符后是 6 位时间，不能误删。
                var stamp = String(name.dropFirst("zprofile-".count).dropLast(".zprofile".count))
                if let dash = stamp.lastIndex(of: "-") {
                    let tail = stamp[stamp.index(after: dash)...]
                    if (1...2).contains(tail.count), tail.allSatisfy(\.isNumber) {
                        stamp = String(stamp[..<dash])
                    }
                }
                let date = isBaseline ? nil : formatter.date(from: stamp)
                return BackupInfo(url: url, date: date, isBaseline: isBaseline)
            }
    }

    public func read(url: URL) throws -> String {
        let resolved = url.resolvingSymlinksInPath()
        let canonical = resolved.deletingLastPathComponent().standardizedFileURL
        let allowed = backupsDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard canonical == allowed else { throw EngineError.backupNotFound(url.path) }
        guard let content = String(data: try Data(contentsOf: resolved), encoding: .utf8) else {
            throw EngineError.backupFileUnreadable(url.path)
        }
        return content
    }

    /// 裁剪：只删时间戳备份，基线永不删。
    public func prune() throws {
        let timestamped = try list().filter { !$0.isBaseline }
        guard timestamped.count > Self.retentionCount else { return }
        // list() 已按文件名排序，文件名内的时间戳即时间顺序。
        let outdated = timestamped.prefix(timestamped.count - Self.retentionCount)
        for info in outdated {
            try FileManager.default.removeItem(at: info.url)
        }
    }

    private func makeDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }
}
