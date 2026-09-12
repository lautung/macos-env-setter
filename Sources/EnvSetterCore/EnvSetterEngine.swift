import Foundation

/// 引擎编排：载入（含漂移检测与以文件为准的重新载入）、收编计划、显式应用（备份 → 写标记块）、恢复备份。
/// 只负责 shell 层（~/.zprofile 标记块）与本地状态；GUI 层（launchctl/LaunchAgent）在 GUI 层实现票接入。
public final class EnvSetterEngine {
    public let paths: EnginePaths
    private let backups: BackupManager

    public init(paths: EnginePaths) {
        self.paths = paths
        self.backups = BackupManager(backupsDirectory: paths.backupsDirectory)
    }

    // MARK: - 载入

    /// 读取本地状态与 ~/.zprofile，做一次漂移检测。
    /// 标记块与最后写入的快照不一致（或块被整个删掉）时，以文件为准重新载入并回报。
    public func load() throws -> LoadResult {
        var store = try loadStore()
        let content = try readZprofile()
        let location = try MarkerBlock.locate(in: content)

        var driftDetected = false
        var adoptedExistingBlock = false

        if let location {
            if let snapshot = store.blockSnapshot {
                if location.fullText != snapshot {
                    driftDetected = true
                    store = reload(store: store, from: location)
                }
            } else {
                // 首次遇到已存在的标记块（或本地状态丢失）：块内容即真相。
                adoptedExistingBlock = true
                store = reload(store: store, from: location)
            }
        } else if store.blockSnapshot != nil {
            // 块被手工整个删掉：同样以文件为准，shell 层全部停用。
            driftDetected = true
            disableShellLayer(in: &store)
        }

        if driftDetected || adoptedExistingBlock {
            try StorePersistence.save(store, to: paths.storeURL)
        }
        return LoadResult(
            entries: store.entries,
            driftDetected: driftDetected,
            adoptedExistingBlock: adoptedExistingBlock,
            hasMarkerBlock: location != nil
        )
    }

    /// 只读的漂移检测，不改任何状态。
    public func checkDrift() throws -> Bool {
        let store = try loadStore()
        let content = try readZprofile()
        let location = try MarkerBlock.locate(in: content)
        guard let snapshot = store.blockSnapshot else { return false }
        guard let location else { return true } // 快照在、块没了
        return location.fullText != snapshot
    }

    // MARK: - 收编

    /// 生成收编计划（纯内存操作，不落盘）。UI 可先展示计划再调用 apply。
    public func planAdoption() throws -> AdoptionPlan {
        let store = try loadStore()
        let content = try readZprofile()
        return try AdoptionScanner.plan(fileContent: content, currentEntries: store.entries)
    }

    // MARK: - 显式应用

    /// 显式应用：编辑只在内存，直到这里才一次性落盘。
    /// 流程：漂移预检 → 基线/时间戳备份 → 原子写标记块（含收编的块外注释）→ 更新快照与本地状态。
    /// 成功后返回本次写入的完整文件内容。
    @discardableResult
    public func apply(
        entries: [ManagedEntry],
        outsideEdits: [OutsideEdit] = []
    ) throws -> String {
        try validate(entries: entries)

        var store = try loadStore()
        let content = try readZprofile()
        let location = try MarkerBlock.locate(in: content)

        if let snapshot = store.blockSnapshot {
            if let location {
                guard location.fullText == snapshot else { throw EngineError.driftDetected }
            } else {
                throw EngineError.driftDetected
            }
        }

        for edit in outsideEdits {
            guard let line = FileText(content).line(at: edit.lineIndex), line == edit.originalLine else {
                throw EngineError.fileChangedSincePlan
            }
        }

        // 块外注释先于整块替换：替换是原行原位进行的，行数不变，块行号不受影响；
        // 若先换块（行数可能变化），计划时的行号就会错位。
        var working = content
        for edit in outsideEdits {
            working = FileText(working).replacingLine(at: edit.lineIndex, with: edit.replacementLine)
        }

        let newBlock = MarkerBlock.generate(entries: entries)
        let newContent: String
        if location != nil {
            // 必须在注释后的文本上重新定位：String.Index 不跨字符串复用，
            // 注释让行变长了，旧索引会切错位置。
            guard let workingLocation = try MarkerBlock.locate(in: working) else {
                throw EngineError.malformedMarkerBlock
            }
            newContent = MarkerBlock.splice(original: working, location: workingLocation, newBlock: newBlock)
        } else {
            newContent = MarkerBlock.append(original: working, newBlock: newBlock)
        }

        try backups.ensureBaseline(currentContent: content.isEmpty ? nil : content)
        try backups.timestampedBackup(currentContent: content.isEmpty ? nil : content)
        try AtomicFile.write(Data(newContent.utf8), to: paths.zprofileURL)

        store.entries = entries
        store.blockSnapshot = newBlock
        try StorePersistence.save(store, to: paths.storeURL)
        return newContent
    }

    // MARK: - 备份与恢复

    public func backupsList() throws -> [BackupInfo] {
        try backups.list()
    }

    /// 一键恢复：先给当前文件做时间戳备份，再原子写回备份内容，最后以文件为准重新载入本地状态。
    public func restore(from backup: BackupInfo) throws {
        let restored = try backups.read(url: backup.url)
        let current = try? readZprofile()
        try backups.timestampedBackup(currentContent: current)
        try AtomicFile.write(Data(restored.utf8), to: paths.zprofileURL)

        var store = try loadStore()
        let location = try MarkerBlock.locate(in: restored)
        if let location {
            store = reload(store: store, from: location)
        } else {
            disableShellLayer(in: &store)
        }
        try StorePersistence.save(store, to: paths.storeURL)
    }

    // MARK: - Private

    /// 以文件为准重新载入：解析标记块内容，
    /// 已有记录按 key 合并（值取文件、shell 开，GUI 开关与来源保留），
    /// 新 key 收编为导入记录；文件里消失的 shell 记录停用（shell 关）；文件里无法解析的行逐字保留。
    private func reload(store: EnvStore, from location: MarkerBlock.Location) -> EnvStore {
        let parsed = MarkerBlock.parse(innerContent: location.innerContent)
        let existingByKey: [String: VariableRecord] = store.entries.reduce(into: [:]) { dict, entry in
            if case .record(let record) = entry { dict[record.key] = record }
        }

        var merged: [ManagedEntry] = []
        var matchedKeys = Set<String>()
        for entry in parsed {
            switch entry {
            case .verbatim(let line):
                merged.append(.verbatim(line: line))
            case .record(let parsedRecord):
                var record = parsedRecord
                record.shellEnabled = true
                if let existing = existingByKey[parsedRecord.key] {
                    matchedKeys.insert(parsedRecord.key)
                    record.rawValue = parsedRecord.rawValue // 值以文件为准
                    record.guiEnabled = existing.guiEnabled
                    record.source = existing.source
                } else {
                    record.guiEnabled = false
                    record.source = .adopted
                }
                merged.append(.record(record))
            }
        }
        // 文件里没有的既有记录：shell 行被用户删了 → shell 层停用，保留原相对顺序放在尾部。
        for entry in store.entries {
            if case .record(var record) = entry, !matchedKeys.contains(record.key) {
                record.shellEnabled = false
                merged.append(.record(record))
            }
        }
        return EnvStore(entries: merged, blockSnapshot: location.fullText)
    }

    /// 块不存在（被用户删除或恢复到无块备份）时的以文件为准：全部记录 shell 停用。
    private func disableShellLayer(in store: inout EnvStore) {
        store.entries = store.entries.map { entry in
            if case .record(var record) = entry {
                record.shellEnabled = false
                return .record(record)
            }
            return nil
        }.compactMap { $0 }
        store.blockSnapshot = nil
    }

    private func validate(entries: [ManagedEntry]) throws {
        for entry in entries {
            guard case .record(let record) = entry else { continue }
            guard ShellLine.isSimpleKey(record.key) else { throw EngineError.invalidKey(record.key) }
            guard !record.rawValue.contains("\n"), !record.rawValue.contains("\r") else {
                throw EngineError.invalidRawValue(record.key)
            }
            if record.quoteStyle == .single, record.rawValue.contains("'") {
                // 单引号样式无法表达撇号（zsh 单引号内无转义）。
                throw EngineError.invalidRawValue(record.key)
            }
        }
    }

    private func readZprofile() throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.zprofileURL.path) else { return "" }
        guard let content = String(data: try Data(contentsOf: paths.zprofileURL), encoding: .utf8) else {
            throw EngineError.fileNotUTF8
        }
        return content
    }

    private func loadStore() throws -> EnvStore {
        guard FileManager.default.fileExists(atPath: paths.storeURL.path) else { return EnvStore() }
        return try StorePersistence.load(from: paths.storeURL)
    }
}
