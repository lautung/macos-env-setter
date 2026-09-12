import Foundation

/// 引擎可注入的全部文件路径；测试用沙盒家目录替换。
public struct EnginePaths: Sendable {
    public var zprofileURL: URL
    public var storeURL: URL
    public var backupsDirectory: URL

    public init(zprofileURL: URL, storeURL: URL, backupsDirectory: URL) {
        self.zprofileURL = zprofileURL
        self.storeURL = storeURL
        self.backupsDirectory = backupsDirectory
    }

    public static func standard() -> EnginePaths {
        sandboxed(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// 把指定目录当作家目录，供测试使用。
    public static func sandboxed(home: URL) -> EnginePaths {
        EnginePaths(
            zprofileURL: home.appending(path: ".zprofile"),
            storeURL: home
                .appending(path: "Library/Application Support/EnvSetter/store.json"),
            backupsDirectory: home.appending(path: ".env-setter/backups")
        )
    }
}

/// 原子写：解析 symlink 后写真实目标（不破坏链接）、保留文件权限、临时文件 + 原子替换。
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        // 解析整条路径上的 symlink，落到真实文件上写，避免 rename 把用户的链接替换掉。
        let destination = url.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        var mode: mode_t = 0o644
        if let attrs = try? fm.attributesOfItem(atPath: destination.path),
            let fileMode = attrs[.posixPermissions] as? NSNumber
        {
            mode = mode_t(truncating: fileMode)
        }

        let tmp = parent.appending(path: ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        chmod(tmp.path, mode)
        defer { try? fm.removeItem(at: tmp) }
        _ = try fm.replaceItemAt(destination, withItemAt: tmp)
    }
}

/// 把文件内容切成行，支持按行号精确替换，重组时未触碰的行字节级原样保留。
struct FileText {
    let content: String
    private let lineRanges: [Range<String.Index>]
    private let hadTrailingNewline: Bool

    init(_ content: String) {
        self.content = content
        var ranges: [Range<String.Index>] = []
        var index = content.startIndex
        while index < content.endIndex, let nl = content[index...].firstIndex(of: "\n") {
            ranges.append(index..<nl)
            index = content.index(after: nl)
        }
        if index < content.endIndex {
            ranges.append(index..<content.endIndex)
            hadTrailingNewline = false
        } else {
            hadTrailingNewline = !ranges.isEmpty
        }
        lineRanges = ranges
    }

    var lines: [String] { lineRanges.map { String(content[$0]) } }

    var lineCount: Int { lineRanges.count }

    func line(at index: Int) -> String? {
        guard lineRanges.indices.contains(index) else { return nil }
        return String(content[lineRanges[index]])
    }

    /// 整个文件在字节层面的结尾是否带换行。
    var endsWithNewline: Bool { hadTrailingNewline }

    func replacingLine(at index: Int, with newLine: String) -> String {
        precondition(lineRanges.indices.contains(index), "line index out of range")
        var result = content
        result.replaceSubrange(lineRanges[index], with: newLine)
        return result
    }

    /// 行号区间 [from, to) 前的行范围在原文中的完整 Range（含行间换行）。
    func rangeOfLines(from: Int, to: Int) -> Range<String.Index> {
        precondition(lineRanges.indices.contains(from))
        let lower = lineRanges[from].lowerBound
        let upper = to < lineRanges.count ? lineRanges[to].lowerBound : content.endIndex
        return lower..<upper
    }

    /// 行号区间 [from, to]（闭区间）的完整 Range：含行内容与行间换行，
    /// 但不含第 to 行自身的行尾换行——替换块时不得吞掉块后的第一个换行。
    func rangeOfLinesClosed(from: Int, to: Int) -> Range<String.Index> {
        precondition(lineRanges.indices.contains(from) && lineRanges.indices.contains(to))
        return lineRanges[from].lowerBound..<lineRanges[to].upperBound
    }
}
