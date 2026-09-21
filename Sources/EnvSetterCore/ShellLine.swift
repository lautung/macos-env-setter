import Foundation

/// 一行可解析的简单 `export KEY=value`。
public struct ParsedExport: Equatable, Sendable {
    public let key: String
    public let rawValue: String
    /// 值的引用语义：单引号 = `$` 是字面量；双引号/裸值 = `$` 照常展开。
    public let quoteStyle: QuoteStyle
}

/// shell 行的解析与生成。只认「简单 export 行」：
/// `export KEY=value`、`export KEY="value"`、`export KEY='value'`（尾部可带注释）。
/// 复杂行（多赋值、命令替换裸写、缺 `=`）一律返回 nil，由调用方保持原样、绝不重写。
public enum ShellLine {
    public static func isSimpleKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    public static func parseExportLine(_ line: String) -> ParsedExport? {
        var rest = Substring(line)

        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
        guard rest.hasPrefix("export") else { return nil }
        rest = rest.dropFirst("export".count)
        guard let afterKeyword = rest.first, afterKeyword == " " || afterKeyword == "\t" else {
            return nil
        }
        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }

        var key = ""
        while let first = rest.first, first.isLetter || first.isNumber || first == "_" {
            key.append(first)
            rest = rest.dropFirst()
        }
        guard isSimpleKey(key), rest.first == "=" else { return nil }
        rest = rest.dropFirst()

        // 值必须紧跟 `=`：引号开头，或非空白字符开头。
        guard let valueStart = rest.first else {
            return ParsedExport(key: key, rawValue: "", quoteStyle: .double)
        }
        if valueStart == "\"" || valueStart == "'" {
            let (rawValue, remainder) = parseQuoted(from: rest)
            guard let rawValue, remainderTrimmedIsBlankOrComment(remainder) else { return nil }
            return ParsedExport(
                key: key,
                rawValue: rawValue,
                quoteStyle: valueStart == "'" ? .single : .double
            )
        }
        guard valueStart != " " && valueStart != "\t" else { return nil }

        var rawValue = ""
        while let first = rest.first, first != " " && first != "\t" {
            rawValue.append(first)
            rest = rest.dropFirst()
        }
        guard remainderTrimmedIsBlankOrComment(rest) else { return nil }
        return ParsedExport(key: key, rawValue: rawValue, quoteStyle: .double)
    }

    /// 生成 `export KEY="value"`（`.double`）或 `export KEY='value'`（`.single`）。
    public static func exportLine(key: String, rawValue: String, quoteStyle: QuoteStyle = .double) -> String {
        "export " + assignment(key: key, rawValue: rawValue, quoteStyle: quoteStyle)
    }

    /// 生成不带 `export` 的赋值 `KEY="value"` / `KEY='value'`。
    /// GUI 层脚本（`setenv.sh`）复用同一套引用语义，两层的 `$` 展开结果才一致。
    ///
    /// 双引号内保留 `$` 引用原文（让其照常展开），只转义双引号语义中真正需要转义的字符：`\`、`"`、反引号。
    /// 单引号内一切字面：`$` 不展开，原样往返（单引号值本身不可能含 `'`）。
    public static func assignment(key: String, rawValue: String, quoteStyle: QuoteStyle = .double) -> String {
        switch quoteStyle {
        case .double: return "\(key)=\(quotedValue(rawValue))"
        case .single: return "\(key)='\(rawValue)'"
        }
    }

    public static func quotedValue(_ raw: String) -> String {
        var out = "\""
        for ch in raw {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "`": out += "\\`"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }

    // MARK: - Private

    /// 解析引号值。返回解出来的原始值文本与引号之后的余下部分；解析失败返回 nil。
    private static func parseQuoted(from rest: Substring) -> (String?, Substring) {
        let quote = rest.first!
        var body = ""
        var index = rest.index(after: rest.startIndex)
        if quote == "'" {
            // 单引号内无任何转义，`\` 也是字面量。
            while index < rest.endIndex, rest[index] != "'" {
                body.append(rest[index])
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else { return (nil, rest) }
            return (body, rest[rest.index(after: index)...])
        }
        // 双引号：zsh 只在 `\$` `\`` `\"` `\\` 与行尾续行时移除反斜杠，其余 `\x` 原样保留。
        while index < rest.endIndex {
            let ch = rest[index]
            if ch == "\"" {
                return (body, rest[rest.index(after: index)...])
            }
            if ch == "\\" {
                let nextIndex = rest.index(after: index)
                if nextIndex < rest.endIndex {
                    let next = rest[nextIndex]
                    if next == "$" || next == "`" || next == "\"" || next == "\\" {
                        body.append(next)
                        index = rest.index(after: nextIndex)
                        continue
                    }
                }
                body.append(ch)
                index = nextIndex
                continue
            }
            body.append(ch)
            index = rest.index(after: index)
        }
        return (nil, rest) // 引号未闭合
    }

    private static func remainderTrimmedIsBlankOrComment(_ rest: Substring) -> Bool {
        var rest = rest
        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
        return rest.isEmpty || rest.first == "#"
    }
}
