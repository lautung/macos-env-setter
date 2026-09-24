import Combine
import EnvSetterCore
import Foundation

/// 界面状态与命令的唯一入口：草稿（内存里的编辑）、显式应用、收编、备份、诊断、重启 App。
///
/// 纪律与引擎一致——编辑只改内存，点「应用」才落盘；唯一的例外是「秘密值」打码标记，
/// 它只影响展示、不属于两层写入内容，改一次就单独存一次（见 `EnvSetterEngine.setSecretFlags`）。
///
/// 所有会碰磁盘/launchctl 的命令都在主线程之外执行，界面靠 `isBusy` 挡住重入。
@MainActor
public final class AppModel: ObservableObject {
    // MARK: - 类型

    public enum Sheet: String, Identifiable, Equatable {
        case newRecord, adoption, backups, restart, diagnostics

        public var id: String { rawValue }
    }

    public struct Banner: Identifiable, Equatable {
        public enum Kind: Equatable { case info, warning }

        public let id = UUID()
        public var kind: Kind
        public var text: String
        public var opensDiagnostics: Bool

        public init(kind: Kind, text: String, opensDiagnostics: Bool = false) {
            self.kind = kind
            self.text = text
            self.opensDiagnostics = opensDiagnostics
        }
    }

    public enum Layer: Equatable { case shell, gui }

    // MARK: - 依赖

    private let engine: EnvSetterEngine
    private let apps: AppController
    public let paths: EnginePaths

    // MARK: - 状态

    /// 草稿：列表顺序即声明顺序，也就是写入标记块的顺序。
    @Published public private(set) var entries: [ManagedEntry] = []
    /// 已应用状态（磁盘上的快照），「待生效」的判定基准。
    @Published public private(set) var savedEntries: [ManagedEntry] = []
    @Published private var pathDraft = PathDraft()
    @Published public var search: String = ""
    @Published public private(set) var selection: String?
    /// 当前临时显示明文的记录 key（切换选中即重新打码）。
    @Published public private(set) var revealedKey: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var busyLabel: String?
    @Published public private(set) var lastAppliedAt: Date?
    @Published public var banner: Banner?
    @Published public var sheet: Sheet?
    @Published public var dialog: Dialog?
    @Published public private(set) var diagnosis: GuiDiagnosis?
    @Published public private(set) var backups: [BackupInfo] = []
    @Published public private(set) var adoptionPlan: AdoptionPlan?
    @Published public private(set) var runningApps: [RunningApp] = []
    @Published public private(set) var restartingPID: pid_t?

    private var started = false

    public init(
        engine: EnvSetterEngine,
        apps: AppController = WorkspaceAppController()
    ) {
        self.engine = engine
        self.paths = engine.paths
        self.apps = apps
    }

    // MARK: - 生命周期

    public func start() async {
        guard !started else { return }
        started = true
        await reload()
    }

    /// 以文件为准重新载入（漂移处理与「丢弃未应用改动」都是它）。
    public func reload() async {
        isBusy = true
        busyLabel = "读取 \(zprofileLabel)…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        do {
            let result = try await loadFromDisk()
            banner = loadBanner(result)
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    /// 工具栏的「重新载入」：有未应用改动时先问一句。
    public func requestReload() {
        guard changes.isEmpty else {
            dialog = Dialog(
                title: "丢弃未应用的改动？",
                message: "重新载入会以 \(zprofileLabel) 为准重建列表，\(changes.count) 处未应用的改动会丢失。",
                confirmTitle: "丢弃并重新载入",
                isDestructive: true,
                action: .reloadFromDisk
            )
            return
        }
        Task { await reload() }
    }

    @discardableResult
    private func loadFromDisk() async throws -> LoadResult {
        let engine = self.engine
        let result = try await offMain { try engine.load() }
        adopt(result.entries)
        return result
    }

    /// 把一组条目设为草稿与已应用状态（载入、收编、恢复后都走这里，保证派生状态同步重建）。
    private func adopt(_ newEntries: [ManagedEntry]) {
        entries = newEntries
        savedEntries = newEntries
        syncPathDraft()
        revealedKey = nil
        if let selection, !newEntries.hasRecord(named: selection) {
            self.selection = nil
        }
    }

    /// PATH 行草稿与记录原始值的同步点。编辑器以外的记录变化都从权威原始值重建行。
    private func syncPathDraft() {
        pathDraft.synchronize(with: pathRecord?.rawValue)
    }

    // MARK: - 派生状态

    public var changes: ChangeSet {
        ChangeSet(draft: entries, saved: savedEntries)
    }

    public var validationIssues: [String: String] {
        RecordValidation.issues(in: entries)
    }

    /// GUI 层引用警告（按记录 key 索引）。非阻塞：它不参与 `canApply`，
    /// 只提醒「这一段在 GUI 层拿不到值」。修好（打开被引用记录的 GUI 开关、或把它上移）后立刻消失——
    /// 它算在草稿上，不需要重新载入。
    public var referenceWarnings: [String: [GuiReferenceWarning]] {
        GuiReferenceWarnings.warnings(in: entries, revealedKey: revealedKey)
    }

    public func referenceWarnings(for key: String) -> [GuiReferenceWarning] {
        referenceWarnings[key] ?? []
    }

    public var pendingCount: Int { changes.count }

    public var structureChanged: Bool { changes.orderChanged }

    /// 有校验问题或有未应用改动时才能应用；忙碌时挡住重入。
    public var canApply: Bool {
        !isBusy && !changes.isEmpty && validationIssues.isEmpty
    }

    public var canRetryGuiSync: Bool {
        !isBusy && changes.isEmpty && engine.gui != nil
    }

    /// 有草稿时唯一的出路，措辞只此一份：横幅、按钮提示、诊断面板都取它。
    private var draftAdvice: String { "先应用，或重新载入并丢弃草稿" }

    /// 诊断面板里的提示：与挡住「重试 GUI 同步」时的横幅同一句话。
    public var draftBlockedNotice: String { draftBlockedMessage("重试 GUI 同步") }

    public var guiRetryHelp: String {
        if !changes.isEmpty { return "\(draftAdvice)，再重试 GUI 同步" }
        if isBusy { return "当前操作完成后才能重试 GUI 同步" }
        return "只同步已应用的 GUI 层状态，不改写 ~/.zprofile 或创建备份"
    }

    public var selectedRecord: VariableRecord? {
        guard let selection else { return nil }
        return entries.record(named: selection)
    }

    public var pathRows: [PathRow] { pathDraft.rows }

    public var pathRecord: VariableRecord? {
        entries.record(named: VariableKeys.path)
    }

    /// 侧栏的行：记录（可编辑）→ 逐字保留行（只读）→ 已删除未应用（划掉、可撤销）。
    public var rows: [SidebarRow] {
        let changes = self.changes
        let issues = validationIssues
        let warnings = referenceWarnings
        let query = search.trimmingCharacters(in: .whitespaces)
        var rows: [SidebarRow] = []
        var verbatimIndex = 0

        for entry in entries {
            switch entry {
            case .record(let record):
                guard Self.matches(record.key, query: query) else { continue }
                rows.append(
                    .record(
                        RecordRow(
                            record: record,
                            status: Self.rowStatus(record, changes: changes),
                            layers: changes.layerStates(for: record),
                            preview: SecretMasking.preview(record, revealed: revealedKey == record.key),
                            issue: issues[record.key],
                            warnings: warnings[record.key] ?? [],
                            isPath: record.key == VariableKeys.path
                        )
                    )
                )
            case .verbatim(let line):
                // 逐字保留行没有变量名可比，搜索时先不显示（否则一搜索满屏噪音）。
                guard query.isEmpty else { continue }
                rows.append(.verbatim(VerbatimRow(line: line, index: verbatimIndex)))
                verbatimIndex += 1
            }
        }

        for record in changes.removedRecords where Self.matches(record.key, query: query) {
            rows.append(.removed(RemovedRow(record: record)))
        }
        return rows
    }

    public var zprofileLabel: String {
        Self.abbreviateHome(paths.zprofileURL.path)
    }

    public var backupsDirectoryLabel: String {
        Self.abbreviateHome(paths.backupsDirectory.path)
    }

    public var guiLabel: String { engine.gui?.label ?? LaunchAgent.defaultLabel }

    public var guiDomain: String { engine.gui?.domain ?? "gui/\(getuid())" }

    /// 上次应用的时间（仅本次会话内记录；只用于工具栏提示，不假装是持久事实）。
    public var lastAppliedText: String? {
        lastAppliedAt?.formatted(date: .omitted, time: .shortened)
    }

    public func maskedPreview(_ record: VariableRecord) -> String {
        SecretMasking.preview(record, revealed: revealedKey == record.key)
    }

    public func rowStatus(for key: String) -> RowStatus {
        guard let record = entries.record(named: key) else { return .off }
        return Self.rowStatus(record, changes: changes)
    }

    public func layerStates(for key: String) -> LayerStates {
        guard let record = entries.record(named: key) else {
            return LayerStates(shell: .off, gui: .off)
        }
        return changes.layerStates(for: record)
    }

    /// 新建记录时对变量名的预检（同名或格式不合法都不让点「添加」）。
    public func issueForNewKey(_ key: String) -> String? {
        if entries.hasRecord(named: key) { return "同名变量已存在" }
        return RecordValidation.issue(for: VariableRecord(key: key, rawValue: ""), duplicateCount: 1)
    }

    // MARK: - 编辑

    public func select(_ key: String?) {
        selection = key
        revealedKey = nil
    }

    public func toggleReveal(_ key: String) {
        revealedKey = revealedKey == key ? nil : key
    }

    public func addRecord(
        key: String,
        rawValue: String,
        shellEnabled: Bool,
        guiEnabled: Bool,
        secret: Bool
    ) {
        let record = VariableRecord(
            key: key,
            rawValue: rawValue,
            shellEnabled: shellEnabled,
            guiEnabled: guiEnabled,
            secret: secret,
            source: .toolCreated
        )
        entries.append(.record(record))
        if record.key == VariableKeys.path { syncPathDraft() }
        selection = record.key
        revealedKey = nil
        banner = Banner(kind: .info, text: "已添加 \(record.key)（待生效）——点「应用」才写入两层。")
    }

    /// 移除一条记录的后果：只看已应用状态——写进两层的只有它（判定依据见 `RemovalImpact`）。
    /// 确认框与移除后的提示条都从这里取口径，两处才不会各说一套。
    public func removalImpact(for key: String) -> RemovalImpact {
        RemovalImpact(key: key, saved: savedEntries.record(named: key))
    }

    public func requestDelete(_ key: String) {
        dialog = Dialog(
            title: "从列表移除「\(key)」？",
            message: removalImpact(for: key).dialogMessage(zprofileLabel: zprofileLabel),
            confirmTitle: "移除",
            isDestructive: true,
            action: .deleteRecord(key)
        )
    }

    public func deleteRecord(_ key: String) {
        let impact = removalImpact(for: key)
        entries.removeAll { $0.key == key }
        if key == VariableKeys.path { syncPathDraft() }
        if selection == key { selection = nil }
        if revealedKey == key { revealedKey = nil }
        // 只有已应用过的记录才会留下待生效改动（其余直接消失，没什么可说的）。
        if impact.wasApplied {
            banner = Banner(kind: .info, text: impact.bannerText(zprofileLabel: zprofileLabel))
        }
    }

    public func undoRemoval(_ key: String) {
        guard let record = savedEntries.record(named: key), !entries.hasRecord(named: key) else { return }
        // 插回它原来的位置：直接追加会把「撤销」变成一次顺序改动。
        let savedIndex = savedEntries.firstIndex { $0.key == key } ?? 0
        let predecessor = savedEntries[..<savedIndex].last { entry in
            guard let entryKey = entry.key else { return false }
            return entries.hasRecord(named: entryKey)
        }
        let insertAt = predecessor
            .flatMap { previous in entries.firstIndex { $0.key == previous.key }.map { $0 + 1 } } ?? 0
        entries.insert(.record(record), at: min(insertAt, entries.count))
        if key == VariableKeys.path { syncPathDraft() }
        selection = record.key
    }

    public func setKey(_ newKey: String, for key: String) {
        guard newKey != key else { return }
        Self.mutate(&entries, key: key) { $0.key = newKey }
        // 改名进出 PATH 都要重建行草稿：记录换了身份，旧草稿从此对不上它。
        if key == VariableKeys.path || newKey == VariableKeys.path { syncPathDraft() }
        if selection == key { selection = newKey }
        if revealedKey == key { revealedKey = newKey }
    }

    public func setRawValue(_ value: String, for key: String) {
        Self.mutate(&entries, key: key) { $0.rawValue = value }
        if key == VariableKeys.path { syncPathDraft() }
    }

    public func setLayer(_ layer: Layer, enabled: Bool, for key: String) {
        Self.mutate(&entries, key: key) { record in
            switch layer {
            case .shell: record.shellEnabled = enabled
            case .gui: record.guiEnabled = enabled
            }
        }
    }

    /// 引用样式：双引号（`$` 照常展开）或单引号（`$` 是字面量）。写回文件时按它重新加引号。
    public func setQuoteStyle(_ style: QuoteStyle, for key: String) {
        Self.mutate(&entries, key: key) { $0.quoteStyle = style }
    }

    /// 秘密值标记：改完立刻单独落盘（只动本地状态，不碰标记块、不备份）。
    /// 同步写：几 KB 的本地状态，同步做完最省心——异步的话「标记完立刻退出」会把标记丢掉，
    /// 下次启动就变成明文显示了。
    public func setSecret(_ secret: Bool, for key: String) {
        Self.mutate(&entries, key: key) { $0.secret = secret }
        Self.mutate(&savedEntries, key: key) { $0.secret = secret }
        do {
            try engine.setSecretFlags([key: secret])
        } catch {
            banner = Banner(
                kind: .warning,
                text: "「\(key)」的打码标记没能存到本地状态：\(error.localizedDescription)。重启界面后会重新显示明文。"
            )
        }
    }

    public func moveRecord(_ key: String, by delta: Int) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    // MARK: - PATH 编辑器

    public var pathDuplicateIDs: Set<UUID> { pathDraft.duplicateIDs }

    public var pathHasAnchor: Bool { pathDraft.anchorCount > 0 }

    public var pathAnchorWarning: String? {
        pathDraft.anchorCount > 1
            ? "有多个 $PATH 锚点：只有第一个起「继承既有 PATH」的作用，多余的请删掉。"
            : nil
    }

    /// PATH 是单引号记录时的提醒：编辑器按「`$` 展开」的语义工作，一改就换成双引号。
    public var pathQuoteWarning: String? {
        pathRecord?.quoteStyle == .single
            ? "这条 PATH 记录当前是单引号（`$` 是字面量、不展开）；用本编辑器改动后会改为双引号，`$` 引用与锚点照常展开。"
            : nil
    }

    public func setPathRowText(_ text: String, forRow id: UUID) {
        editPathDraft { $0.setText(text, for: id) }
    }

    public func addPathRow(_ text: String) {
        editPathDraft { $0.addEntry(text) }
    }

    public func addPathAnchor() {
        editPathDraft { $0.addAnchor() }
    }

    public func pathRowIndex(of id: UUID) -> Int? {
        pathDraft.index(of: id)
    }

    public func canRemovePathRow(_ id: UUID) -> Bool {
        pathDraft.canRemove(id)
    }

    public func removePathRow(_ id: UUID) {
        editPathDraft { $0.remove(id) }
    }

    public func nudgePathRow(_ id: UUID, by delta: Int) {
        editPathDraft { $0.move(id, by: delta) }
    }

    /// SwiftUI 的拖动 API 使用下标；视图负责转成稳定行 ID，模型只接收身份顺序。
    public func reorderPathRows(_ rowIDs: [UUID]) {
        editPathDraft { $0.reorder(to: rowIDs) }
    }

    /// 提交（回车/失焦）：归一化行文本；拆分时保留未受影响行与首个片段的身份。
    public func commitPathRows() {
        editPathDraft { $0.commit() }
    }

    /// 记录原始值始终是待生效状态的权威来源；未载入时先以记录重建，再接受后续编辑。
    private func editPathDraft(_ edit: (inout PathDraft) -> String?) {
        guard let current = pathRecord else {
            pathDraft.synchronize(with: nil)
            return
        }
        guard pathDraft.prepareForEditing(currentRawValue: current.rawValue),
              let rawValue = edit(&pathDraft),
              pathDraft.hasSemanticChange(from: current.rawValue, to: rawValue)
        else { return }

        Self.mutate(&entries, key: VariableKeys.path) { record in
            record.rawValue = rawValue
            record.quoteStyle = .double
        }
    }

    // MARK: - 显式应用

    public func apply() async {
        guard canApply else { return }
        isBusy = true
        busyLabel = "应用…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        commitPathRows() // 先把编辑中的 PATH 行落到语义上，写出去的内容与看到的一致
        let draft = entries
        let engine = self.engine
        do {
            let result = try await offMain { try engine.apply(entries: draft) }
            savedEntries = draft
            lastAppliedAt = Date()
            banner = applyBanner(result)
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    // MARK: - 收编

    public func planAdoption() async {
        if refuseWhileDraftPending("打开收编计划") { return }
        isBusy = true
        busyLabel = "扫描块外 export 行…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        let engine = self.engine
        do {
            let plan = try await offMain { try engine.planAdoption() }
            // 扫描期间用户可能又改了草稿：计划是从磁盘状态生成的，落进草稿会把改动顶掉。
            if refuseWhileDraftPending("打开收编计划") { return }
            guard !plan.adoptedKeys.isEmpty || plan.mergedPathLineCount > 0 || !plan.outsideEdits.isEmpty else {
                banner = Banner(kind: .info, text: "没有可收编的块外 export 行。")
                return
            }
            adoptionPlan = plan
            sheet = .adoption
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    public func confirmAdoption() async {
        guard let plan = adoptionPlan else { return }
        // 计划是打开面板时生成的：期间新增的草稿不能被它顶掉，所以确认时再挡一次。
        if refuseWhileDraftPending("确认收编计划") {
            sheet = nil
            adoptionPlan = nil
            return
        }
        sheet = nil
        adoptionPlan = nil
        isBusy = true
        busyLabel = "收编并应用…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        let engine = self.engine
        do {
            let result = try await offMain {
                try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)
            }
            adopt(plan.entries)
            lastAppliedAt = Date()
            banner = adoptionBanner(plan: plan, result: result)
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    // MARK: - 备份与恢复

    public func openBackups() async {
        isBusy = true
        busyLabel = "读取备份…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        let engine = self.engine
        do {
            backups = try await offMain { try engine.backupsList() }
            sheet = .backups
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    public func requestRestore(_ backup: BackupInfo) {
        // 先收起面板：确认框挂在主窗口上，面板开着时它会被挡在后面。
        sheet = nil
        dialog = Dialog(
            title: "用「\(backup.fileName)」恢复？",
            message: """
                会用这份备份整份覆盖 \(zprofileLabel)（恢复前的内容也会先备份一份），\
                然后以文件为准重新载入列表——未应用的改动会丢失。
                """,
            confirmTitle: "恢复",
            isDestructive: true,
            action: .restoreBackup(backup)
        )
    }

    public func restore(_ backup: BackupInfo) async {
        sheet = nil
        isBusy = true
        busyLabel = "恢复备份…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        let engine = self.engine
        do {
            try await offMain { try engine.restore(from: backup) }
            try await loadFromDisk()
            banner = Banner(
                kind: .info,
                text: "已用「\(backup.fileName)」覆盖 \(zprofileLabel) 并重新载入列表（恢复前的内容也备份了一份）。"
            )
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    // MARK: - GUI 层诊断

    public func openDiagnostics() async {
        isBusy = true
        busyLabel = "体检 GUI 层…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        let engine = self.engine
        do {
            guard let diagnosis = try await offMain({ try engine.guiDiagnosis() }) else {
                banner = Banner(kind: .warning, text: "引擎未接入 GUI 层，无法诊断。")
                return
            }
            self.diagnosis = diagnosis
            sheet = .diagnostics
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    /// 使用已应用状态单独重试 GUI 同步；有草稿时拒绝执行，避免把草稿误当成已应用配置。
    public func retryGuiSync() async {
        if refuseWhileDraftPending("重试 GUI 同步") { return }
        guard engine.gui != nil else {
            banner = Banner(kind: .warning, text: "引擎未接入 GUI 层，无法重试同步。")
            return
        }
        isBusy = true
        busyLabel = "重试 GUI 同步…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        let engine = self.engine
        do {
            guard let report = try await offMain({ try engine.retryGuiSync() }) else {
                banner = Banner(kind: .warning, text: "引擎未接入 GUI 层，无法重试同步。")
                return
            }
            diagnosis = try await offMain { try engine.guiDiagnosis() }
            banner = guiRetryBanner(report)
        } catch {
            dialog = EngineErrorMessages.dialog(for: error)
        }
    }

    public func openLoginItemsSettings() {
        apps.openLoginItemsSettings()
    }

    // MARK: - 重启指定 App

    public func openRestartSheet() {
        refreshRunningApps()
        sheet = .restart
    }

    public func refreshRunningApps() {
        runningApps = apps.runningApps()
    }

    public func restart(_ app: RunningApp) async {
        restartingPID = app.pid
        defer { restartingPID = nil }
        let failure = await apps.restart(app)
        refreshRunningApps()
        banner = failure.map { Banner(kind: .warning, text: $0) }
            ?? Banner(kind: .info, text: "已重启「\(app.name)」——新进程读到的是 GUI 层当前值。")
    }

    // MARK: - 对话框

    public func dismissDialog() {
        dialog = nil
    }

    public func dismissSheet() {
        sheet = nil
        adoptionPlan = nil
    }

    public func perform(_ dialog: Dialog) async {
        self.dialog = nil
        switch dialog.action {
        case .acknowledge:
            break
        case .reloadFromDisk:
            await reload()
        case .deleteRecord(let key):
            deleteRecord(key)
        case .restoreBackup(let backup):
            await restore(backup)
        }
    }

    // MARK: - Private

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    @discardableResult
    private static func mutate(
        _ entries: inout [ManagedEntry],
        key: String,
        _ body: (inout VariableRecord) -> Void
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        guard case .record(var record) = entries[index] else { return false }
        body(&record)
        entries[index] = .record(record)
        return true
    }

    private static func matches(_ key: String, query: String) -> Bool {
        // 只按变量名搜索：拿值去搜会让搜索框变成绕过打码的探针。
        query.isEmpty || key.localizedCaseInsensitiveContains(query)
    }

    private static func rowStatus(_ record: VariableRecord, changes: ChangeSet) -> RowStatus {
        if changes.isPending(record.key) { return .pending }
        // 顺序变了：每条记录在文件里的位置都变了，已应用状态就不再等于眼前这一份。
        if changes.orderChanged, changes.savedByKey[record.key] != nil { return .pending }
        return (record.shellEnabled || record.guiEnabled) ? .synced : .off
    }

    private static func reorder<T>(_ items: [T], from offsets: IndexSet, to destination: Int) -> [T] {
        var result = items
        let moving = offsets.sorted().map { items[$0] }
        for index in offsets.sorted(by: >) { result.remove(at: index) }
        let adjusted = destination - offsets.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: adjusted)
        return result
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func loadBanner(_ result: LoadResult) -> Banner? {
        if result.driftDetected {
            return Banner(
                kind: .warning,
                text: "检测到漂移：标记块被手工改动过，已以文件为准重新载入（\(result.entries.count) 个条目）。"
            )
        }
        if result.adoptedExistingBlock {
            return Banner(kind: .info, text: "发现已有标记块，已把块内容收编为当前状态。")
        }
        return nil
    }

    /// 挡住一个需要「已应用状态」的动作，并把唯一的出路说清楚。
    /// 返回 true = 已挡下（调用方直接 return）；没有草稿时不产生任何副作用。
    private func refuseWhileDraftPending(_ action: String) -> Bool {
        guard !changes.isEmpty else { return false }
        banner = Banner(kind: .warning, text: draftBlockedMessage(action))
        return true
    }

    private func draftBlockedMessage(_ action: String) -> String {
        "当前有 \(changes.count) 处待生效改动，\(draftAdvice)，再\(action)。"
    }

    private func applyBanner(_ result: ApplyResult) -> Banner {
        // 「只影响之后新启动的 App」这句每次应用后都要出现——它是这个工具最容易误解的地方。
        let effect = "只影响之后新启动的 App——已运行的 App 需退出重开（侧栏「重启指定 App」）。"
        guard let gui = result.gui else {
            return Banner(
                kind: .info,
                text: "已应用：\(zprofileLabel) 标记块与本地状态已写入（应用前已自动备份）。\(effect)"
            )
        }
        switch gui.outcome {
        case .applied:
            return Banner(
                kind: .info,
                text: """
                    已应用：\(zprofileLabel) 标记块 + GUI 层（launchd，\(gui.keys.count) 个变量）均已写入，\
                    并已注入当前会话（应用前已自动备份）。\(effect)
                    """
            )
        case .skipped:
            return Banner(
                kind: .info,
                text: "已应用：\(zprofileLabel) 标记块与本地状态已写入（应用前已自动备份）。当前没有启用 GUI 层的变量，未安装 LaunchAgent。\(effect)"
            )
        case .uninstalled:
            let cleared = gui.clearedKeys.isEmpty
                ? ""
                : "，并从 gui 域清除了 \(gui.clearedKeys.count) 个变量（\(gui.clearedKeys.joined(separator: "、"))）"
            return Banner(
                kind: .info,
                text: """
                    已应用：\(zprofileLabel) 标记块与本地状态已写入（应用前已自动备份）。当前没有启用 GUI 层的变量：\
                    GUI 层已整体撤掉——脚本、LaunchAgent 与登录项都不再存在\(cleared)。\
                    只影响之后新启动的 App：已在运行的 App 仍持有旧值（退出重开才会丢掉）。
                    """
            )
        case .partial, .failed:
            let cleared = gui.clearedKeys.isEmpty
                ? ""
                : "本轮已从 gui 域清除 \(gui.clearedKeys.count) 个变量（\(gui.clearedKeys.joined(separator: "、"))）。\n"
            return Banner(
                kind: .warning,
                text: """
                    shell 层已写入（\(zprofileLabel)，应用前已自动备份），但 GUI 层没做完：
                    \(cleared)\
                    \(gui.warning ?? "见「诊断 LaunchAgent」")
                    可打开诊断面板单独重试 GUI 同步。
                    \(effect)
                    """,
                opensDiagnostics: true
            )
        }
    }

    private func adoptionBanner(plan: AdoptionPlan, result: ApplyResult) -> Banner {
        var parts: [String] = []
        if !plan.adoptedKeys.isEmpty {
            parts.append("收编 \(plan.adoptedKeys.count) 条：\(plan.adoptedKeys.joined(separator: "、"))")
        }
        if plan.mergedPathLineCount > 0 {
            parts.append("合并 \(plan.mergedPathLineCount) 行 PATH 进有序列表")
        }
        if !plan.outsideEdits.isEmpty {
            parts.append("块外 \(plan.outsideEdits.count) 行已注释（保留手工回退路径）")
        }
        var text = "已收编并应用：" + parts.joined(separator: "；") + "。收编的变量默认只写 shell 层，需要 GUI 层请在列表里逐条打开。"
        if let gui = result.gui, let warning = gui.warning {
            text += "\nGUI 层未完成：\(warning)"
        }
        return Banner(
            kind: result.gui?.warning == nil ? .info : .warning,
            text: result.gui?.warning == nil ? text : text + "\n可打开诊断面板单独重试 GUI 同步。",
            opensDiagnostics: result.gui?.warning != nil
        )
    }

    private func guiRetryBanner(_ report: GuiApplyReport) -> Banner {
        switch report.outcome {
        case .applied:
            return Banner(kind: .info, text: "GUI 层同步成功，已刷新诊断结果。")
        case .uninstalled:
            return Banner(kind: .info, text: "GUI 层清理完成，已刷新诊断结果。")
        case .skipped:
            return Banner(kind: .info, text: "当前没有需要同步的 GUI 层变量，已刷新诊断结果。")
        case .partial, .failed:
            return Banner(
                kind: .warning,
                text: "GUI 层仍未完成：\(report.warning ?? "请查看诊断结果。")\n可在诊断面板再次重试 GUI 同步。",
                opensDiagnostics: true
            )
        }
    }

}
