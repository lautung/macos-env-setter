import EnvSetterCore
import EnvSetterUI
import Foundation
import Testing

// MARK: - 差异判定

struct ChangeSetTests {
    private func record(_ key: String, _ value: String, shell: Bool = true, gui: Bool = false, secret: Bool = false) -> ManagedEntry {
        .record(VariableRecord(key: key, rawValue: value, shellEnabled: shell, guiEnabled: gui, secret: secret))
    }

    @Test func newRecordIsPending() {
        let changes = ChangeSet(draft: [record("A", "1")], saved: [])
        #expect(changes.pendingKeys == ["A"])
        #expect(changes.count == 1)
        #expect(!changes.isEmpty)
    }

    @Test func valueAndLayerChangesArePending() {
        let saved = [record("A", "1"), record("B", "2", shell: false, gui: true)]
        #expect(ChangeSet(draft: [record("A", "1"), record("B", "2", shell: false, gui: true)], saved: saved).isEmpty)
        #expect(ChangeSet(draft: [record("A", "9"), record("B", "2", shell: false, gui: true)], saved: saved).pendingKeys == ["A"])
        #expect(ChangeSet(draft: [record("A", "1"), record("B", "2", shell: true, gui: true)], saved: saved).pendingKeys == ["B"])
        #expect(ChangeSet(draft: [record("A", "1"), record("B", "2", shell: false, gui: false)], saved: saved).pendingKeys == ["B"])
    }

    /// 打码与来源只影响展示，不该让一条已写入的记录变成「待生效」。
    @Test func displayOnlyFieldsAreNotPending() {
        let saved = [record("A", "1")]
        #expect(ChangeSet(draft: [record("A", "1", secret: true)], saved: saved).isEmpty)

        var adopted = VariableRecord(key: "A", rawValue: "1", source: .adopted)
        adopted.secret = true
        #expect(ChangeSet(draft: [.record(adopted)], saved: saved).isEmpty)
    }

    @Test func quoteStyleChangeIsPending() {
        let saved: [ManagedEntry] = [.record(VariableRecord(key: "A", rawValue: "$B", quoteStyle: .double))]
        let draft: [ManagedEntry] = [.record(VariableRecord(key: "A", rawValue: "$B", quoteStyle: .single))]
        #expect(ChangeSet(draft: draft, saved: saved).pendingKeys == ["A"])
    }

    @Test func removalIsTrackedAndCounted() {
        let saved = [record("A", "1"), record("B", "2")]
        let changes = ChangeSet(draft: [record("A", "1")], saved: saved)
        #expect(changes.removedRecords.map(\.key) == ["B"])
        #expect(changes.count == 1)
        // 删掉一条不该顺带算成「顺序变了」
        #expect(!changes.orderChanged)
    }

    @Test func orderChangeOnlyCountsCommonKeys() {
        let saved = [record("A", "1"), record("B", "2")]
        #expect(ChangeSet(draft: [record("B", "2"), record("A", "1")], saved: saved).orderChanged)
        // 只新增一条：共同 key 的相对顺序没变
        let added = ChangeSet(draft: [record("A", "1"), record("B", "2"), record("C", "3")], saved: saved)
        #expect(!added.orderChanged)
        #expect(added.count == 1)
    }

    @Test func duplicateKeysDoNotCrash() {
        let changes = ChangeSet(draft: [record("A", "1"), record("A", "2")], saved: [record("A", "1")])
        #expect(changes.pendingKeys == ["A"])
        #expect(changes.count == 1)
    }

    /// 逐层状态：只改了 GUI 开关，不该把 shell 层也染成橙色。
    @Test func layerStatesArePerLayer() {
        let saved = [record("A", "1", shell: true, gui: false)]
        let guiOnly = ChangeSet(draft: [record("A", "1", shell: true, gui: true)], saved: saved)
        #expect(guiOnly.layerStates(for: VariableRecord(key: "A", rawValue: "1", shellEnabled: true, guiEnabled: true))
            == LayerStates(shell: .written, gui: .pending))

        let valueChanged = ChangeSet(draft: [record("A", "2", shell: true, gui: true)], saved: saved)
        #expect(valueChanged.layerStates(for: VariableRecord(key: "A", rawValue: "2", shellEnabled: true, guiEnabled: true))
            == LayerStates(shell: .pending, gui: .pending))

        let off = ChangeSet(draft: [record("A", "1", shell: false)], saved: saved)
        #expect(off.layerStates(for: VariableRecord(key: "A", rawValue: "1", shellEnabled: false))
            == LayerStates(shell: .off, gui: .off))
    }
}

// MARK: - 打码

struct SecretMaskingTests {
    @Test func longValuesKeepATinyHint() {
        #expect(SecretMasking.masked("sk-proj-9f3a81c7") == "sk-p" + SecretMasking.mask)
    }

    /// 短值露出前 4 位等于泄露大半条，整条打码。
    @Test func shortValuesAreFullyMasked() {
        #expect(SecretMasking.masked("abc123") == SecretMasking.mask)
        #expect(SecretMasking.masked("") == SecretMasking.mask)
    }

    @Test func previewRespectsSecretAndReveal() {
        let plain = VariableRecord(key: "A", rawValue: "hello-world")
        #expect(SecretMasking.preview(plain, revealed: false) == "hello-world")

        let secret = VariableRecord(key: "TOKEN", rawValue: "hello-world", secret: true)
        #expect(SecretMasking.preview(secret, revealed: false) == "hell" + SecretMasking.mask)
        #expect(SecretMasking.preview(secret, revealed: true) == "hello-world")
    }

    @Test func heuristicCatchesCredentials() {
        #expect(SecretKeys.looksSecret("GITHUB_TOKEN"))
        #expect(SecretKeys.looksSecret("OPENAI_API_KEY"))
        #expect(SecretKeys.looksSecret("AWS_ACCESS_KEY_ID"))
        #expect(SecretKeys.looksSecret("DB_PASSWORD"))
        #expect(!SecretKeys.looksSecret("JAVA_HOME"))
        #expect(!SecretKeys.looksSecret("EDITOR"))
        #expect(!SecretKeys.looksSecret("PATH"))
    }
}

// MARK: - 校验

struct RecordValidationTests {
    private func issue(_ key: String, _ value: String, duplicateCount: Int = 1, style: QuoteStyle = .double) -> String? {
        RecordValidation.issue(
            for: VariableRecord(key: key, rawValue: value, quoteStyle: style),
            duplicateCount: duplicateCount
        )
    }

    @Test func acceptsOrdinaryRecords() {
        #expect(issue("JAVA_HOME", "/opt/homebrew/opt/openjdk@21") == nil)
        #expect(issue("_PRIVATE", "$HOME/go") == nil)
        #expect(issue("PATH", "/usr/local/bin:$PATH") == nil)
    }

    @Test func rejectsBadKeys() {
        #expect(issue("", "1") != nil)
        #expect(issue("1BAD", "1") != nil)
        #expect(issue("BAD-KEY", "1") != nil)
        #expect(issue("BAD KEY", "1") != nil)
    }

    @Test func rejectsDuplicates() {
        #expect(issue("A", "1", duplicateCount: 2) != nil)
    }

    @Test func rejectsValuesThatCannotBeWrittenBack() {
        #expect(issue("A", "line1\nline2") != nil)
        #expect(issue("A", "it's", style: .single) != nil)
        #expect(issue("A", "it's", style: .double) == nil)
    }

    @Test func reportsEveryOffenderInTheDraft() {
        let entries: [ManagedEntry] = [
            .record(VariableRecord(key: "A", rawValue: "1")),
            .record(VariableRecord(key: "A", rawValue: "2")),
            .record(VariableRecord(key: "BAD-KEY", rawValue: "3")),
            .record(VariableRecord(key: "OK", rawValue: "4")),
        ]
        let issues = RecordValidation.issues(in: entries)
        #expect(issues["A"] != nil)
        #expect(issues["BAD-KEY"] != nil)
        #expect(issues["OK"] == nil)
    }
}

// MARK: - PATH 编辑器

struct PathEditorTests {
    @Test func parsesAnchorsLiteralsAndEmptySegments() {
        let rows = PathEditor.rows(fromRawValue: "/a:$PATH:/b::/c")
        #expect(rows.map(\.isAnchor) == [false, true, false, false, false])
        #expect(rows.map(\.text) == ["/a", "$PATH", "/b", "", "/c"])
        #expect(PathEditor.rawValue(from: rows) == "/a:$PATH:/b::/c")
    }

    @Test func recognizesBraceAnchorForm() {
        #expect(PathEditor.rows(fromRawValue: "a:${PATH}:b").map(\.isAnchor) == [false, true, false])
    }

    /// 编辑中的行按原样保存：敲进 `:` 不会当场拆行；提交时才归一化。
    @Test func normalizationHappensOnCommitOnly() {
        let rows = [PathRow(text: "a:b")]
        #expect(PathEditor.rawValue(from: rows) == "a:b")
        #expect(PathEditor.normalized(rows).map(\.text) == ["a", "b"])
    }

    @Test func typingAnAnchorBecomesAnAnchorOnCommit() {
        let rows = [PathRow(text: "/a"), PathRow(text: "$PATH")]
        let normalized = PathEditor.normalized(rows)
        #expect(normalized.map(\.isAnchor) == [false, true])
    }

    @Test func duplicatesIgnoreCaseAndSkipEmptyEntries() {
        let rows = [
            PathRow(text: "/usr/local/bin"),
            PathRow(text: "/USR/local/bin"),
            PathRow(text: ""),
            PathRow(text: ""),
            PathRow(text: "$PATH", isAnchor: true),
        ]
        let duplicates = PathEditor.duplicateIDs(rows)
        #expect(duplicates == [rows[0].id, rows[1].id])
        #expect(PathEditor.anchorCount(rows) == 1)
    }

    /// 语义没变就不写回：一次单纯的失焦不该把 `${PATH}` 重排成 `$PATH`、白标「待生效」。
    @Test func semanticsComparisonIgnoresCosmeticDifferences() {
        let rows = PathEditor.rows(fromRawValue: "a:${PATH}")
        #expect(!PathEditor.changesSemantics(currentRawValue: "a:${PATH}", rows: rows))
        #expect(PathEditor.changesSemantics(currentRawValue: "a:${PATH}", rows: rows + [PathRow(text: "/b")]))
    }
}

// MARK: - 移除的后果判定

struct RemovalImpactTests {
    private func record(_ key: String, shell: Bool, gui: Bool) -> VariableRecord {
        VariableRecord(key: key, rawValue: "1", shellEnabled: shell, guiEnabled: gui)
    }

    /// 判定看的是「哪一层的已写入内容会变」，而写进两层的只有已应用状态。
    @Test func layerInvolvementFollowsWhatIsAlreadyWritten() {
        let shellOn = RemovalImpact(key: "A", saved: record("A", shell: true, gui: false))
        #expect(shellOn.touchesShell)
        #expect(!shellOn.touchesGui)

        let guiOnly = RemovalImpact(key: "A", saved: record("A", shell: false, gui: true))
        #expect(guiOnly.touchesGui)
        #expect(!guiOnly.touchesShell)

        // 两层都没启用的既有记录：移除不改动任何已写入的内容
        let untouched = RemovalImpact(key: "DRIFT_PROBE", saved: record("DRIFT_PROBE", shell: false, gui: false))
        #expect(untouched.wasApplied)
        #expect(!untouched.touchesShell)
        #expect(!untouched.touchesGui)
        let message = untouched.dialogMessage(zprofileLabel: "~/.zprofile")
        #expect(message.contains("两层写入内容不变"))
        #expect(!message.contains("会被删掉"))
    }

    /// 从未应用过：两层都没写进过任何地方，口径是「还没应用过」。
    @Test func neverAppliedRecordsSayNothingWasWritten() {
        let impact = RemovalImpact(key: "NEW", saved: nil)
        #expect(!impact.wasApplied)
        #expect(!impact.touchesShell)
        #expect(!impact.touchesGui)
        let message = impact.dialogMessage(zprofileLabel: "~/.zprofile")
        #expect(message.contains("还没应用过"))
        #expect(message.contains("移除不会影响"))
        #expect(!message.contains("会被删掉"))
    }

    /// PATH 记录带的不止一个条目：文案要涵盖它在标记块里的整条声明，不能只说「这一行」。
    @Test func pathRecordsCoverTheirWholeDeclaration() {
        let path = RemovalImpact(key: "PATH", saved: record("PATH", shell: true, gui: false))
        let message = path.dialogMessage(zprofileLabel: "~/.zprofile")
        #expect(message.contains("PATH 记录"))
        #expect(message.contains("整串目录"))
        #expect(message.contains("好几行"))
        #expect(!message.contains("这一行"))

        let plain = RemovalImpact(key: "FOO", saved: record("FOO", shell: true, gui: false))
        #expect(!plain.dialogMessage(zprofileLabel: "~/.zprofile").contains("整串目录"))
    }
}

// MARK: - GUI 层引用警告

struct GuiReferenceWarningsTests {
    private func record(
        _ key: String,
        _ value: String,
        shell: Bool = true,
        gui: Bool = false,
        style: QuoteStyle = .double
    ) -> ManagedEntry {
        .record(VariableRecord(key: key, rawValue: value, shellEnabled: shell, guiEnabled: gui, quoteStyle: style))
    }

    /// 规格里的例子：GUI 层的 PATH 拿不到 `$JAVA_HOME/bin`，那一段会展开成空。
    @Test func referencingARecordWithoutTheGuiSwitchWarns() throws {
        let warnings = GuiReferenceWarnings.warnings(in: [
            record("JAVA_HOME", "/opt/jdk"),
            record("PATH", "$JAVA_HOME/bin:$PATH", gui: true),
        ])

        let warning = try #require(warnings["PATH"]?.first)
        #expect(warnings["PATH"]?.count == 1)
        #expect(warning.referencedKey == "JAVA_HOME")
        #expect(warning.cause == .layerOff)
        // 哪一段：引用原文；会展开成什么：整条值里那一段被抽掉的样子
        #expect(warning.occurrences == ["$JAVA_HOME"])
        #expect(warning.rendering == "/bin:$PATH")
        #expect(warning.summary.contains("没开 GUI 开关"))
        // 「会展开成什么」单独占一行（值可能很长），视图按 kind 决定用等宽字展示
        #expect(warning.lines.contains(GuiReferenceWarning.Line(kind: .preview, text: "/bin:$PATH")))
        #expect(warning.detail.contains("整条值会变成："))
        #expect(warning.detail.contains("修法"))
        // 留着余地：gui 域里可能有别处设过的同名变量，不能把话说成绝对错误
        #expect(warning.detail.contains("不一定"))
    }

    /// PATH 记录里的 `$PATH` 是锚点、不是对记录的引用——即便列表里真有一条没开 GUI 的 PATH 记录。
    @Test func pathAnchorIsNotARecordReference() {
        let warnings = GuiReferenceWarnings.warnings(in: [
            record("PATH", "/a:$PATH", gui: false),
            record("FOO", "$PATH:/opt/bin", gui: true),
        ])
        #expect(warnings.isEmpty)
    }

    @Test func referencingARecordDeclaredLaterWarns() throws {
        let warnings = GuiReferenceWarnings.warnings(in: [
            record("PATH", "$JAVA_HOME/bin", gui: true),
            record("JAVA_HOME", "/opt/jdk", gui: true),
        ])

        let warning = try #require(warnings["PATH"]?.first)
        #expect(warning.cause == .declaredLater)
        #expect(warning.rendering == "/bin")
        #expect(warning.summary.contains("排在后面"))
        #expect(warning.detail.contains("引用只能看到"))
        #expect(warning.detail.contains("上移"))
    }

    @Test func noWarningWhenTheReferencedRecordIsEnabledAndEarlier() {
        #expect(
            GuiReferenceWarnings.warnings(in: [
                record("JAVA_HOME", "/opt/jdk", gui: true),
                record("PATH", "$JAVA_HOME/bin", gui: true),
            ]).isEmpty
        )
    }

    /// 自引用是合法惯用法：`${RUBYOPT:+ $RUBYOPT}` 里外两层都指自己。
    @Test func selfReferencesAreNotWarnings() {
        #expect(
            GuiReferenceWarnings.warnings(in: [
                record("RUBYOPT", "-rlogger${RUBYOPT:+ $RUBYOPT}", gui: true),
                record("FOO", "$FOO/suffix", gui: true),
            ]).isEmpty
        )
    }

    /// 不是列表里的记录（外部环境变量）：gui 域里可能是有的，不报警。
    @Test func externalVariablesAreNotWarnings() {
        #expect(GuiReferenceWarnings.warnings(in: [record("FOO", "$HOME/bin:$USER", gui: true)]).isEmpty)
    }

    /// 单引号样式是字面量，`$` 不展开。
    @Test func singleQuotedValuesAreNotWarnings() {
        #expect(
            GuiReferenceWarnings.warnings(in: [
                record("JAVA_HOME", "/opt/jdk"),
                record("FOO", "$JAVA_HOME/bin", gui: true, style: .single),
            ]).isEmpty
        )
    }

    /// 只在 GUI 层算：没开 GUI 开关的记录不进脚本，谈不上「GUI 层引用不到」。
    @Test func warningsAreGuiLayerOnly() {
        #expect(
            GuiReferenceWarnings.warnings(in: [
                record("JAVA_HOME", "/opt/jdk"),
                record("FOO", "$JAVA_HOME/bin", shell: true, gui: false),
            ]).isEmpty
        )
    }

    /// 一个被引用的变量只报一次，引用原文按出现顺序去重。
    @Test func oneWarningPerReferencedVariable() throws {
        let warnings = GuiReferenceWarnings.warnings(in: [
            record("B", "1"),
            record("A", "$B/x:${B}/y", gui: true),
        ])

        let warning = try #require(warnings["A"]?.first)
        #expect(warnings["A"]?.count == 1)
        #expect(warning.occurrences == ["$B", "${B}"])
        #expect(warning.rendering == "/x:/y")
    }

    /// 自带兜底的写法（`${B:-默认值}`）：报「拿不到 B 的值」，但不给「会变成什么」的确定预览。
    @Test func fallbackFormsAreReportedWithoutARendering() throws {
        let warnings = GuiReferenceWarnings.warnings(in: [
            record("B", "1"),
            record("A", "${B:-/opt}/bin", gui: true),
        ])

        let warning = try #require(warnings["A"]?.first)
        #expect(warning.referencedKey == "B")
        #expect(warning.rendering == nil)
        #expect(warning.detail.contains("取决于这个写法本身"))
        #expect(!warning.detail.contains("整条值会变成"))
    }

    /// 整条值就是那一处引用：预览说「空」，而不是留一行空白。
    @Test func wholeValueReferencePreviewsAsEmpty() throws {
        let warnings = GuiReferenceWarnings.warnings(in: [
            record("B", "1"),
            record("A", "$B", gui: true),
        ])

        let warning = try #require(warnings["A"]?.first)
        #expect(warning.rendering == "")
        #expect(warning.detail.contains("整条值会变成空"))
        #expect(!warning.lines.contains { $0.kind == .preview })
    }

    /// 秘密值：值预览跟列表预览同一套规则打码，警告卡片不该成为绕过打码的探针。
    @Test func secretValuesAreMaskedInThePreview() throws {
        let entries: [ManagedEntry] = [
            record("B", "1"),
            .record(
                VariableRecord(
                    key: "TOKEN", rawValue: "$B/sk-live-9f3a81c7",
                    shellEnabled: true, guiEnabled: true, secret: true
                )
            ),
        ]

        let masked = try #require(GuiReferenceWarnings.warnings(in: entries)["TOKEN"]?.first?.rendering)
        #expect(masked == SecretMasking.masked("/sk-live-9f3a81c7"))
        #expect(!masked.contains("sk-live"))

        // 点过「显示」才给明文
        let revealed = try #require(
            GuiReferenceWarnings.warnings(in: entries, revealedKey: "TOKEN")["TOKEN"]?.first?.rendering
        )
        #expect(revealed == "/sk-live-9f3a81c7")
    }

    /// 没开 GUI 开关的引用者：同一个引用，开关一开就报。
    @Test func enablingTheGuiSwitchStartsReporting() throws {
        let entries: [ManagedEntry] = [
            record("JAVA_HOME", "/opt/jdk"),
            record("FOO", "$JAVA_HOME/bin", gui: true),
        ]
        #expect(GuiReferenceWarnings.warnings(in: entries)["FOO"]?.count == 1)
        #expect(GuiReferenceWarnings.warnings(in: [entries[0], record("FOO", "$JAVA_HOME/bin")]).isEmpty)
    }
}

// MARK: - 诊断清单的呈现

struct DiagnosisPresentationTests {
    private func diagnosis(_ checks: [(String, GuiCheckStatus)]) -> GuiDiagnosis {
        GuiDiagnosis(checks: checks.map { GuiCheck(name: $0.0, detail: "", status: $0.1) })
    }

    /// 「打开系统设置的登录项面板」按钮只跟后台项那一行有关：它不通过才出现。
    /// 判定按标题常量，不再对标题做子串匹配（标题是行身份，见 `GuiCheckTitle`）。
    @Test func loginItemsShortcutFollowsTheBackgroundItemRow() {
        #expect(diagnosis([(GuiCheckTitle.backgroundItem, .failed)]).hasBackgroundItemProblem)
        #expect(diagnosis([(GuiCheckTitle.backgroundItem, .warning)]).hasBackgroundItemProblem)
        #expect(!diagnosis([(GuiCheckTitle.backgroundItem, .ok)]).hasBackgroundItemProblem)
        // 别的行出问题不算：这个按钮不去修脚本、plist 或注册的事
        #expect(!diagnosis([(GuiCheckTitle.script, .failed), (GuiCheckTitle.agentFile, .failed)]).hasBackgroundItemProblem)
        #expect(!diagnosis([(GuiCheckTitle.backgroundItem, .ok), (GuiCheckTitle.agentRegistration, .warning)]).hasBackgroundItemProblem)
    }
}

// MARK: - 错误文案

struct EngineErrorMessagesTests {
    @Test func driftOffersReload() {
        let dialog = EngineErrorMessages.dialog(for: EngineError.driftDetected)
        #expect(dialog.action == .reloadFromDisk)
        #expect(dialog.confirmTitle != nil)
        #expect(dialog.isDestructive)
    }

    @Test func malformedBlockIsExplainedWithoutAnAction() {
        let dialog = EngineErrorMessages.dialog(for: EngineError.malformedMarkerBlock)
        #expect(dialog.action == .acknowledge)
        #expect(dialog.confirmTitle == nil)
        #expect(dialog.message.contains(MarkerBlock.beginMarker))
    }

    @Test func nonEngineErrorsFallBackToTheirDescription() {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "炸了" } }
        #expect(EngineErrorMessages.dialog(for: Boom()).message == "炸了")
    }
}
