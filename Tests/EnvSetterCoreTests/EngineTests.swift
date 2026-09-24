import Testing
import Foundation
@testable import EnvSetterCore

struct EngineTests {
    private let guiLabel = "com.example.envsetter-test"

    /// GUI 层测试的固定装置：固定 label 与 launchd-like 环境的引擎（与 `GuiLayerTests.makeLayer` 同构）。
    private func makeGuiEngine(home: URL, paths: EnginePaths, runner: FakeProcessRunner) -> EnvSetterEngine {
        EnvSetterEngine(
            paths: paths,
            gui: GuiLayer(
                paths: paths,
                label: guiLabel,
                runner: runner,
                environment: ["HOME": home.path, "PATH": LaunchAgent.defaultPath],
                uid: 501
            )
        )
    }

    /// 让假执行器回答「没注册」：本工具没装过任何东西时的正常状态。
    private func stubUnregistered(_ runner: FakeProcessRunner) {
        runner.outcomes[[LaunchAgent.launchctlPath, "print", "gui/501/\(guiLabel)"]] = ProcessOutcome(
            exitCode: 113, stdout: "", stderr: "Could not find service"
        )
    }

    @Test func freshSandboxLoadsEmpty() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        let result = try engine.load()
        #expect(result.entries.isEmpty)
        #expect(!result.driftDetected)
        #expect(!result.adoptedExistingBlock)
        #expect(!result.hasMarkerBlock)
        #expect(try engine.checkDrift() == false)
    }

    @Test func adoptAndApplyWritesBlockCommentsOutsideAndSavesStore() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)

        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        let written = try TestSupport.read(paths.zprofileURL)
        // 块外：原行注释、原注释与空行保留
        #expect(written.contains("# export TOOLS="))
        #expect(written.contains("# export PATH="))
        #expect(written.contains("# OpenCode CLI"))
        // 块内：typeset + 按声明顺序导出
        #expect(written.contains(MarkerBlock.typesetLine))
        let location = try MarkerBlock.locate(in: written)
        #expect(location != nil)

        // 本地状态：条目与快照都落了盘
        let store = try StorePersistence.load(from: paths.storeURL)
        #expect(store.entries == plan.entries)
        #expect(store.blockSnapshot == location?.fullText)
        #expect(try engine.checkDrift() == false)

        // 备份：基线 + 时间戳各一份，基线内容 = 收编前原文
        let backups = try engine.backupsList()
        #expect(backups.filter(\.isBaseline).count == 1)
        let baseline = backups.first { $0.isBaseline }!
        #expect(try TestSupport.read(baseline.url) == Fixtures.adoptionFile)
    }

    @Test func applyIsIdempotentWhenNothingChanged() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        let first = try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        let secondPlan = try engine.planAdoption()
        #expect(secondPlan.outsideEdits.isEmpty)
        let second = try engine.apply(entries: secondPlan.entries)
        #expect(second.shellContent == first.shellContent)
        #expect(try TestSupport.read(paths.zprofileURL) == first.shellContent)
    }

    @Test func manualBlockEditTriggersDriftAndFileWins() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        var plan = try engine.planAdoption()
        // 给 JAVA_HOME 开 GUI（模拟用户在应用内的编辑）
        for index in plan.entries.indices {
            if case .record(var record) = plan.entries[index], record.key == "JAVA_HOME" {
                record.guiEnabled = true
                plan.entries[index] = .record(record)
            }
        }
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        // 手工改块内 MAVEN_HOME 的值，再加一行无法解析的行
        let content = try TestSupport.read(paths.zprofileURL)
        let edited = content
            .replacingOccurrences(of: #"export MAVEN_HOME="$TOOLS/maven/apache-maven-3""#,
                                  with: #"export MAVEN_HOME="$TOOLS/maven/apache-maven-4""#)
            .replacingOccurrences(of: MarkerBlock.endMarker,
                                  with: "export WEIRD=a b\n\(MarkerBlock.endMarker)")
        try TestSupport.write(edited, to: paths.zprofileURL)

        #expect(try engine.checkDrift() == true)
        let result = try engine.load()
        #expect(result.driftDetected)
        #expect(try engine.checkDrift() == false) // 重载后快照已更新

        let records = result.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        let maven = records.first { $0.key == "MAVEN_HOME" }
        #expect(maven?.rawValue == "$TOOLS/maven/apache-maven-4")
        // GUI 开关按 key 保留
        let java = records.first { $0.key == "JAVA_HOME" }
        #expect(java?.guiEnabled == true)
        // 无法解析的行逐字保留为 verbatim 条目
        #expect(result.entries.contains { entry in
            if case .verbatim(let line) = entry { return line == "export WEIRD=a b" }
            return false
        })

        // 再应用：verbatim 原样写回，文件与载入后的期望一致
        _ = try engine.apply(entries: result.entries)
        let rewritten = try TestSupport.read(paths.zprofileURL)
        #expect(rewritten.contains("export WEIRD=a b"))
        #expect(rewritten.contains(#"export MAVEN_HOME="$TOOLS/maven/apache-maven-4""#))
    }

    @Test func applyThrowsWhenDriftedUntilLoad() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        // 手工加一行
        let content = try TestSupport.read(paths.zprofileURL)
        try TestSupport.write(content + "\n# 手工备注\n", to: paths.zprofileURL)
        // 块未动 → 不算漂移
        #expect(try engine.checkDrift() == false)

        // 动块 → apply 必须先被拦下
        let edited = content.replacingOccurrences(
            of: MarkerBlock.typesetLine,
            with: MarkerBlock.typesetLine + "\n# 手工改过块"
        )
        try TestSupport.write(edited, to: paths.zprofileURL)
        #expect(throws: EngineError.driftDetected.self) {
            try engine.apply(entries: plan.entries)
        }
        _ = try engine.load() // 以文件为准重载
        _ = try engine.apply(entries: plan.entries) // 现在可以应用了
    }

    @Test func applyThrowsWhenOutsideLinesChangedSincePlan() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()

        var content = Fixtures.adoptionFile
        let first = plan.outsideEdits[0]
        content = FileText(content).replacingLine(at: first.lineIndex, with: first.originalLine + " # 改过")
        try TestSupport.write(content, to: paths.zprofileURL)

        #expect(throws: EngineError.fileChangedSincePlan.self) {
            try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)
        }
    }

    @Test func deletingWholeBlockDisablesShellLayerOnReload() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        // 用户把块整个删了，只留注释行
        let content = try TestSupport.read(paths.zprofileURL)
        let location = try MarkerBlock.locate(in: content)!
        let stripped = content
            .replacingOccurrences(of: location.fullText + "\n", with: "")
        try TestSupport.write(stripped, to: paths.zprofileURL)

        let result = try engine.load()
        #expect(result.driftDetected)
        #expect(!result.hasMarkerBlock)
        let records = result.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        #expect(records.allSatisfy { !$0.shellEnabled })
        #expect(records.allSatisfy { $0.key != "PATH" } == false) // PATH 记录仍在，只是 shell 关
    }

    @Test func atomicWritePreservesPermissions() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let url = try TestSupport.write("a=1\n", to: paths.zprofileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        _ = try engine.apply(entries: [.record(VariableRecord(key: "A", rawValue: "1"))])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
    }

    /// 移除一条 GUI 层记录并应用：它的 key 要从 gui 域里清掉（界面上承诺的就是这件事）。
    /// 边界不变：本工具没拥有过的 key（脚本里的外来行）一律不碰。
    @Test func removingAGuiRecordClearsItsKeyFromTheDomain() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        let a = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        let b = ManagedEntry.record(VariableRecord(key: "B", rawValue: "2", guiEnabled: true))
        let initial = try engine.apply(entries: [a, b])
        #expect(initial.gui?.removalCandidates.isEmpty == true)
        #expect(initial.gui?.clearedKeys.isEmpty == true)
        #expect(initial.gui?.pendingGuiRemovals.isEmpty == true)
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "B"]))

        // 手工往工具自己的脚本里塞一行外来 key：它不在任何记录里，不该被清
        let script = try TestSupport.read(paths.guiScriptURL)
        try TestSupport.write(
            script + "\n\(LaunchAgent.launchctlPath) setenv FOREIGN \"$FOREIGN\"\n",
            to: paths.guiScriptURL
        )

        // B 被移除（草稿里不再有它）→ 应用后 gui 域里也不该留着它
        let result = try engine.apply(entries: [a])

        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "B"]))
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "FOREIGN"]))
        #expect(result.gui?.removalCandidates == ["B"])
        #expect(result.gui?.clearedKeys == ["B"])
        #expect(result.gui?.pendingGuiRemovals.isEmpty == true)
        #expect(result.gui?.removedKeys == ["B"])
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals.isEmpty)

        // 再应用一次：脚本里已经没有 B 了，不该重复清
        let callsBefore = runner.calls.count
        _ = try engine.apply(entries: [a])
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "B"], since: callsBefore))
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"]))
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals.isEmpty)
    }

    @Test func failedGuiRemovalSurvivesEngineRecreationAndRetry() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        stubUnregistered(runner)

        let firstEngine = makeGuiEngine(home: home, paths: paths, runner: runner)
        let applied = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        _ = try firstEngine.apply(entries: [applied])
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "Unsetenv failed"
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "stale\n", stderr: ""
        )

        let removed = try firstEngine.apply(entries: [])
        #expect(removed.gui?.removalCandidates == ["A"])
        #expect(removed.gui?.clearedKeys.isEmpty == true)
        #expect(removed.gui?.pendingGuiRemovals == ["A"])
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])
        let leftover = try #require(
            firstEngine.guiDiagnosis()?.checks.first { $0.name == GuiCheckTitle.disabledLeftovers }
        )
        #expect(leftover.status == .warning)
        #expect(leftover.detail.contains("A"))

        // 新引擎实例不再依赖旧脚本也能从落盘的待清理残留发现并重试。
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "", stderr: ""
        )
        let retry = try #require(try makeGuiEngine(home: home, paths: paths, runner: runner).retryGuiSync())
        #expect(retry.removalCandidates == ["A"])
        #expect(retry.clearedKeys == ["A"])
        #expect(retry.pendingGuiRemovals.isEmpty)
        #expect(retry.outcome == .uninstalled)
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
    }

    @Test func guiRemovalReportSeparatesSuccessfulAndFailedKeys() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        stubUnregistered(runner)
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        let a = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        let b = ManagedEntry.record(VariableRecord(key: "B", rawValue: "2", guiEnabled: true))
        let c = ManagedEntry.record(VariableRecord(key: "C", rawValue: "3", guiEnabled: true))
        _ = try engine.apply(entries: [a, b, c])
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "Unsetenv failed"
        )

        let result = try engine.apply(entries: [c])
        let report = try #require(result.gui)

        #expect(report.removalCandidates == ["A", "B"])
        #expect(report.clearedKeys == ["B"])
        #expect(report.pendingGuiRemovals == ["A"])
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])
    }

    /// 审查发现的原始形态：**其他 GUI 变量还在**时，脚本会被重写成不含 A——旧脚本从此给不出线索，
    /// 只剩持久化的待清理残留。清不掉时这份记录必须活下来，重建引擎实例后仍能发现并清除。
    @Test func failedGuiRemovalIsRetriedWhileOtherGuiVariablesRemain() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        stubUnregistered(runner)

        let a = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        let b = ManagedEntry.record(VariableRecord(key: "B", rawValue: "2", guiEnabled: true))
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        _ = try engine.apply(entries: [a, b])

        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "Unsetenv failed"
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "stale\n", stderr: ""
        )
        let removed = try engine.apply(entries: [b])

        #expect(removed.gui?.outcome == .partial)
        #expect(removed.gui?.removalCandidates == ["A"])
        #expect(removed.gui?.clearedKeys.isEmpty == true)
        #expect(removed.gui?.pendingGuiRemovals == ["A"])
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])
        // B 还在，所以脚本被重写成只剩 B：A 的 key 从脚本里消失，旧脚本再也提供不了线索
        let script = try TestSupport.read(paths.guiScriptURL)
        #expect(script.contains("B="))
        #expect(!script.contains("A="))

        // 再应用一次：待清理残留不能因为脚本里已经没有 A 而被抹掉
        _ = try engine.apply(entries: [b])
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])
        let leftover = try #require(
            engine.guiDiagnosis()?.checks.first { $0.name == GuiCheckTitle.disabledLeftovers }
        )
        #expect(leftover.status == .warning)
        #expect(leftover.detail.contains("A"))

        // 重建引擎实例后重试仍然失败：记录继续留着（重试失败也不能丢）
        let callsBeforeRetry = runner.calls.count
        _ = try #require(try makeGuiEngine(home: home, paths: paths, runner: runner).retryGuiSync())
        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"], since: callsBeforeRetry))
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])

        // 清成了：记录清空，仍在启用的 B 不受影响
        let callsBeforeSuccess = runner.calls.count
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "", stderr: ""
        )
        let retry = try #require(try makeGuiEngine(home: home, paths: paths, runner: runner).retryGuiSync())

        #expect(runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"], since: callsBeforeSuccess))
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "B"], since: callsBeforeSuccess))
        #expect(retry.pendingGuiRemovals.isEmpty)
        #expect(retry.removalCandidates == ["A"])
        #expect(retry.clearedKeys == ["A"])
        #expect(retry.outcome == .applied)
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals.isEmpty)
        #expect(try TestSupport.read(paths.guiScriptURL).contains("B="))
    }

    @Test func reenabledGuiKeyIsRemovedFromPendingCleanupWithoutUnsetenv() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        stubUnregistered(runner)
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        let a = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        _ = try engine.apply(entries: [a])
        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "Unsetenv failed"
        )
        _ = try engine.apply(entries: [])
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])

        let callsBeforeReenable = runner.calls.count
        let reenabled = try engine.apply(entries: [a])

        #expect(reenabled.gui?.removalCandidates.isEmpty == true)
        #expect(reenabled.gui?.clearedKeys.isEmpty == true)
        #expect(reenabled.gui?.pendingGuiRemovals.isEmpty == true)
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"], since: callsBeforeReenable))
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals.isEmpty)
    }

    @Test func retryGuiSyncDoesNotWriteProfileOrCreateBackups() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        let entry = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        let script = paths.guiScriptURL.path
        runner.outcomes[[LaunchAgent.shellPath, script, SetenvScript.printFlag]] = ProcessOutcome(
            exitCode: 0, stdout: "A=1\n", stderr: ""
        )
        runner.outcomes[[LaunchAgent.launchctlPath, "getenv", "A"]] = ProcessOutcome(
            exitCode: 0, stdout: "1\n", stderr: ""
        )
        _ = try engine.apply(entries: [entry])
        let profileBeforeRetry = try TestSupport.read(paths.zprofileURL)
        let backupsBeforeRetry = try engine.backupsList().count

        runner.outcomes[[LaunchAgent.shellPath, script]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "script failed"
        )
        let failed = try #require(try engine.retryGuiSync())
        #expect(failed.outcome == .partial)
        #expect(failed.warning?.isEmpty == false)

        runner.outcomes[[LaunchAgent.shellPath, script]] = ProcessOutcome(
            exitCode: 0, stdout: "", stderr: ""
        )
        let succeeded = try #require(try engine.retryGuiSync())

        #expect(succeeded.outcome == .applied)
        #expect(try TestSupport.read(paths.zprofileURL) == profileBeforeRetry)
        #expect(try engine.backupsList().count == backupsBeforeRetry)
    }

    /// 块被手工改过（漂移）时，单独重试 GUI 层与显式应用一样先拒绝：
    /// 本地状态已经不是文件的真相，此时同步只会把陈旧值推进 gui 域。
    @Test func retryGuiSyncRefusesWhenTheBlockDrifted() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        _ = try engine.apply(entries: [.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))])

        let profile = try TestSupport.read(paths.zprofileURL)
        try TestSupport.write(
            profile.replacingOccurrences(of: MarkerBlock.typesetLine, with: MarkerBlock.typesetLine + "\n# drift"),
            to: paths.zprofileURL
        )

        let callsBefore = runner.calls.count
        #expect(throws: EngineError.driftDetected.self) {
            try engine.retryGuiSync()
        }
        // 拒绝得干净：没有碰 gui 域，也没有重写脚本
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"], since: callsBefore))
        #expect(!runner.called(LaunchAgent.launchctlPath, ["setenv", "A", "1"], since: callsBefore))
        #expect(try TestSupport.read(paths.guiScriptURL) == engine.gui?.scriptContent(entries: [
            .record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        ]))
    }

    @Test func pendingGuiRemovalsSurviveDriftReloadAndBackupRestore() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write("original profile\n", to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.apply(entries: [.record(VariableRecord(key: "A", rawValue: "1"))])
        var store = try StorePersistence.load(from: paths.storeURL)
        store.pendingGuiRemovals = ["OLD"]
        try StorePersistence.save(store, to: paths.storeURL)

        let profile = try TestSupport.read(paths.zprofileURL)
        try TestSupport.write(
            profile.replacingOccurrences(of: MarkerBlock.typesetLine, with: MarkerBlock.typesetLine + "\n# drift"),
            to: paths.zprofileURL
        )
        #expect(try engine.load().driftDetected)
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["OLD"])

        let baseline = try #require(try engine.backupsList().first { $0.isBaseline })
        try engine.restore(from: baseline)
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["OLD"])
    }

    /// 关掉最后一条 GUI 层变量并应用：GUI 层整体撤掉，shell 层逐字节不动。
    @Test func uninstallingTheGuiLayerLeavesTheShellLayerUntouched() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        // 装上之后注册就没了（bootout 生效）——撤回时不必再取消一次
        stubUnregistered(runner)

        let on: [ManagedEntry] = [.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))]
        let first = try engine.apply(entries: on)
        #expect(first.gui?.outcome == .applied, "\(first.gui?.warning ?? "")")
        #expect(FileManager.default.fileExists(atPath: paths.guiScriptURL.path))

        let off: [ManagedEntry] = [.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: false))]
        let second = try engine.apply(entries: off)

        #expect(second.gui?.outcome == .uninstalled)
        #expect(second.shellContent == first.shellContent)
        #expect(try TestSupport.read(paths.zprofileURL) == first.shellContent)
        #expect(!FileManager.default.fileExists(atPath: paths.guiScriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: LaunchAgent.plistURL(label: guiLabel, paths: paths).path))
    }

    @Test func applyWithoutGuiLayerReportsNoGuiResult() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        let result = try engine.apply(entries: [.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))])
        #expect(result.shellContent.contains("export A="))
        #expect(result.gui == nil)
        #expect(try engine.guiDiagnosis() == nil)
    }

    @Test func guiWriteFailureWarnsButStillWritesShellLayer() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        // 让 GUI 层脚本的父目录是一个文件：脚本写入必然失败，而 ~/.zprofile 与本地状态路径不受影响。
        let blocked = home.appending(path: "blocked")
        try TestSupport.write("not a directory", to: blocked)
        let enginePaths = EnginePaths(
            zprofileURL: paths.zprofileURL,
            storeURL: paths.storeURL,
            backupsDirectory: paths.backupsDirectory,
            launchAgentsDirectory: paths.launchAgentsDirectory,
            guiScriptURL: blocked.appending(path: "setenv.sh")
        )
        let engine = EnvSetterEngine(
            paths: enginePaths,
            gui: GuiLayer(paths: enginePaths, runner: FakeProcessRunner())
        )

        let result = try engine.apply(entries: [.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))])

        // shell 层照常落盘，GUI 层以警告上报
        #expect(try TestSupport.read(paths.zprofileURL).contains("export A="))
        let gui = try #require(result.gui)
        #expect(gui.outcome == .failed)
        #expect(!gui.scriptWritten)
        #expect(try #require(gui.warning).contains("shell 层写入不受影响"))
        // 本地状态也照常保存
        let store = try StorePersistence.load(from: paths.storeURL)
        #expect(store.entries == [.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))])
    }

    @Test func guiScriptWriteFailureLeavesRemovalCandidatePendingWithoutAttemptingCleanup() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let runner = FakeProcessRunner()
        let engine = makeGuiEngine(home: home, paths: paths, runner: runner)
        let a = ManagedEntry.record(VariableRecord(key: "A", rawValue: "1", guiEnabled: true))
        let b = ManagedEntry.record(VariableRecord(key: "B", rawValue: "2", guiEnabled: true))
        _ = try engine.apply(entries: [a, b])

        runner.outcomes[[LaunchAgent.launchctlPath, "unsetenv", "A"]] = ProcessOutcome(
            exitCode: 1, stdout: "", stderr: "Unsetenv failed"
        )
        _ = try engine.apply(entries: [b])

        // 待清理残留已持久化后，改用不可写的脚本路径；状态文件仍保留在原目录。
        let blocked = home.appending(path: "blocked")
        try TestSupport.write("not a directory", to: blocked)
        let brokenPaths = EnginePaths(
            zprofileURL: paths.zprofileURL,
            storeURL: paths.storeURL,
            backupsDirectory: paths.backupsDirectory,
            launchAgentsDirectory: paths.launchAgentsDirectory,
            guiScriptURL: blocked.appending(path: "setenv.sh")
        )
        let brokenEngine = makeGuiEngine(home: home, paths: brokenPaths, runner: runner)
        let callsBefore = runner.calls.count

        let result = try brokenEngine.apply(entries: [b])
        let report = try #require(result.gui)

        #expect(report.outcome == .failed)
        #expect(report.removalCandidates == ["A"])
        #expect(report.clearedKeys.isEmpty)
        #expect(report.pendingGuiRemovals == ["A"])
        #expect(!runner.called(LaunchAgent.launchctlPath, ["unsetenv", "A"], since: callsBefore))
        #expect(try StorePersistence.load(from: paths.storeURL).pendingGuiRemovals == ["A"])
    }

    @Test func atomicWriteFollowsSymlinkInsteadOfReplacingIt() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        let target = home.appending(path: "dotfiles/zprofile.real")
        try TestSupport.write(Fixtures.adoptionFile, to: target)
        let linkURL = paths.zprofileURL
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        let stillSymlink = (try FileManager.default.attributesOfItem(atPath: linkURL.path)[.type] as? FileAttributeType) == .typeSymbolicLink
        #expect(stillSymlink)
        #expect(try TestSupport.read(target).contains(MarkerBlock.beginMarker))
        #expect(try TestSupport.read(target).contains("# export TOOLS="))
    }

    @Test func restoreBaselineReturnsFileToPreAdoptionState() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        let backups = try engine.backupsList()
        let baseline = backups.first { $0.isBaseline }!
        try engine.restore(from: baseline)

        #expect(try TestSupport.read(paths.zprofileURL) == Fixtures.adoptionFile)
        let result = try engine.load()
        #expect(!result.hasMarkerBlock)
        // 块没了：shell 层停用，但记录还在（可再开启）
        let records = result.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { !$0.shellEnabled })
    }

    @Test func storeRoundTripsThroughJSON() throws {
        let (home, _) = try TestSupport.makeSandbox()
        let store = EnvStore(
            entries: [
                .record(VariableRecord(key: "A", rawValue: "$B/${B:-x}", source: .adopted)),
                .record(VariableRecord(key: "B", rawValue: "1", guiEnabled: true, source: .toolCreated)),
                .verbatim(line: "# keep me"),
            ],
            blockSnapshot: "# >>> EnvSetter >>>\n...\n# <<< EnvSetter <<<",
            pendingGuiRemovals: ["OLD"]
        )
        let url = home.appending(path: "store.json")
        try StorePersistence.save(store, to: url)
        #expect(try StorePersistence.load(from: url) == store)
    }

    @Test func oldStoreWithoutPendingRemovalFieldLoadsAsEmpty() throws {
        let (home, _) = try TestSupport.makeSandbox()
        let url = home.appending(path: "store.json")
        try TestSupport.write(#"{"entries":[],"blockSnapshot":null}"#, to: url)

        #expect(try StorePersistence.load(from: url).pendingGuiRemovals.isEmpty)
    }
}
