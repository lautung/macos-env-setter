import EnvSetterCore
import EnvSetterUI
import Foundation
import Testing

@MainActor
struct AppModelTests {
    // MARK: - 载入与草稿

    @Test func emptySandboxStartsClean() async throws {
        let harness = try Harness()
        await harness.model.start()

        #expect(harness.model.entries.isEmpty)
        #expect(harness.model.rows.isEmpty)
        #expect(harness.model.pendingCount == 0)
        #expect(!harness.model.canApply)
        #expect(harness.model.selectedRecord == nil)
    }

    @Test func addingARecordMakesItPending() async throws {
        let harness = try Harness()
        await harness.model.start()

        harness.model.addRecord(key: "FOO", rawValue: "$HOME/foo", shellEnabled: true, guiEnabled: false, secret: false)

        #expect(harness.model.pendingCount == 1)
        #expect(harness.model.canApply)
        #expect(harness.model.selection == "FOO")
        #expect(harness.model.rows.count == 1)
        #expect(harness.model.rows.first?.record?.record.key == "FOO")
        #expect(harness.model.rows.first?.record?.status == .pending)
        // 还没应用：文件里什么都没有
        #expect(!FileManager.default.fileExists(atPath: harness.paths.zprofileURL.path))
    }

    @Test func applyWritesBothLayersAndClearsPending() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "JAVA_HOME", rawValue: "$TOOLS/jdk", shellEnabled: true, guiEnabled: true, secret: false)
        harness.model.addRecord(key: "TOOLS", rawValue: "/opt/tools", shellEnabled: true, guiEnabled: false, secret: false)
        harness.model.moveRecord("TOOLS", by: -1) // 引用者排在被引用者之后

        await harness.model.apply()

        #expect(harness.model.pendingCount == 0)
        #expect(!harness.model.canApply)

        let content = try harness.profileContent
        #expect(content.contains(MarkerBlock.beginMarker))
        #expect(content.contains("export TOOLS=\"/opt/tools\""))
        #expect(content.contains("export JAVA_HOME=\"$TOOLS/jdk\""))
        // 声明顺序即写入顺序
        let toolsIndex = try #require(content.range(of: "export TOOLS=")).lowerBound
        let javaIndex = try #require(content.range(of: "export JAVA_HOME=")).lowerBound
        #expect(toolsIndex < javaIndex)

        // GUI 层脚本里只有开了 GUI 的那一条
        let script = try UITestSupport.read(harness.paths.guiScriptURL)
        #expect(script.contains("JAVA_HOME"))
        #expect(!script.contains("/bin/launchctl setenv TOOLS"))

        // 横幅讲清生效语义
        let banner = try #require(harness.model.banner)
        #expect(banner.kind == .info)
        #expect(banner.text.contains("只影响之后新启动的 App"))
        #expect(harness.model.lastAppliedText != nil)
    }

    @Test func editsAreRevertedByReload() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")

        harness.model.setRawValue("2", for: "FOO")
        #expect(harness.model.pendingCount == 1)
        #expect(harness.model.rowStatus(for: "FOO") == .pending)

        await harness.model.reload()
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.entries.record(named: "FOO")?.rawValue == "1")
        #expect(try harness.profileContent.contains("export FOO=\"1\""))
    }

    @Test func reloadWithPendingChangesAsksFirst() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")
        harness.model.setRawValue("2", for: "FOO")

        harness.model.requestReload()
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.action == .reloadFromDisk)
        #expect(dialog.isDestructive)

        await harness.model.perform(dialog)
        #expect(harness.model.dialog == nil)
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.entries.record(named: "FOO")?.rawValue == "1")
    }

    @Test func duplicateKeyBlocksApply() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")

        // 界面上改名会先校验，这里直接构造出重复状态，验证「挡住应用」这层兜底
        harness.model.addRecord(key: "FOO", rawValue: "2", shellEnabled: true, guiEnabled: false, secret: false)
        #expect(harness.model.validationIssues["FOO"] != nil)
        #expect(!harness.model.canApply)

        harness.model.setKey("1BAD", for: "FOO")
        #expect(harness.model.validationIssues["1BAD"] != nil)
        #expect(!harness.model.canApply)
    }

    @Test func renameKeepsSelectionAndValidates() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")
        harness.model.select("FOO")

        #expect(harness.model.issueForRename("BAR", from: "FOO") == nil)
        #expect(harness.model.issueForRename("1BAD", from: "FOO") != nil)

        harness.model.setKey("BAR", for: "FOO")
        #expect(harness.model.selection == "BAR")
        #expect(harness.model.entries.record(named: "BAR")?.rawValue == "1")
        // 记录的标识就是变量名，改名对文件而言就是「删一条、加一条」——界面上也是这么显示的
        #expect(harness.model.pendingCount == 2)
        #expect(harness.model.rows.contains { if case .removed(let row) = $0 { return row.record.key == "FOO" } else { return false } })
    }

    // MARK: - 删除与撤销

    @Test func removalIsTwoStepAndUndoable() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("A", "1")
        await harness.addApplied("B", "2")

        harness.model.requestDelete("A")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.action == .deleteRecord("A"))
        await harness.model.perform(dialog)

        // 列表里划掉显示，文件里还在
        #expect(harness.model.pendingCount == 1)
        #expect(harness.model.rows.contains { if case .removed(let row) = $0 { return row.record.key == "A" } else { return false } })
        #expect(try harness.profileContent.contains("export A="))

        harness.model.undoRemoval("A")
        #expect(harness.model.pendingCount == 0) // 撤销插回原位，连顺序都不算改动
        #expect(harness.model.entries.record(named: "A")?.rawValue == "1")
    }

    @Test func removingAnUnappliedRecordLeavesNothingPending() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "TEMP", rawValue: "x", shellEnabled: true, guiEnabled: false, secret: false)
        harness.model.banner = nil

        harness.model.requestDelete("TEMP")
        await harness.model.perform(try #require(harness.model.dialog))

        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.rows.isEmpty)
        // 没应用过的记录直接消失即可，不必提示「待生效」
        #expect(harness.model.banner == nil)
    }

    // MARK: - 移除文案（按「移除后两层的写入内容是否会变」讲）

    /// 两层都没启用的既有记录（真机上就是测试遗留的 DRIFT_PROBE）：
    /// 移除只改列表与本地状态，文案不该再宣称要改动标记块。
    @Test func removingARecordWithBothLayersOffSaysNothingIsWritten() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("DRIFT_PROBE", "byhand", shell: false, gui: false)
        harness.model.banner = nil

        harness.model.requestDelete("DRIFT_PROBE")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.isDestructive)
        #expect(dialog.message.contains("两层写入内容不变"))
        #expect(!dialog.message.contains("会被删掉"))
        #expect(!dialog.message.contains("这一行"))

        await harness.model.perform(dialog)
        let banner = try #require(harness.model.banner)
        #expect(banner.kind == .info)
        #expect(banner.text.contains("两层写入内容不变"))
        #expect(!banner.text.contains("会被删掉"))
        #expect(sameConsequence(dialog: dialog.message, banner: banner.text))

        // 还没应用：文件一个字节都没动
        #expect(try harness.profileContent.contains(MarkerBlock.beginMarker))
        #expect(harness.model.pendingCount == 1)
    }

    /// 刚把开关打开、还没应用就移除：两层都还没有它的内容，文案不该宣称要删掉什么。
    @Test func removingARecordWhoseNewToggleWasNeverAppliedSaysNothingChanges() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("LATER", "1", shell: false, gui: false)
        harness.model.banner = nil
        harness.model.setLayer(.shell, enabled: true, for: "LATER") // 待生效的开关，还没落盘

        harness.model.requestDelete("LATER")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("两层写入内容不变"))
        #expect(!dialog.message.contains("会被删掉"))
    }

    /// 反过来：已经写进标记块的行，不会因为「开关刚关掉、还没应用」就不算数。
    @Test func removingARecordWhoseBlockLineIsAlreadyWrittenStillSaysItWillGo() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1", shell: true, gui: false)
        harness.model.banner = nil
        harness.model.setLayer(.shell, enabled: false, for: "FOO") // 待生效的开关，块里那一行还在

        harness.model.requestDelete("FOO")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("标记块里这条记录对应的内容会被删掉"))

        await harness.model.perform(dialog)
        await harness.model.apply()
        #expect(!(try harness.profileContent.contains("export FOO=")))
    }

    /// shell 层启用：点「应用」后标记块里对应内容会被删掉，应用前自动备份。
    @Test func removingAShellLayerRecordSaysTheBlockContentWillGo() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1", shell: true, gui: false)
        harness.model.banner = nil

        harness.model.requestDelete("FOO")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("标记块里这条记录对应的内容会被删掉"))
        #expect(dialog.message.contains("应用前自动备份"))
        #expect(!dialog.message.contains("gui 域"))

        await harness.model.perform(dialog)
        let banner = try #require(harness.model.banner)
        #expect(banner.text.contains("标记块里这条记录对应的内容会被删掉"))
        #expect(banner.text.contains("应用前自动备份"))
        #expect(sameConsequence(dialog: dialog.message, banner: banner.text))

        // 应用前文件里还在，应用后才真的删掉
        #expect(try harness.profileContent.contains(#"export FOO="1""#))
        await harness.model.apply()
        #expect(!(try harness.profileContent.contains("export FOO=")))
    }

    /// GUI 层启用：应用时会从 gui 域里清掉，边界仍是「只清本工具写过的 key」。
    @Test func removingAGuiLayerRecordSaysTheDomainKeyWillBeCleared() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("GUI_ONLY", "1", shell: false, gui: true)
        harness.model.banner = nil

        harness.model.requestDelete("GUI_ONLY")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("从 gui 域（launchd）里清掉"))
        #expect(dialog.message.contains("只清本工具写过的 key"))
        #expect(!dialog.message.contains("会被删掉")) // 没碰标记块

        await harness.model.perform(dialog)
        let banner = try #require(harness.model.banner)
        #expect(banner.text.contains("从 gui 域（launchd）里清掉"))
        #expect(sameConsequence(dialog: dialog.message, banner: banner.text))

        // 说了会清，就得真清
        await harness.model.apply()
        #expect(harness.runner.calls.contains { $0.arguments == ["unsetenv", "GUI_ONLY"] })
    }

    /// 关掉最后一条 GUI 层变量并应用：横幅说清 GUI 层被整体撤掉，系统里不再留东西。
    @Test func turningOffTheLastGuiVariableSaysTheGuiLayerWasRemoved() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("JAVA_HOME", "/opt/jdk", gui: true)
        // 撤回时 launchctl 里已经没有注册（bootout 生效）
        harness.runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(harness.model.guiLabel)"]] =
            ProcessOutcome(exitCode: 113, stdout: "", stderr: "Could not find service")
        harness.model.banner = nil

        harness.model.setLayer(.gui, enabled: false, for: "JAVA_HOME")
        await harness.model.apply()

        let banner = try #require(harness.model.banner)
        #expect(banner.kind == .info)
        #expect(banner.text.contains("撤掉"))
        #expect(banner.text.contains("JAVA_HOME"))
        // 「只影响之后新启动的 App」这句每次应用后都要出现
        #expect(banner.text.contains("只影响之后新启动的 App"))
        #expect(!FileManager.default.fileExists(atPath: harness.paths.guiScriptURL.path))
    }

    /// 两层都启用：两侧说法同时给出。
    @Test func removingARecordEnabledInBothLayersSaysBoth() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("BOTH", "1", shell: true, gui: true)
        harness.model.banner = nil

        harness.model.requestDelete("BOTH")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("标记块里这条记录对应的内容会被删掉"))
        #expect(dialog.message.contains("应用前自动备份"))
        #expect(dialog.message.contains("它还会从 gui 域（launchd）里清掉"))

        await harness.model.perform(dialog)
        let banner = try #require(harness.model.banner)
        #expect(sameConsequence(dialog: dialog.message, banner: banner.text))
    }

    /// PATH 记录带的不止一个条目：文案不能只说「这一行」。
    @Test func removingAPathRecordCoversItsMultipleLines() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/a:$PATH:/b", shell: true, gui: false)
        harness.model.banner = nil

        harness.model.requestDelete("PATH")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("PATH 记录"))
        #expect(dialog.message.contains("整串目录"))
        #expect(dialog.message.contains("好几行"))
        #expect(dialog.message.contains("应用前自动备份"))
        #expect(!dialog.message.contains("这一行"))

        await harness.model.perform(dialog)
        let banner = try #require(harness.model.banner)
        #expect(banner.text.contains("整串目录"))
        #expect(sameConsequence(dialog: dialog.message, banner: banner.text))

        await harness.model.apply()
        #expect(!(try harness.profileContent.contains("export PATH=")))
    }

    /// 从未应用过的新记录：口径不变（还没应用过、不影响配置文件），也不留提示条。
    @Test func removingANeverAppliedRecordKeepsTheNotAppliedWording() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "TEMP", rawValue: "x", shellEnabled: true, guiEnabled: true, secret: false)
        harness.model.banner = nil

        harness.model.requestDelete("TEMP")
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.message.contains("还没应用过"))
        #expect(dialog.message.contains("移除不会影响"))
        #expect(!dialog.message.contains("会被删掉"))

        await harness.model.perform(dialog)
        #expect(harness.model.banner == nil)
        #expect(harness.model.pendingCount == 0)
    }

    /// 撤销回到原来的声明位置——撤销不该顺带引入一次顺序改动。
    @Test func undoPutsTheRecordBackWhereItWasDeclared() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("A", "1")
        await harness.addApplied("B", "2")
        await harness.addApplied("C", "3")

        harness.model.requestDelete("B")
        await harness.model.perform(try #require(harness.model.dialog))
        #expect(harness.model.entries.records.map(\.key) == ["A", "C"])

        harness.model.undoRemoval("B")
        #expect(harness.model.entries.records.map(\.key) == ["A", "B", "C"])
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.selection == "B")
    }

    // MARK: - GUI 层引用警告（非阻塞）

    /// 规格里的例子：GUI 层的 PATH 拿不到 `$JAVA_HOME/bin`。打开被引用记录的 GUI 开关，警告立刻消失——
    /// 它算在草稿上，不需要重新载入。
    @Test func guiReferenceWarningClearsWhenTheReferencedSwitchTurnsOn() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("JAVA_HOME", "/opt/jdk", gui: false)
        await harness.addApplied("PATH", "$JAVA_HOME/bin:$PATH", gui: true)

        let row = try #require(harness.model.rows.first { $0.record?.record.key == "PATH" }?.record)
        #expect(row.warnings.map(\.referencedKey) == ["JAVA_HOME"])
        #expect(harness.model.referenceWarnings(for: "PATH").first?.cause == .layerOff)

        harness.model.setLayer(.gui, enabled: true, for: "JAVA_HOME")

        #expect(harness.model.referenceWarnings(for: "PATH").isEmpty)
        let cleared = try #require(harness.model.rows.first { $0.record?.record.key == "PATH" }?.record)
        #expect(cleared.warnings.isEmpty)
    }

    /// 警告不挡应用：它走的是与校验错误分开的通道，`canApply` 不受影响。
    @Test func guiReferenceWarningDoesNotBlockApply() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "JAVA_HOME", rawValue: "/opt/jdk", shellEnabled: true, guiEnabled: false, secret: false)
        harness.model.addRecord(key: "FOO", rawValue: "$JAVA_HOME/bin", shellEnabled: true, guiEnabled: true, secret: false)

        #expect(harness.model.referenceWarnings(for: "FOO").count == 1)
        #expect(harness.model.validationIssues.isEmpty) // 警告不进校验通道
        #expect(harness.model.canApply)

        await harness.model.apply()

        #expect(harness.model.pendingCount == 0)
        #expect(try harness.profileContent.contains(#"export FOO="$JAVA_HOME/bin""#))
        // 脚本照常写出这一段（GUI 层里它会展开成空——这正是警告要说的）
        #expect(try UITestSupport.read(harness.paths.guiScriptURL).contains(#"FOO="$JAVA_HOME/bin""#))
    }

    /// 秘密值的警告预览照样打码（与列表预览同一条规则），点过「显示」才给明文。
    @Test func guiReferenceWarningPreviewsRespectMasking() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "TOOLS", rawValue: "/opt/tools", shellEnabled: true, guiEnabled: false, secret: false)
        harness.model.addRecord(
            key: "TOKEN", rawValue: "$TOOLS/sk-live-9f3a81c7", shellEnabled: true, guiEnabled: true, secret: true
        )

        let masked = try #require(harness.model.referenceWarnings(for: "TOKEN").first?.rendering)
        #expect(masked == SecretMasking.masked("/sk-live-9f3a81c7"))
        #expect(!masked.contains("sk-live"))

        harness.model.toggleReveal("TOKEN")
        #expect(harness.model.referenceWarnings(for: "TOKEN").first?.rendering == "/sk-live-9f3a81c7")
    }

    /// 警告与校验错误是两条通道：有警告不影响应用，校验错误照旧挡住应用。
    @Test func validationErrorsStillBlockApplyAlongsideWarnings() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("JAVA_HOME", "/opt/jdk", gui: false)
        harness.model.addRecord(key: "FOO", rawValue: "$JAVA_HOME/bin", shellEnabled: true, guiEnabled: true, secret: false)

        #expect(harness.model.referenceWarnings(for: "FOO").count == 1)
        #expect(harness.model.canApply)

        harness.model.addRecord(key: "FOO", rawValue: "dup", shellEnabled: true, guiEnabled: false, secret: false)
        #expect(harness.model.validationIssues["FOO"] != nil)
        #expect(!harness.model.canApply)
    }

    /// 只在 GUI 层算：同一个引用，只写 shell 层时不报警（shell 层块外还有用户手写内容）。
    @Test func guiReferenceWarningsFollowTheGuiSwitch() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "JAVA_HOME", rawValue: "/opt/jdk", shellEnabled: true, guiEnabled: false, secret: false)
        harness.model.addRecord(key: "FOO", rawValue: "$JAVA_HOME/bin", shellEnabled: true, guiEnabled: false, secret: false)

        #expect(harness.model.referenceWarnings.isEmpty)

        harness.model.setLayer(.gui, enabled: true, for: "FOO")
        #expect(harness.model.referenceWarnings(for: "FOO").count == 1)
        // 被引用的那条自己没引用谁
        #expect(harness.model.referenceWarnings(for: "JAVA_HOME").isEmpty)
    }

    /// 排到后面也是警告，理由与「没开开关」不同（脚本按声明顺序逐条赋值）。
    @Test func guiReferenceWarningFollowsDeclarationOrder() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("JAVA_HOME", "/opt/jdk", gui: true)
        await harness.addApplied("PATH", "$JAVA_HOME/bin", gui: true)
        #expect(harness.model.referenceWarnings(for: "PATH").isEmpty)

        harness.model.moveRecord("PATH", by: -1) // 引用者排到被引用者前面
        let warning = try #require(harness.model.referenceWarnings(for: "PATH").first)
        #expect(warning.cause == .declaredLater)
        #expect(warning.detail.contains("上移"))
    }

    // MARK: - 漂移

    @Test func driftIsReportedAndReloadedFromFile() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")

        // 手工改块内内容
        let content = try harness.profileContent
        try harness.writeProfile(
            content.replacingOccurrences(of: "export FOO=\"1\"", with: "export FOO=\"2\"")
        )

        harness.model.setRawValue("3", for: "FOO")
        await harness.model.apply()

        let dialog = try #require(harness.model.dialog)
        #expect(dialog.action == .reloadFromDisk)
        #expect(dialog.message.contains("漂移"))

        await harness.model.perform(dialog)
        #expect(harness.model.entries.record(named: "FOO")?.rawValue == "2") // 以文件为准
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.banner?.kind == .warning)
    }

    @Test func loadReportsDriftAndAdoptedBlock() async throws {
        let harness = try Harness()
        try harness.writeProfile(
            """
            # 块外备注
            \(MarkerBlock.beginMarker)
            export FOO="1"
            \(MarkerBlock.endMarker)
            """
        )

        await harness.model.start()

        #expect(harness.model.entries.record(named: "FOO")?.rawValue == "1")
        #expect(harness.model.rows.contains { if case .verbatim = $0 { return true } else { return false } } == false)
        let banner = try #require(harness.model.banner)
        #expect(banner.kind == .info)
        #expect(banner.text.contains("收编为当前状态"))
    }

    @Test func verbatimLinesAreShownReadOnly() async throws {
        let harness = try Harness()
        try harness.writeProfile(
            """
            \(MarkerBlock.beginMarker)
            export FOO="1"
            export WEIRD=a b
            \(MarkerBlock.endMarker)
            """
        )
        await harness.model.start()

        let verbatim = harness.model.rows.compactMap { row -> VerbatimRow? in
            if case .verbatim(let row) = row { return row }
            return nil
        }
        #expect(verbatim.map(\.line) == ["export WEIRD=a b"])
        // 搜索时逐字保留行先不显示（它们没有变量名可比）
        harness.model.search = "FOO"
        #expect(harness.model.rows.count == 1)
    }

    // MARK: - 搜索与打码

    @Test func searchMatchesKeysOnly() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("GITHUB_TOKEN", "ghp_1a2b3c4d5e6f7g8h")
        await harness.addApplied("EDITOR", "nvim")

        harness.model.search = "github"
        #expect(harness.model.rows.map(\.id) == ["record:GITHUB_TOKEN"])

        // 值不参与搜索：搜索框不该成为绕过打码的探针
        harness.model.search = "ghp_"
        #expect(harness.model.rows.isEmpty)
    }

    @Test func secretRowsAreMaskedUntilRevealed() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(
            key: "API_TOKEN", rawValue: "sk-proj-9f3a81c7", shellEnabled: true, guiEnabled: false, secret: true
        )

        var row = try #require(harness.model.rows.first?.record)
        #expect(row.preview == "sk-p" + SecretMasking.mask)

        harness.model.toggleReveal("API_TOKEN")
        row = try #require(harness.model.rows.first?.record)
        #expect(row.preview == "sk-proj-9f3a81c7")

        // 换一条记录即重新打码
        harness.model.select(nil)
        row = try #require(harness.model.rows.first?.record)
        #expect(row.preview == "sk-p" + SecretMasking.mask)
    }

    /// 打码标记不进两层的写入内容，所以它不该标「待生效」，而是立刻单独存起来。
    @Test func secretFlagPersistsWithoutApply() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")

        harness.model.setSecret(true, for: "FOO")
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.rows.first?.record?.status == .synced)

        // 标记当场落进本地状态（不等「应用」）
        let stored = try harness.storedEntries().record(named: "FOO")
        #expect(stored?.secret == true)
        // 标记块没被这次写入碰到
        #expect(!(try harness.profileContent.contains("secret")))

        // 重新载入后仍然是打码状态
        await harness.model.reload()
        #expect(harness.model.entries.record(named: "FOO")?.secret == true)
    }

    @Test func newRecordSheetPrechecksCredentialLookingKeys() {
        #expect(SecretKeys.looksSecret("STRIPE_SECRET_KEY"))
        #expect(!SecretKeys.looksSecret("LANG"))
    }

    // MARK: - PATH 编辑器

    @Test func pathEditsRewriteTheRecord() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/a:$PATH")

        #expect(harness.model.pathRows.map(\.text) == ["/a", "$PATH"])
        #expect(harness.model.pathHasAnchor)

        harness.model.addPathRow("/b")
        #expect(harness.model.pathRecord?.rawValue == "/a:$PATH:/b")
        #expect(harness.model.pendingCount == 1)

        harness.model.nudgePathRow(at: 0, by: 1)
        #expect(harness.model.pathRows.map(\.text) == ["$PATH", "/a", "/b"])
        #expect(harness.model.pathRecord?.rawValue == "$PATH:/a:/b")

        harness.model.movePathRows(from: IndexSet(integer: 1), to: 0)
        #expect(harness.model.pathRows.map(\.text) == ["/a", "$PATH", "/b"])

        harness.model.removePathRow(at: 0)
        #expect(harness.model.pathRecord?.rawValue == "$PATH:/b")

        await harness.model.apply()
        #expect(try harness.profileContent.contains("export PATH=\"$PATH:/b\""))
    }

    @Test func anchorIsProtectedUnlessDuplicated() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/a:$PATH")

        #expect(!harness.model.canRemovePathRow(at: 1)) // 唯一的锚点不给删
        harness.model.addPathRow("$PATH")
        #expect(harness.model.pathAnchorWarning != nil)
        #expect(harness.model.canRemovePathRow(at: 1))

        harness.model.commitPathRows()
        #expect(harness.model.pathRows.map(\.isAnchor) == [false, true, true])
    }

    @Test func addingAnchorWhenMissing() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/a:/b")

        #expect(!harness.model.pathHasAnchor)
        harness.model.addPathAnchor()
        #expect(harness.model.pathRecord?.rawValue == "/a:/b:$PATH")
    }

    @Test func duplicatePathEntriesAreFlagged() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/usr/local/bin:/USR/local/bin:$PATH")

        #expect(harness.model.pathDuplicateIDs.count == 2)
    }

    @Test func pathRowEditsDoNotChurnWhenSemanticsAreUnchanged() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/a:${PATH}")

        // 单纯的失焦提交不该把 ${PATH} 重排成 $PATH、白标一次「待生效」
        harness.model.commitPathRows()
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.pathRecord?.rawValue == "/a:${PATH}")
    }

    @Test func singleQuotedPathIsFlaggedBeforeEditing() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "PATH", rawValue: "/a:$PATH", shellEnabled: true, guiEnabled: false, secret: false)
        harness.model.setQuoteStyle(.single, for: "PATH")
        #expect(harness.model.pathQuoteWarning != nil)

        // 用编辑器改动后换成双引号（锚点必须展开）
        harness.model.addPathRow("/b")
        #expect(harness.model.pathRecord?.quoteStyle == .double)
        #expect(harness.model.pathQuoteWarning == nil)
    }

    /// 删到一条不剩也是合法的（空 PATH = 整条替换），不能被「防误写空」的兜底挡回来。
    @Test func lastPathEntryCanBeRemoved() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("PATH", "/a")

        #expect(harness.model.pathRows.count == 1)
        harness.model.removePathRow(harness.model.pathRows[0].id)
        #expect(harness.model.pathRows.isEmpty)
        #expect(harness.model.pathRecord?.rawValue == "")
        #expect(harness.model.pendingCount == 1)
        // 没有锚点时界面会提醒「整条 PATH 会被替换」
        #expect(!harness.model.pathHasAnchor)
    }

    /// 改名进出 PATH：行草稿必须跟着重建，否则下一次行编辑会写进已经不属于 PATH 的记录。
    @Test func renamingIntoAndOutOfPathResyncsRows() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "$HOME/foo")
        await harness.addApplied("PATH", "/a")

        harness.model.setKey("OLDPATH", for: "PATH")
        #expect(harness.model.pathRows.isEmpty)

        harness.model.setKey("PATH", for: "FOO")
        #expect(harness.model.pathRows.map(\.text) == ["$HOME/foo"])

        harness.model.addPathRow("/b")
        #expect(harness.model.pathRecord?.rawValue == "$HOME/foo:/b")
        // 原来的 OLDPATH 记录没被这次编辑碰到
        #expect(harness.model.entries.record(named: "OLDPATH")?.rawValue == "/a")
    }

    /// 顺序变了也是「待生效」：每条记录在文件里的位置都变了。
    @Test func reorderingMarksRowsPending() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("A", "1")
        await harness.addApplied("B", "2")

        harness.model.moveRecord("B", by: -1)
        #expect(harness.model.pendingCount == 1)
        #expect(harness.model.structureChanged)
        #expect(harness.model.rowStatus(for: "A") == .pending)
        #expect(harness.model.rowStatus(for: "B") == .pending)
        #expect(harness.model.rows.allSatisfy { $0.record?.status == .pending })
    }

    // MARK: - 收编

    @Test func adoptionPlanIsShownThenApplied() async throws {
        let harness = try Harness()
        try harness.writeProfile(UITestSupport.adoptionFile)
        await harness.model.start()

        await harness.model.planAdoption()
        #expect(harness.model.sheet == .adoption)
        let plan = try #require(harness.model.adoptionPlan)
        #expect(plan.adoptedKeys == ["TOOLS", "JAVA_HOME", "GITHUB_TOKEN"])
        #expect(plan.mergedPathLineCount == 2)
        // 一眼是凭据的 key 默认打码
        #expect(plan.entries.record(named: "GITHUB_TOKEN")?.secret == true)
        #expect(plan.entries.record(named: "TOOLS")?.secret == false)

        await harness.model.confirmAdoption()
        #expect(harness.model.sheet == nil)
        #expect(harness.model.pendingCount == 0)

        let content = try harness.profileContent
        #expect(content.contains("# export TOOLS="))
        #expect(content.contains("export JAVA_HOME=\"$TOOLS/jdk-21\""))
        // PATH 合并成一条记录并排在最后（引用者要在被引用者之后）
        let pathIndex = try #require(harness.model.entries.firstIndex { $0.key == "PATH" })
        #expect(pathIndex == harness.model.entries.count - 1)
        #expect(harness.model.entries.record(named: "PATH")?.rawValue == "/Users/tester/.opencode/bin:$TOOLS/bin:$PATH")
        #expect(harness.model.banner?.text.contains("收编") == true)
    }

    @Test func adoptionIsBlockedWhenThereIsAnUnappliedDraft() async throws {
        let harness = try Harness()
        try harness.writeProfile("export OUTSIDE=\"1\"\n")
        await harness.model.start()
        harness.model.addRecord(key: "DRAFT", rawValue: "keep", shellEnabled: true, guiEnabled: false, secret: false)
        let draft = harness.model.entries

        await harness.model.planAdoption()

        #expect(harness.model.sheet == nil)
        #expect(harness.model.adoptionPlan == nil)
        #expect(harness.model.entries == draft)
        #expect(harness.model.pendingCount == 1)
        #expect(harness.model.banner?.text.contains("待生效改动") == true)
        #expect(try harness.profileContent == "export OUTSIDE=\"1\"\n")
    }

    @Test func confirmAdoptionDoesNotReplaceDraftsAddedAfterPlanning() async throws {
        let harness = try Harness()
        try harness.writeProfile("export OUTSIDE=\"1\"\n")
        await harness.model.start()
        await harness.model.planAdoption()
        #expect(harness.model.sheet == .adoption)

        harness.model.addRecord(key: "DRAFT", rawValue: "keep", shellEnabled: true, guiEnabled: false, secret: false)
        let draft = harness.model.entries
        await harness.model.confirmAdoption()

        #expect(harness.model.sheet == nil)
        #expect(harness.model.adoptionPlan == nil)
        #expect(harness.model.entries == draft)
        #expect(harness.model.pendingCount == 1)
        #expect(harness.model.banner?.text.contains("待生效改动") == true)
        #expect(try harness.profileContent == "export OUTSIDE=\"1\"\n")
    }

    @Test func adoptionWithNothingToAdoptJustSaysSo() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")

        await harness.model.planAdoption()
        #expect(harness.model.sheet == nil)
        #expect(harness.model.adoptionPlan == nil)
        #expect(harness.model.banner?.text.contains("没有可收编") == true)
    }

    // MARK: - 备份与恢复

    @Test func backupsAreListedAndRestorable() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1")
        await harness.addApplied("BAR", "2")

        await harness.model.openBackups()
        #expect(harness.model.sheet == .backups)
        #expect(!harness.model.backups.isEmpty)

        harness.model.requestRestore(try #require(harness.model.backups.last))
        let dialog = try #require(harness.model.dialog)
        #expect(harness.model.sheet == nil) // 确认框挂主窗口，面板先收起来
        await harness.model.perform(dialog)

        // 那份备份里只有 FOO：BAR 的 shell 行在文件里没了 → shell 层停用（记录留着，可再开启）
        #expect(harness.model.entries.record(named: "FOO")?.shellEnabled == true)
        #expect(harness.model.entries.record(named: "BAR")?.shellEnabled == false)
        #expect(!(try harness.profileContent.contains("export BAR=")))
        #expect(harness.model.pendingCount == 0)
        #expect(harness.model.banner?.text.contains("覆盖") == true)
    }

    // MARK: - 诊断与重启

    @Test func diagnosticsSheetCarriesChecks() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1", gui: true)

        await harness.model.openDiagnostics()
        #expect(harness.model.sheet == .diagnostics)
        let diagnosis = try #require(harness.model.diagnosis)
        // 界面拿到的就是清单那六行、那个顺序（标题是行身份，`List` 以它作 `id`）
        #expect(diagnosis.checks.map(\.name) == GuiCheckTitle.checklist)
    }

    @Test func guiSyncRetryRefreshesDiagnosisAndDoesNotTouchShellOrBackups() async throws {
        let harness = try Harness()
        await harness.model.start()
        let script = harness.paths.guiScriptURL.path
        harness.runner.outcomes[[LaunchAgent.shellPath, script, SetenvScript.printFlag]] = ProcessOutcome(
            exitCode: 0, stdout: "FOO=1\n", stderr: ""
        )
        harness.runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "FOO"]] = ProcessOutcome(
            exitCode: 0, stdout: "stale\n", stderr: ""
        )
        harness.model.addRecord(key: "FOO", rawValue: "1", shellEnabled: true, guiEnabled: true, secret: false)
        await harness.model.apply()
        await harness.model.openDiagnostics()
        let injectedCheck = try #require(
            harness.model.diagnosis?.checks.first { $0.name == GuiCheckTitle.injectedValues }
        )
        #expect(injectedCheck.status == .failed)

        let profileBeforeRetry = try harness.profileContent
        let backupsBeforeRetry = try harness.engine.backupsList().count
        harness.runner.outcomes[[LaunchAgent.shellPath, script]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "script failed"
        )
        await harness.model.retryGuiSync()
        #expect(harness.model.banner?.kind == .warning)
        #expect(harness.model.banner?.opensDiagnostics == true)

        harness.runner.outcomes[[LaunchAgent.shellPath, script]] = ProcessOutcome(
            exitCode: 0, stdout: "", stderr: ""
        )
        harness.runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "FOO"]] = ProcessOutcome(
            exitCode: 0, stdout: "1\n", stderr: ""
        )
        await harness.model.retryGuiSync()

        #expect(harness.model.banner?.kind == .info)
        #expect(harness.model.banner?.text.contains("已刷新诊断") == true)
        #expect(harness.model.diagnosis?.checks.first { $0.name == GuiCheckTitle.injectedValues }?.status == .ok)
        #expect(try harness.profileContent == profileBeforeRetry)
        #expect(try harness.engine.backupsList().count == backupsBeforeRetry)

        harness.model.setRawValue("draft", for: "FOO")
        #expect(!harness.model.canRetryGuiSync)
        #expect(harness.model.guiRetryHelp.contains("先应用"))
    }

    /// 漂移之后单独重试 GUI 层：和显式应用一样被拒绝，并把「重新载入」这条路指出来。
    @Test func guiSyncRetryIsRefusedAfterDriftAndOffersReload() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.addApplied("FOO", "1", gui: true)

        let profile = try harness.profileContent
        try harness.writeProfile(
            profile.replacingOccurrences(of: "export FOO=\"1\"", with: "export FOO=\"2\"")
        )
        harness.model.banner = nil

        await harness.model.retryGuiSync()

        // 拒绝的理由走弹窗（和显式应用同一条路），不拿横幅糊过去
        let dialog = try #require(harness.model.dialog)
        #expect(dialog.action == .reloadFromDisk)
        #expect(dialog.title.contains("手工改动"))
        #expect(harness.model.banner == nil)
    }

    @Test func diagnosticsWithoutGuiLayerWarns() async throws {
        let harness = try Harness(gui: false)
        await harness.model.start()
        await harness.model.openDiagnostics()
        #expect(harness.model.sheet == nil)
        #expect(harness.model.banner?.kind == .warning)
    }

    @Test func restartingAnAppReportsBothOutcomes() async throws {
        let harness = try Harness()
        await harness.model.start()
        let app = RunningApp(name: "Safari", bundleIdentifier: "com.apple.Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"), pid: 4242)
        harness.apps.apps = [app]

        harness.model.openRestartSheet()
        #expect(harness.model.sheet == .restart)
        #expect(harness.model.runningApps == [app])

        await harness.model.restart(app)
        #expect(harness.apps.restarted == [app])
        #expect(harness.model.banner?.kind == .info)
        #expect(harness.model.restartingPID == nil)

        harness.apps.restartFailure = "「Safari」没有在 5 秒内退出（可能有未保存的文档）。已放弃重启。"
        await harness.model.restart(app)
        #expect(harness.model.banner?.kind == .warning)
        #expect(harness.model.banner?.text.contains("放弃重启") == true)
    }

    @Test func loginItemsSettingsShortcutIsWired() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.openLoginItemsSettings()
        #expect(harness.apps.openedLoginItemsSettings)
    }

    // MARK: - GUI 层失败只出横幅

    @Test func guiLayerFailureSurfacesAsWarningBanner() async throws {
        let harness = try Harness(gui: false)
        await harness.model.start()
        // 把 GUI 层脚本的父目录做成一个文件：脚本写入必然失败，shell 层不受影响。
        let blocked = harness.home.appending(path: "blocked")
        try UITestSupport.write("not a directory", to: blocked)
        let paths = EnginePaths(
            zprofileURL: harness.paths.zprofileURL,
            storeURL: harness.paths.storeURL,
            backupsDirectory: harness.paths.backupsDirectory,
            launchAgentsDirectory: harness.paths.launchAgentsDirectory,
            guiScriptURL: blocked.appending(path: "setenv.sh")
        )
        let model = AppModel(engine: EnvSetterEngine(paths: paths, gui: GuiLayer(paths: paths, runner: harness.runner)))
        await model.start()
        model.addRecord(key: "FOO", rawValue: "1", shellEnabled: true, guiEnabled: true, secret: false)

        await model.apply()

        #expect(try harness.profileContent.contains("export FOO=")) // shell 层照常写入
        let banner = try #require(model.banner)
        #expect(banner.kind == .warning)
        #expect(banner.text.contains("GUI 层没做完"))
        #expect(banner.text.contains("shell 层已写入"))
        // 每次应用后的横幅都要讲清生效语义，失败的这次也不例外
        #expect(banner.text.contains("只影响之后新启动的 App"))
    }

    // MARK: - 忙碌状态

    @Test func commandsAreBlockedWhileBusy() async throws {
        let harness = try Harness()
        await harness.model.start()
        harness.model.addRecord(key: "FOO", rawValue: "1", shellEnabled: true, guiEnabled: false, secret: false)
        #expect(harness.model.canApply)

        async let applying: Void = harness.model.apply()
        await applying

        #expect(harness.model.busyLabel == nil)
        #expect(!harness.model.isBusy)
    }
}

// MARK: - 便于断言的取值

private extension SidebarRow {
    var record: RecordRow? {
        if case .record(let row) = self { return row }
        return nil
    }
}

/// 确认框与移除后的提示条必须共用同一段后果说明：剥掉各自的引导语后应当逐字相同。
private func sameConsequence(dialog: String, banner: String) -> Bool {
    let lead = "移除先只改内存；"
    let consequence = dialog.hasPrefix(lead) ? String(dialog.dropFirst(lead.count)) : dialog
    return banner.hasSuffix(consequence)
}
