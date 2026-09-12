import Foundation

public enum VariableKeys {
    public static let path = "PATH"
}

/// 标记块：`~/.zprofile` 中由标记注释围起、工具独占读写的区域。
/// 解析、生成与整块替换；块外内容字节级不动。
public enum MarkerBlock {
    public static let beginMarker = "# >>> EnvSetter >>>"
    public static let endMarker = "# <<< EnvSetter <<<"
    static let headerComment = "# 本块由 EnvSetter 管理：请在应用内编辑；块外内容不受影响。"
    static let typesetLine = "typeset -U path PATH"

    public struct Location: Equatable, Sendable {
        /// 含首尾标记行的完整块文本（漂移检测比对的就是它）。
        public let fullText: String
        /// 首尾标记之间的内容（不含标记行本身）。
        public let innerContent: String
        let beginLineIndex: Int
        let endLineIndex: Int
    }

    /// 在文件内容中定位标记块。无块返回 nil；标记不成对或重复即畸形，抛错并拒绝改写。
    public static func locate(in content: String) throws -> Location? {
        let file = FileText(content)
        var beginLine: Int?
        for (index, line) in file.lines.enumerated() {
            guard line.trimmingCharacters(in: .whitespaces) == beginMarker else { continue }
            if beginLine != nil { throw EngineError.malformedMarkerBlock }
            beginLine = index
        }
        guard let begin = beginLine else { return nil }

        var endLine: Int?
        for index in (begin + 1)..<file.lineCount {
            if file.lines[index].trimmingCharacters(in: .whitespaces) == endMarker {
                endLine = index
                break
            }
        }
        guard let end = endLine else { throw EngineError.malformedMarkerBlock }

        let inner = file.rangeOfLines(from: begin + 1, to: end)
        let full = file.rangeOfLinesClosed(from: begin, to: end)
        return Location(
            fullText: String(content[full]),
            innerContent: String(content[inner]),
            beginLineIndex: begin,
            endLineIndex: end
        )
    }

    /// 把块内容解析回条目列表。工具自己写入的模板行（头注释、typeset）被丢弃，
    /// 其余行要么解析为变量记录，要么逐字保留。
    public static func parse(innerContent: String) -> [ManagedEntry] {
        var entries: [ManagedEntry] = []
        for line in FileText(innerContent).lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == headerComment || trimmed == beginMarker || trimmed == endMarker {
                continue
            }
            if trimmed == typesetLine || trimmed.hasPrefix("typeset -U") { continue }
            if let parsed = ShellLine.parseExportLine(line) {
                entries.append(
                    .record(
                        VariableRecord(
                            key: parsed.key,
                            rawValue: parsed.rawValue,
                            shellEnabled: true,
                            guiEnabled: false,
                            source: .adopted,
                            quoteStyle: parsed.quoteStyle
                        )
                    )
                )
            } else {
                entries.append(.verbatim(line: line))
            }
        }
        return entries
    }

    /// 由条目列表生成完整块文本（含首尾标记）。头部说明与 `typeset -U` 是模板固定内容。
    /// shell 关闭的记录不写入块——块就是 shell 层；GUI 专属记录只活在本地状态里。
    public static func generate(entries: [ManagedEntry]) -> String {
        var lines: [String] = [beginMarker, headerComment, typesetLine]
        for entry in entries {
            switch entry {
            case .record(let record):
                guard record.shellEnabled else { continue }
                lines.append(
                    ShellLine.exportLine(key: record.key, rawValue: record.rawValue, quoteStyle: record.quoteStyle)
                )
            case .verbatim(let line):
                lines.append(line)
            }
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// 用新块整块替换文件中的现有块；块外内容字节级不动（含块后的换行）。
    public static func splice(original: String, location: Location, newBlock: String) -> String {
        let file = FileText(original)
        var result = original
        result.replaceSubrange(
            file.rangeOfLinesClosed(from: location.beginLineIndex, to: location.endLineIndex),
            with: newBlock
        )
        return result
    }

    /// 文件中没有块时，把新块追加到文件末尾。
    public static func append(original: String, newBlock: String) -> String {
        if original.isEmpty {
            return newBlock + "\n"
        }
        let file = FileText(original)
        return file.endsWithNewline ? original + newBlock + "\n" : original + "\n" + newBlock + "\n"
    }
}
