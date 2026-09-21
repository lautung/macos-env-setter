import EnvSetterCore
import SwiftUI

/// 表单控件用的绑定：读当前草稿、写回模型。
/// 变量名一栏不走这里——改名会让「按 key 查找」的绑定中途失效，它用本地草稿 + 提交（见 `RecordDetailView`）。
public extension AppModel {
    func rawValueBinding(for key: String) -> Binding<String> {
        Binding(
            get: { self.entries.record(named: key)?.rawValue ?? "" },
            set: { self.setRawValue($0, for: key) }
        )
    }

    func shellBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { self.entries.record(named: key)?.shellEnabled ?? false },
            set: { self.setLayer(.shell, enabled: $0, for: key) }
        )
    }

    func guiBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { self.entries.record(named: key)?.guiEnabled ?? false },
            set: { self.setLayer(.gui, enabled: $0, for: key) }
        )
    }

    func secretBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { self.entries.record(named: key)?.secret ?? false },
            set: { self.setSecret($0, for: key) }
        )
    }

    func quoteStyleBinding(for key: String) -> Binding<QuoteStyle> {
        Binding(
            get: { self.entries.record(named: key)?.quoteStyle ?? .double },
            set: { self.setQuoteStyle($0, for: key) }
        )
    }

    func pathRowTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { self.pathRows.indices.contains(index) ? self.pathRows[index].text : "" },
            set: { self.setPathRowText($0, at: index) }
        )
    }

    /// 行内输入框用这个：按 id 定位，提交时的归一化拆行/重排不会让它写错行。
    func pathRowTextBinding(forRow id: UUID) -> Binding<String> {
        Binding(
            get: { self.pathRows.first { $0.id == id }?.text ?? "" },
            set: { self.setPathRowText($0, forRow: id) }
        )
    }

    var selectionBinding: Binding<String?> {
        Binding(get: { self.selection }, set: { self.select($0) })
    }

    /// 改名预检：与别的记录重名、或不是合法变量名时给出说明（字段里实时显示）。
    func issueForRename(_ newKey: String, from key: String) -> String? {
        guard newKey != key else { return nil }
        if entries.contains(where: { $0.key == newKey }) { return "同名变量已存在" }
        return RecordValidation.issue(for: VariableRecord(key: newKey, rawValue: ""), duplicateCount: 1)
    }
}
