import Foundation

/// PATH 值中的单个条目。`anchor` 代表「继承既有 PATH」：shell 层写作 `$PATH`（登录时的既有 PATH）。
public enum PathEntry: Equatable, Sendable, Codable {
    case literal(String)
    case anchor

    var rawText: String {
        switch self {
        case .literal(let value): return value
        case .anchor: return "$PATH"
        }
    }

    var isAnchor: Bool {
        if case .anchor = self { return true }
        return false
    }
}

/// PATH 专用逻辑：有序列表与 `:` 拼接的原始值互转，以及语义保持的多行合并。
public enum PathList {
    /// 把 PATH 原始值切成有序条目。`$PATH` 与 `${PATH}` 识别为锚点；
    /// 空段（`a::b` 中的当前目录语义）保留为字面量空条目。
    public static func entries(fromRawValue raw: String) -> [PathEntry] {
        raw.split(separator: ":", omittingEmptySubsequences: false).map { segment in
            segment == "$PATH" || segment == "${PATH}" ? PathEntry.anchor : .literal(String(segment))
        }
    }

    public static func rawValue(from entries: [PathEntry]) -> String {
        entries.map(\.rawText).joined(separator: ":")
    }

    /// 判断原始值里是否含锚点（决定这条 PATH 行是「在既有 PATH 基础上增删」还是「整条替换」）。
    public static func hasAnchor(_ raw: String) -> Bool {
        entries(fromRawValue: raw).contains(where: \.isAnchor)
    }

    /// 把多个 PATH 来源（按文件出现顺序）合并成单一有序列表，保持与逐行求值完全一致的最终语义。
    ///
    /// 逐行求值里 `export PATH="X:$PATH"` 是把 X 前插、`"$PATH:X"` 是后插、无锚点是整条替换。
    /// 合并规则：锚点前的条目并入前插累积区，锚点后的条目并入后插累积区；
    /// 遇到无锚点的行则清空累积区、以该行内容为替换基底。
    /// 最终求值 = 前插区 + 基底（锚点或替换内容）+ 后插区。
    public static func compose(sources: [[PathEntry]]) -> [PathEntry] {
        var prefix: [PathEntry] = []
        var middle: [PathEntry] = []
        var replacement: [PathEntry]?

        for source in sources {
            if let anchorIndex = source.firstIndex(where: { $0.isAnchor }) {
                prefix = Array(source[..<anchorIndex]) + prefix
                middle = middle + Array(source[source.index(after: anchorIndex)...])
            } else {
                replacement = source
                prefix = []
                middle = []
            }
        }

        if let replacement {
            return prefix + replacement + middle
        }
        return prefix + [.anchor] + middle
    }

    /// 便捷入口：直接对若干条 PATH 原始值做语义保持合并，返回合并后的原始值。
    public static func composeRawValues(_ rawValues: [String]) -> String {
        rawValue(from: compose(sources: rawValues.map(entries(fromRawValue:))))
    }
}
