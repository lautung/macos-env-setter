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
