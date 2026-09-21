import Foundation

/// 一条待收编的块外 export 行的落点。
public struct OutsideEdit: Equatable, Sendable, Codable {
    /// 计划时的行号（0 起）。
    public let lineIndex: Int
    /// 该行原文，用于写入前校验文件没在计划之后被改动。
    public let originalLine: String
    /// 注释掉之后的替换文本。
    public let replacementLine: String
}

public struct SkippedLine: Equatable, Sendable {
    public let lineIndex: Int
    public let line: String
    public let reason: String
}

/// 收编计划：合并后的完整条目列表 + 块外行注释计划。编辑仍只在内存，应用时才落盘。
public struct AdoptionPlan: Equatable, Sendable {
    public var entries: [ManagedEntry]
    public var outsideEdits: [OutsideEdit]
    /// 本次实际收编的 key（按收编顺序，PATH 除外）。
    public var adoptedKeys: [String]
    /// 合并进 PATH 有序列表的块外 PATH 行数。
    public var mergedPathLineCount: Int
    /// 看起来像 export 但无法安全解析、保持原样的行。
    public var skipped: [SkippedLine]
}

/// 收编：扫描标记块外用户手写的简单 `export` 行，接管为变量记录。
/// PATH 行不单独成记录，而是按文件顺序语义保持地合并进 PATH 专用有序列表；
/// 原行注释掉，保留手工回退路径；收编变量 GUI 开关默认关。
public enum AdoptionScanner {
    public static func plan(
        fileContent: String,
        currentEntries: [ManagedEntry]
    ) throws -> AdoptionPlan {
        let location = try MarkerBlock.locate(in: fileContent)
        let file = FileText(fileContent)

        var outsideEdits: [OutsideEdit] = []
        var adoptedKeys: [String] = []
        var skipped: [SkippedLine] = []
        var newRecords: [VariableRecord] = []
        var newRecordIndexByKey: [String: Int] = [:]
        // PATH 来源：按文件出现顺序收集的原始值（含已有的 PATH 记录）。
        var pathSources: [(position: Int, rawValue: String)] = []
        var outsidePathLineCount = 0

        let managedKeys = Set(currentEntries.compactMap(\.key))
        var touchedManagedKeys = Set<String>()
        for entry in currentEntries {
            if case .record(let record) = entry, record.key == VariableKeys.path {
                // 有块：块记录的文件位置 = 块首；无块：视为先于一切块外行。
                let position = location?.beginLineIndex ?? -1
                pathSources.append((position, record.rawValue))
            }
        }

        for index in 0..<file.lineCount {
            if let location, index >= location.beginLineIndex && index <= location.endLineIndex {
                continue
            }
            let line = file.line(at: index)!
            if let parsed = ShellLine.parseExportLine(line) {
                outsideEdits.append(
                    OutsideEdit(lineIndex: index, originalLine: line, replacementLine: "# " + line)
                )
                if parsed.key == VariableKeys.path {
                    outsidePathLineCount += 1
                    pathSources.append((index, parsed.rawValue))
                    continue
                }
                if managedKeys.contains(parsed.key) {
                    // 与工具已有记录同名：zsh 后写覆盖，值取文件里的这一条。
                    touchedManagedKeys.insert(parsed.key)
                    continue
                }
                if let existing = newRecordIndexByKey[parsed.key] {
                    newRecords[existing].rawValue = parsed.rawValue
                    newRecords[existing].quoteStyle = parsed.quoteStyle
                    continue
                }
                newRecordIndexByKey[parsed.key] = newRecords.count
                adoptedKeys.append(parsed.key)
                newRecords.append(
                    VariableRecord(
                        key: parsed.key,
                        rawValue: parsed.rawValue,
                        shellEnabled: true,
                        guiEnabled: false,
                        // 一眼是凭据的 key 默认打码；只是展示偏好，判断错了用户取消勾选即可。
                        secret: SecretKeys.looksSecret(parsed.key),
                        source: .adopted,
                        quoteStyle: parsed.quoteStyle
                    )
                )
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("export") {
                skipped.append(
                    SkippedLine(lineIndex: index, line: line, reason: "复杂行不收编，保持原样")
                )
            }
        }

        // 已有记录里被块外同名行覆盖的，值取块外最后一次出现的值（zsh 后写覆盖）。
        var mergedEntries = currentEntries
        if !touchedManagedKeys.isEmpty {
            for index in mergedEntries.indices {
                if case .record(var record) = mergedEntries[index],
                    touchedManagedKeys.contains(record.key),
                    let outside = lastOutsideValue(key: record.key, file: file, edits: outsideEdits)
                {
                    record.rawValue = outside.rawValue
                    record.quoteStyle = outside.quoteStyle
                    mergedEntries[index] = .record(record)
                }
            }
        }

        let adoptedEntries: [ManagedEntry] = newRecords.map { .record($0) }
        if location == nil {
            // 没有标记块也要保留既有条目：GUI 专属与 shell 关闭的记录只存在本地状态里，
            // 收编计划丢弃它们会让下一次应用把这些记录从 store 里抹掉。
            mergedEntries.append(contentsOf: adoptedEntries)
        } else if !adoptedEntries.isEmpty {
            mergedEntries.append(contentsOf: adoptedEntries)
        }

        // PATH 合并：所有来源按文件位置排序后合成一条记录。
        if !pathSources.isEmpty {
            let ordered = pathSources.sorted { $0.position < $1.position }.map(\.rawValue)
            let mergedRaw = PathList.composeRawValues(ordered)
            upsertPathRecord(rawValue: mergedRaw, in: &mergedEntries, moveToEnd: location != nil)
        }

        return AdoptionPlan(
            entries: mergedEntries,
            outsideEdits: outsideEdits,
            adoptedKeys: adoptedKeys,
            mergedPathLineCount: outsidePathLineCount,
            skipped: skipped
        )
    }

    // MARK: - Private

    private static func lastOutsideValue(key: String, file: FileText, edits: [OutsideEdit]) -> ParsedExport? {
        var value: ParsedExport?
        for edit in edits {
            guard let line = file.line(at: edit.lineIndex),
                let parsed = ShellLine.parseExportLine(line), parsed.key == key
            else { continue }
            value = parsed
        }
        return value
    }

    private static func upsertPathRecord(
        rawValue: String,
        in entries: inout [ManagedEntry],
        moveToEnd: Bool
    ) {
        if let index = entries.firstIndex(where: { entry in
            if case .record(let record) = entry { return record.key == VariableKeys.path }
            return false
        }) {
            var record = VariableRecord(key: VariableKeys.path, rawValue: rawValue)
            if case .record(let existing) = entries[index] {
                record.guiEnabled = existing.guiEnabled
                record.source = existing.source
            }
            // PATH 的 rawValue 携带 `$PATH` 锚点，必须展开：强制双引号样式。
            record.quoteStyle = .double
            entries[index] = .record(record)
            // 收编变量必须先于 PATH 声明，PATH 里的 `$` 引用登录时才能展开。
            if moveToEnd, index != entries.count - 1 {
                entries.append(entries.remove(at: index))
            }
        } else {
            entries.append(
                .record(
                    VariableRecord(
                        key: VariableKeys.path,
                        rawValue: rawValue,
                        shellEnabled: true,
                        guiEnabled: false,
                        source: .adopted,
                        quoteStyle: .double
                    )
                )
            )
        }
    }
}
