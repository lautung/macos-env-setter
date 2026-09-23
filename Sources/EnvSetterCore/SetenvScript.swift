import Foundation

/// GUI 层脚本（`setenv.sh`）：工具生成、由 LaunchAgent 在登录时执行，把变量注入 launchd 的 gui 域。
///
/// 两段式，与 shell 层标记块共用同一套引用语义：
/// 1. 先按声明顺序做 shell 变量赋值——`$` 引用（含 `${…}`）在这一步展开，`$PATH` 锚点展开为脚本进程继承到的 PATH（登录时即 launchd 的默认 PATH）；
/// 2. 再逐条 `/bin/launchctl setenv KEY "$KEY"`，取赋值结果注入 gui 域（用绝对路径，不受脚本内 PATH 赋值影响）。
///
/// `--print` 只打印将要注入的 `KEY=VALUE`、不调用 launchctl，供应用后的回读自检与诊断比对期望值。
public enum SetenvScript {
    public static let fileName = "setenv.sh"
    public static let printFlag = "--print"

    static let assignmentsHeader = "# —— 按声明顺序赋值（$ 引用在这里展开）——"
    static let injectionHeader = "# —— 注入 launchd 的 gui 域 ——"
    static let emptyNote = "# （当前没有启用 GUI 层的变量）"

    /// 参与 GUI 层的记录：按声明顺序列出 `guiEnabled` 为真的 key。
    /// 逐字保留行属于 shell 层块内内容，不进 GUI 层。
    public static func enabledKeys(entries: [ManagedEntry]) -> [String] {
        guiRecords(entries).map(\.key)
    }

    /// 生成完整脚本内容。
    public static func generate(entries: [ManagedEntry], label: String = LaunchAgent.defaultLabel) -> String {
        let records = guiRecords(entries)
        var lines: [String] = [
            "#!/bin/sh",
            "# 由 EnvSetter 生成，每次「应用」整份重写——请勿手工编辑。",
            "# 执行时机：登录时由 LaunchAgent（\(label)）运行，把下列变量注入 launchd 的 gui 域。",
            "# 值里的 $ 引用按声明顺序展开；PATH 的 $PATH 锚点是 launchd 的默认 PATH，与终端里的不同。",
            "# 诊断：setenv.sh \(printFlag) 打印将要注入的 KEY=VALUE（不调用 launchctl）。",
            "",
            assignmentsHeader,
        ]
        if records.isEmpty {
            lines.append(emptyNote)
        } else {
            for record in records {
                lines.append(
                    ShellLine.assignment(
                        key: record.key, rawValue: record.rawValue, quoteStyle: record.quoteStyle
                    )
                )
            }
        }

        lines.append("")
        lines.append(injectionHeader)
        lines.append("if [ \"$1\" = \"\(printFlag)\" ]; then")
        for record in records {
            lines.append("    printf '%s=%s\\n' \(record.key) \"$\(record.key)\"")
        }
        lines.append("    exit 0")
        lines.append("fi")
        lines.append("")
        if records.isEmpty {
            lines.append(emptyNote)
        } else {
            for record in records {
                lines.append("\(LaunchAgent.launchctlPath) setenv \(record.key) \"$\(record.key)\"")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 解析脚本实际注入的 key（本工具自己写出的格式：`/bin/launchctl setenv KEY "…"`）。
    /// 用于知道「上次同步了哪些 key」——关闭某条变量的 GUI 开关时据此清理 gui 域里的残留。
    public static func appliedKeys(in content: String) -> [String] {
        let prefix = "\(LaunchAgent.launchctlPath) setenv "
        var keys: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            guard let key = trimmed.dropFirst(prefix.count).split(separator: " ").first else { continue }
            let name = String(key)
            guard ShellLine.isSimpleKey(name), !keys.contains(name) else { continue }
            keys.append(name)
        }
        return keys
    }

    /// 解析 `--print` 的输出为「期望值」表。只取第一处 `=` 切分；无法解析的行跳过，
    /// 让调用方对拿不到期望值的 key 保持沉默，而不是误报不一致。
    public static func parsePrintedValues(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            guard ShellLine.isSimpleKey(key) else { continue }
            values[key] = String(line[line.index(after: separator)...])
        }
        return values
    }

    private static func guiRecords(_ entries: [ManagedEntry]) -> [VariableRecord] {
        entries.compactMap { entry in
            guard case .record(let record) = entry, record.guiEnabled else { return nil }
            return record
        }
    }
}
