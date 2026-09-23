import Foundation

/// 原始值里的一处 `$` 引用。
public struct ValueReference: Equatable, Sendable {
    /// 被引用的变量名：`$JAVA_HOME` 与 `${JAVA_HOME:-/opt/jdk}` 都给出 `JAVA_HOME`。
    public let name: String
    /// 引用原文——界面上要按它说清「哪一段」。
    public let text: String
    /// 朴素写法（`$NAME` / `${NAME}`）：变量在这一层没有值时，这一段就展开成空。
    /// `${NAME:-默认值}` 这类自带兜底的写法为 false——展开成什么取决于写法本身，不能断言是空。
    public let isPlain: Bool

    public init(name: String, text: String, isPlain: Bool) {
        self.name = name
        self.text = text
        self.isPlain = isPlain
    }
}

/// 原始值里的 `$` 引用扫描——两层写入共用同一套引用语义（见 `ShellLine.quotedValue` 与 `PathList`）。
///
/// 单引号样式里 `$` 是字面量，一个引用也没有；双引号（含裸值）里 `$NAME` 与 `${NAME…}` 都算引用。
/// 原始值里没有「转义掉 `$`」的写法：写回时 `\` 会被转义成 `\\`（`ShellLine.quotedValue`），
/// 所以 `$` 永远是引用；`$$`、`$1`、`$?`、`$(` 这类读不出变量名的写法直接跳过。
public enum ValueReferences {
    /// 按出现顺序列出原始值里的引用（重复出现就重复列出）。
    public static func scan(_ rawValue: String, quoteStyle: QuoteStyle) -> [ValueReference] {
        occurrences(rawValue, quoteStyle: quoteStyle).map(\.reference)
    }

    /// 把 `name` 的引用按「这一层没有它的值」展开后的整条值（`$JAVA_HOME/bin` → `/bin`）。
    ///
    /// 只对朴素写法成立：出现 `${NAME:-…}` 这类自带兜底的写法时返回 nil——那时展开成什么取决于
    /// 写法本身，界面不该给出一个确定的预览。没有该变量的引用时原样返回。
    public static func rendering(_ rawValue: String, quoteStyle: QuoteStyle, emptying name: String) -> String? {
        let matches = occurrences(rawValue, quoteStyle: quoteStyle).filter { $0.reference.name == name }
        guard !matches.isEmpty else { return rawValue }
        guard matches.allSatisfy(\.reference.isPlain) else { return nil }

        var result = ""
        var cursor = rawValue.startIndex
        for match in matches {
            result += rawValue[cursor..<match.range.lowerBound]
            cursor = match.range.upperBound
        }
        result += rawValue[cursor...]
        return result
    }

    // MARK: - Private

    private struct Occurrence {
        var reference: ValueReference
        var range: Range<String.Index>
        /// 记下这一处之后从哪里接着扫：大括号里的内容还要继续扫（`${A:-$B}` 里的 `$B` 也是一处引用）。
        var next: String.Index
    }

    private static func occurrences(_ rawValue: String, quoteStyle: QuoteStyle) -> [Occurrence] {
        guard quoteStyle == .double else { return [] }
        var occurrences: [Occurrence] = []
        var index = rawValue.startIndex

        while index < rawValue.endIndex {
            guard rawValue[index] == "$" else {
                index = rawValue.index(after: index)
                continue
            }
            let after = rawValue.index(after: index)
            let occurrence = after < rawValue.endIndex && rawValue[after] == "{"
                ? bracedOccurrence(rawValue, dollar: index)
                : bareOccurrence(rawValue, dollar: index)
            if let occurrence {
                occurrences.append(occurrence)
                index = occurrence.next
            } else {
                // 读不出变量名（`$$`、`$1`、`$?`、`$(`…）或 `${` 没闭合：`$` 连同后面那个字符整个跳过——
                // 它们是一个完整的特殊参数，再落到第二个 `$` 上会把 `$$A` 读成对 `A` 的引用。
                index = after < rawValue.endIndex ? rawValue.index(after: after) : after
            }
        }
        return occurrences
    }

    private static func bareOccurrence(_ rawValue: String, dollar: String.Index) -> Occurrence? {
        let (name, end) = name(in: rawValue, from: rawValue.index(after: dollar))
        guard ShellLine.isSimpleKey(name) else { return nil }
        return Occurrence(
            reference: ValueReference(name: name, text: "$" + name, isPlain: true),
            range: dollar..<end,
            next: end
        )
    }

    private static func bracedOccurrence(_ rawValue: String, dollar: String.Index) -> Occurrence? {
        let open = rawValue.index(after: dollar)
        let (name, end) = name(in: rawValue, from: rawValue.index(after: open))
        guard ShellLine.isSimpleKey(name), let close = matchingBrace(rawValue, open: open) else { return nil }
        return Occurrence(
            reference: ValueReference(
                name: name,
                text: String(rawValue[dollar...close]),
                // 名字后紧跟 `}`：`${NAME}` 与 `$NAME` 一样，变量没有值时展开成空。
                isPlain: end == close
            ),
            range: dollar..<rawValue.index(after: close),
            next: end
        )
    }

    /// 从 `from` 起读变量名，返回名字与名字之后的位置。
    private static func name(in rawValue: String, from start: String.Index) -> (String, String.Index) {
        var end = start
        var name = ""
        while end < rawValue.endIndex, isNameCharacter(rawValue[end]) {
            name.append(rawValue[end])
            end = rawValue.index(after: end)
        }
        return (name, end)
    }

    /// 与 `open` 处的 `{` 配对的 `}`；`${A:-${B}}` 这样的嵌套也认。
    private static func matchingBrace(_ rawValue: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < rawValue.endIndex {
            switch rawValue[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = rawValue.index(after: index)
        }
        return nil
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
