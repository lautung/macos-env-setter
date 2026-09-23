import EnvSetterCore

/// 移除一条记录会改动哪些写入内容——确认框与移除后的提示条共用同一套判定，两处口径才不会打架。
///
/// 判定依据是「移除后两层的写入内容是否会变」，不是「这条记录是否曾应用过」：
/// 写进两层的只有已应用状态，所以只看它——草稿里刚打开、还没应用的开关并没有写进任何一层，
/// 移除它不会改动任何已写入的内容（那点改动本来就还没落盘）。
///
/// 于是「已应用过、但两层都没启用」的记录（例如测试遗留的那条）移除后
/// 标记块与 gui 域都不会变——文案不许再宣称要从标记块里删掉什么。
/// 从未应用过的记录两层都没写进过任何地方，`touches*` 也都是 false，
/// 文案走「还没应用过」那一路（见 `dialogMessage`）。
public struct RemovalImpact: Equatable, Sendable {
    public let key: String
    /// 记录已在已应用状态里（即「曾应用过」）。不在的话这次移除不产生任何待生效改动。
    public let wasApplied: Bool
    /// 移除会改变标记块里已写入的内容（shell 层涉及）。
    public let touchesShell: Bool
    /// 移除会改变 gui 域里已写入的内容（GUI 层涉及）。
    public let touchesGui: Bool

    private var isPath: Bool { key == VariableKeys.path }

    public init(key: String, saved: VariableRecord?) {
        self.key = key
        wasApplied = saved != nil
        touchesShell = saved?.shellEnabled == true
        touchesGui = saved?.guiEnabled == true
    }

    public func dialogMessage(zprofileLabel: String) -> String {
        guard wasApplied else {
            return "这条记录还没应用过，移除不会影响 \(zprofileLabel)。"
        }
        return "移除先只改内存；" + consequences(zprofileLabel: zprofileLabel).joined()
    }

    public func bannerText(zprofileLabel: String) -> String {
        "已从列表移除 \(key)（待生效）——" + consequences(zprofileLabel: zprofileLabel).joined()
    }

    /// 后果说明本身（不含「先只改内存 / 已从列表移除」这类引导语）：两处逐字共用，口径才一致。
    private func consequences(zprofileLabel: String) -> [String] {
        var sentences: [String] = []
        if touchesShell {
            // PATH 是一整串目录（收编时可能来自好几行 PATH），不能只说「这一行」。
            sentences.append(
                isPath
                    ? "点「应用」后，\(zprofileLabel) 标记块里这条 PATH 记录对应的内容会被删掉"
                        + "——整串目录一并消失（收编时可能来自好几行 PATH），应用前自动备份。"
                    : "点「应用」后，\(zprofileLabel) 标记块里这条记录对应的内容会被删掉（应用前自动备份）。"
            )
        }
        if touchesGui {
            // launchd 没有标记块那样的隔离区：清的理由只是「本工具写过」，边界照旧。
            sentences.append(
                (touchesShell ? "它还会" : "点「应用」时，会把它")
                    + "从 gui 域（launchd）里清掉——只清本工具写过的 key，别的工具设的同名变量不动。"
            )
        }
        if sentences.isEmpty {
            sentences.append(
                "两层写入内容不变：这条记录两层都没启用，\(zprofileLabel) 的标记块与 gui 域里都没有它的内容，"
                    + "这次移除只改列表与本地状态。"
            )
        }
        return sentences
    }
}
