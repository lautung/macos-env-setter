import Foundation

/// PATH 编辑器的行草稿与生命周期。`AppModel.entries` 仍是待生效原始值的唯一来源；
/// 这里仅管理编辑呈现状态，并从调用方提供的当前原始值重建。
struct PathDraft {
    private(set) var rows: [PathRow] = []
    private var isLoaded = false

    var duplicateIDs: Set<UUID> { PathEditor.duplicateIDs(rows) }
    var anchorCount: Int { PathEditor.anchorCount(rows) }

    func hasSemanticChange(from currentRawValue: String, to editedRawValue: String) -> Bool {
        PathEditor.changesSemantics(
            currentRawValue: currentRawValue,
            rows: PathEditor.rows(fromRawValue: editedRawValue)
        )
    }

    func index(of id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    mutating func synchronize(with rawValue: String?) {
        rows = rawValue.map(PathEditor.rows(fromRawValue:)) ?? []
        isLoaded = true
    }

    /// 首次收到行编辑时保护尚未从记录加载的草稿，避免空行误写掉非空 PATH。
    mutating func prepareForEditing(currentRawValue: String) -> Bool {
        guard !isLoaded else { return true }
        synchronize(with: currentRawValue)
        return currentRawValue.isEmpty
    }

    mutating func setText(_ text: String, for id: UUID) -> String? {
        guard let index = index(of: id), !rows[index].isAnchor else { return nil }
        rows[index].text = text
        return PathEditor.rawValue(from: rows)
    }

    mutating func addEntry(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        rows.append(PathRow(text: trimmed))
        normalizeRowsPreservingIdentity()
        return PathEditor.rawValue(from: rows)
    }

    mutating func addAnchor() -> String? {
        guard anchorCount == 0 else { return nil }
        rows.append(PathRow(text: "$PATH", isAnchor: true))
        return PathEditor.rawValue(from: rows)
    }

    func canRemove(_ id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        return !rows[index].isAnchor || anchorCount > 1
    }

    mutating func remove(_ id: UUID) -> String? {
        guard canRemove(id), let index = index(of: id) else { return nil }
        rows.remove(at: index)
        return PathEditor.rawValue(from: rows)
    }

    mutating func move(_ id: UUID, by delta: Int) -> String? {
        guard let index = index(of: id) else { return nil }
        let destination = index + delta
        guard rows.indices.contains(destination) else { return nil }
        rows.swapAt(index, destination)
        return PathEditor.rawValue(from: rows)
    }

    mutating func reorder(to rowIDs: [UUID]) -> String? {
        guard rowIDs.count == rows.count,
              Set(rowIDs) == Set(rows.map(\.id)),
              rowIDs != rows.map(\.id)
        else { return nil }

        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = rowIDs.compactMap { rowsByID[$0] }
        return PathEditor.rawValue(from: rows)
    }

    mutating func commit() -> String? {
        let previousRows = rows
        normalizeRowsPreservingIdentity()
        guard !PathEditor.sameStructure(previousRows, rows) else { return nil }
        return PathEditor.rawValue(from: rows)
    }

    private mutating func normalizeRowsPreservingIdentity() {
        rows = rows.flatMap { row in
            let normalized = PathEditor.rows(fromRawValue: row.isAnchor ? "$PATH" : row.text)
            return normalized.enumerated().map { index, part in
                PathRow(
                    id: index == 0 ? row.id : UUID(),
                    text: part.text,
                    isAnchor: part.isAnchor
                )
            }
        }
    }
}
