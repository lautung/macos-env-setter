import EnvSetterCore

/// 一条记录在 GUI 层「引用不到某个变量」的警告。
///
/// **非阻塞**：它不参与 `canApply`，只把「这一段在 GUI 层没有值」说出来；挡住应用的仍然只有校验错误。
///
/// 两种成因合并成同一条警告——被引用的记录没开 GUI 开关，或排在引用者后面
/// （GUI 层脚本按声明顺序逐条赋值，`$` 引用只能看到排在它前面的变量）。
///
/// 只在 GUI 层算：GUI 层脚本是本工具独有的写入面，脚本里没赋值的引用在那个脚本里没有别的来源；
/// shell 层标记块之外还有用户手写内容，同样的报警会变成误报。
public struct GuiReferenceWarning: Identifiable, Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// 被引用的记录没开 GUI 开关：GUI 层脚本里不会给它赋值。
        case layerOff
        /// 被引用的记录开了 GUI 开关，但排在引用者后面：赋值时它还看不见。
        case declaredLater
    }

    /// 被引用的那条记录（在列表里）。
    public var referencedKey: String
    public var cause: Cause
    /// 值里触发这条警告的引用原文（如 `$JAVA_HOME`），按出现顺序去重。
    public var occurrences: [String]
    /// 把这条引用按空展开后的整条值（`$JAVA_HOME/bin` → `/bin`）；
    /// 写法自带兜底（`${NAME:-…}`）时为 nil——展开成什么取决于写法本身。
    /// 秘密值（且没点「显示」）时已打码，与列表预览同一套规则。
    public var rendering: String?

    public var id: String { referencedKey }

    /// 列表行的悬停提示：一句话说清「哪条变量、为什么」。
    public var summary: String { wording.summary }

    /// 详情区的标题。
    public var title: String { wording.title }

    /// 详情区的一行。`preview` 是「会展开成什么」的值预览——整条值可能很长，
    /// 单独占一行、等宽展示，才不至于把解释埋在一大段文字里。
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case text
            case preview
        }

        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// 详情区的完整解释：哪一段、会展开成什么、怎么修。
    public var lines: [Line] {
        var lines: [Line] = [Line(kind: .text, text: wording.cause)]
        switch rendering {
        case .none:
            lines.append(
                Line(
                    kind: .text,
                    text: "值里的 \(occurrenceText) 因此在 GUI 层拿不到 \(referencedKey) 的值："
                        + "展开成什么取决于这个写法本身。"
                )
            )
        case .some(""):
            lines.append(Line(kind: .text, text: consequence + "——整条值会变成空。"))
        case .some(let rendered):
            lines.append(Line(kind: .text, text: consequence + "——整条值会变成："))
            lines.append(Line(kind: .preview, text: rendered))
        }
        lines.append(Line(kind: .text, text: hedge))
        lines.append(Line(kind: .text, text: wording.fix))
        return lines
    }

    /// 单行版（悬停提示、测试断言用）：各段之间用换行接起来。
    public var detail: String { lines.map(\.text).joined(separator: "\n") }

    // MARK: - Private

    /// 一种成因的整套措辞。集中在一处，两种成因才好并排比对——
    /// 「哪一段、会展开成什么、怎么修」三件事在两条路上都要说全。
    private struct Wording {
        var title: String
        var summary: String
        var cause: String
        var fix: String
    }

    private var wording: Wording {
        switch cause {
        case .layerOff:
            return Wording(
                title: "GUI 层引用不到「\(referencedKey)」",
                summary: "GUI 层引用不到 \(referencedKey)：它没开 GUI 开关",
                cause: "「\(referencedKey)」没开 GUI 开关：GUI 层脚本（setenv.sh）里不会给它赋值。",
                fix: "修法：给「\(referencedKey)」打开 GUI 开关，或去掉这段引用。"
            )
        case .declaredLater:
            return Wording(
                title: "「\(referencedKey)」排在后面，GUI 层里看不到它",
                summary: "GUI 层引用不到 \(referencedKey)：它排在后面，引用只能看到排在它前面的变量",
                cause: "「\(referencedKey)」开了 GUI 开关，但排在当前变量后面：脚本按声明顺序逐条赋值——"
                    + "引用只能看到排在它前面的变量，赋值时它还看不见。",
                fix: "修法：把「\(referencedKey)」上移到本变量前面（列表顺序就是写入顺序），或去掉这段引用。"
            )
        }
    }

    /// 触发警告的引用原文，多个用顿号连起来。
    private var occurrenceText: String { occurrences.joined(separator: "、") }

    /// 后果：哪一段、会展开成什么。
    private var consequence: String {
        "值里的 \(occurrenceText) 因此在 GUI 层没有值：这一层没有别的来源时，这一段会展开成空"
    }

    /// 话里留着余地：gui 域里可能有别处设过的同名变量，不能把话说成绝对错误。
    private var hedge: String {
        "gui 域里若已由别的工具设过 \(referencedKey)，则不一定是空的。"
    }
}

/// 草稿里的 GUI 层引用警告：按记录 key 索引，供列表行与详情区取用。
public enum GuiReferenceWarnings {
    /// 逐条记录算出它在 GUI 层引用不到的变量。
    ///
    /// 判定的都是「这段引用在 GUI 层脚本里能不能拿到值」：
    /// 被引用的记录没开 GUI 开关（脚本里根本不赋值）、或排在引用者后面（赋值时还没值）。
    ///
    /// `revealedKey` 是当前临时显示明文的那条记录：秘密值的值预览按列表预览那套规则打码，
    /// 免得警告卡片成为绕过打码的探针（打码只影响展示，判定与文案不受影响）。
    public static func warnings(in entries: [ManagedEntry], revealedKey: String? = nil) -> [String: [GuiReferenceWarning]] {
        let positions = positionsByKey(entries)
        var warnings: [String: [GuiReferenceWarning]] = [:]

        for (index, entry) in entries.enumerated() {
            guard case .record(let record) = entry, record.guiEnabled else { continue }
            var found: [GuiReferenceWarning] = []
            for reference in grouped(ValueReferences.scan(record.rawValue, quoteStyle: record.quoteStyle)) {
                // 自引用是合法惯用法（`${RUBYOPT:+ $RUBYOPT}`）；PATH 锚点是锚点，不是对记录的引用。
                guard reference.name != record.key, reference.name != VariableKeys.path else { continue }
                // 不是列表里的记录（外部环境变量）——它在 gui 域里可能是有的，不报警。
                guard let targetIndex = positions[reference.name],
                    case .record(let target) = entries[targetIndex]
                else { continue }

                let cause: GuiReferenceWarning.Cause
                if !target.guiEnabled {
                    cause = .layerOff
                } else if targetIndex > index {
                    cause = .declaredLater
                } else {
                    continue  // 开了 GUI 开关、又排在前面：这一段在脚本里拿得到值
                }
                found.append(
                    GuiReferenceWarning(
                        referencedKey: reference.name,
                        cause: cause,
                        occurrences: reference.occurrences,
                        rendering: rendering(
                            for: record, emptying: reference.name, revealedKey: revealedKey
                        )
                    )
                )
            }
            if !found.isEmpty { warnings[record.key] = found }
        }
        return warnings
    }

    // MARK: - Private

    /// 值预览。秘密值且没点「显示」时打码：与列表预览、详情「原始值」同一条规则。
    private static func rendering(
        for record: VariableRecord,
        emptying name: String,
        revealedKey: String?
    ) -> String? {
        guard
            let rendering = ValueReferences.rendering(
                record.rawValue, quoteStyle: record.quoteStyle, emptying: name
            )
        else { return nil }
        guard record.secret, record.key != revealedKey else { return rendering }
        return SecretMasking.masked(rendering)
    }

    /// 声明顺序（= 写入顺序）里的位置，按 key 索引；重复 key 取第一条（重复本身是校验错误）。
    private static func positionsByKey(_ entries: [ManagedEntry]) -> [String: Int] {
        var positions: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            guard let key = entry.key, positions[key] == nil else { continue }
            positions[key] = index
        }
        return positions
    }

    /// 按被引用的变量名归拢，保留首次出现的顺序：同一条记录里一个变量只报一次警告。
    private static func grouped(_ references: [ValueReference]) -> [(name: String, occurrences: [String])] {
        var order: [String] = []
        var texts: [String: [String]] = [:]
        for reference in references {
            if texts[reference.name] == nil {
                order.append(reference.name)
                texts[reference.name] = []
            }
            if !(texts[reference.name] ?? []).contains(reference.text) {
                texts[reference.name, default: []].append(reference.text)
            }
        }
        return order.map { (name: $0, occurrences: texts[$0] ?? []) }
    }
}
