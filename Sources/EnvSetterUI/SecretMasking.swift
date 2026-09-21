import EnvSetterCore
import Foundation

/// 秘密值的打码展示。
public enum SecretMasking {
    public static let mask = "••••••••"

    /// 打码文本：保留前 4 个字符作为「这是哪一条」的线索；太短的值整条打码——
    /// 短值露出前几位等于把大半条泄露出去。
    public static func masked(_ rawValue: String) -> String {
        rawValue.count >= 8 ? String(rawValue.prefix(4)) + mask : mask
    }

    /// 列表预览与详情展示共用的文本。
    public static func preview(_ record: VariableRecord, revealed: Bool) -> String {
        record.secret && !revealed ? masked(record.rawValue) : record.rawValue
    }
}

/// 草稿的写入前校验：把引擎会拒绝的情况在界面上先说清楚，并挡住应用按钮。
/// 规则与 `EnvSetterEngine.validate` 一一对应，外加一条引擎不管、但写出来必然踩坑的「同名重复」。
public enum RecordValidation {
    public static func issues(in entries: [ManagedEntry]) -> [String: String] {
        let records = entries.records
        var counts: [String: Int] = [:]
        for record in records { counts[record.key, default: 0] += 1 }

        var issues: [String: String] = [:]
        for record in records {
            if let issue = issue(for: record, duplicateCount: counts[record.key] ?? 1) {
                issues[record.key] = issue
            }
        }
        return issues
    }

    public static func issue(for record: VariableRecord, duplicateCount: Int = 1) -> String? {
        if record.key.isEmpty { return "变量名不能为空" }
        guard ShellLine.isSimpleKey(record.key) else {
            return "变量名只能用字母、数字、下划线，且不能以数字开头"
        }
        if duplicateCount > 1 {
            return "变量名重复：标记块里会出现两条同名 export，后一条覆盖前一条"
        }
        if record.rawValue.contains("\n") || record.rawValue.contains("\r") {
            return "原始值不能包含换行"
        }
        if record.quoteStyle == .single, record.rawValue.contains("'") {
            return "单引号样式表示不了撇号，请改用双引号（或去掉撇号）"
        }
        return nil
    }
}
