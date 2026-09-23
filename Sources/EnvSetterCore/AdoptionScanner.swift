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
        // 只记录当前文件里的实际赋值；本地记录若关闭 shell 层，不会在块中赋值。
        let blockEntries = location.map { MarkerBlock.parse(innerContent: $0.innerContent) } ?? []
        let blockAssignedKeys = Set(blockEntries.compactMap(\.key))
        // 块内那些看不懂的行里提到的 key：工具不知道它们到底有没有被赋值，所以不猜——
        // 这些 key 的块外同名赋值一律保持原样、本次不收编（见下面循环里的跳过分支）。
        let blockMayAssign = Set(
            blockEntries.flatMap { entry -> [String] in
                guard case .verbatim(let line) = entry else { return [] }
                return mentionedKeys(in: line)
            }
        ).subtracting(blockAssignedKeys)
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
                // 块内有一行看不懂的内容可能也给这个 key 赋值：不猜谁最后生效。
                // 原行保持原样（不注释、不改记录、不收编），计划里报出来让人自己决定。
                if parsed.key != VariableKeys.path, let location, index < location.beginLineIndex,
                    blockMayAssign.contains(parsed.key)
                {
                    skipped.append(
                        SkippedLine(
                            lineIndex: index,
                            line: line,
                            reason: "块内有一行看不懂的内容可能也给 \(parsed.key) 赋值，不猜谁最后生效"
                        )
                    )
                    continue
                }
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

        // 已有记录只由它后面的块外赋值覆盖。块前的同名 export 会被标记块内赋值覆盖，
        // 收编后这些行会注释掉，故应保留块内值；块后的 export 则仍是最后一次赋值。
        // （块内只有看不懂的行可能赋值的 key 上面已按「不猜」跳过，不会走到这里。）
        var mergedEntries = currentEntries
        if !touchedManagedKeys.isEmpty {
            for index in mergedEntries.indices {
                if case .record(var record) = mergedEntries[index],
                    touchedManagedKeys.contains(record.key),
                    let outside = lastOutsideValue(
                        key: record.key,
                        file: file,
                        edits: outsideEdits,
                        afterLineIndex: blockAssignedKeys.contains(record.key) ? location?.endLineIndex : nil
                    )
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

    /// 一行看不懂的内容里可能被赋值的 key（`KEY=` 形态的 token）。
    /// 只用来决定「这次不动它」，绝不用来定值——假命中的代价是少收编一条 + 一条提示，
    /// 而猜错的代价是悄悄改掉一个环境变量的生效值。
    private static func mentionedKeys(in line: String) -> [String] {
        let characters = Array(line)
        var keys: [String] = []
        var index = 0
        while index < characters.count {
            guard isKeyStart(characters[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isKeyCharacter(characters[end]) { end += 1 }
            if end < characters.count, characters[end] == "=" {
                let candidate = String(characters[index..<end])
                if ShellLine.isSimpleKey(candidate) { keys.append(candidate) }
            }
            index = max(end, index + 1)
        }
        return keys
    }

    private static func isKeyStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func lastOutsideValue(
        key: String,
        file: FileText,
        edits: [OutsideEdit],
        afterLineIndex: Int? = nil
    ) -> ParsedExport? {
        var value: ParsedExport?
        for edit in edits {
            if let afterLineIndex, edit.lineIndex <= afterLineIndex { continue }
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
