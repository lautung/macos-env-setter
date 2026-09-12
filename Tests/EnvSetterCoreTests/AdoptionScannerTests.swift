import Testing
@testable import EnvSetterCore

struct AdoptionScannerTests {
    @Test func plansAdoptionOfUserShapedFile() throws {
        let plan = try AdoptionScanner.plan(fileContent: Fixtures.adoptionFile, currentEntries: [])

        // 7 条非 PATH 记录按文件顺序收编，GUI 默认关、来源为导入
        let records = plan.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        #expect(plan.adoptedKeys == Fixtures.nonPathKeys)
        #expect(records.map(\.key) == Fixtures.nonPathKeys + ["PATH"])
        #expect(records.allSatisfy { !$0.guiEnabled && $0.shellEnabled && $0.source == .adopted })
        #expect(records.first { $0.key == "JAVA_HOME" }?.rawValue == "$TOOLS/jdk/jdk-21/Contents/Home")
        #expect(records.first { $0.key == "SDK_ROOT" }?.rawValue == "$SDK_HOME")
        #expect(records.first { $0.key == "RUBYOPT" }?.rawValue == #"-rlogger${RUBYOPT:+ $RUBYOPT}"#)

        // PATH：两条行语义保持合并，opencode 仍最前、锚点殿后
        let path = records.first { $0.key == "PATH" }
        #expect(path?.rawValue == Fixtures.expectedMergedPath)
        #expect(plan.mergedPathLineCount == 2)

        // 8 行都要注释掉
        #expect(plan.outsideEdits.count == 8)
        #expect(plan.outsideEdits.allSatisfy { $0.replacementLine == "# " + $0.originalLine })

        // 应用计划后的文件：块外只剩注释行与原有注释/空行，字节级其余不动
        var content = Fixtures.adoptionFile
        for edit in plan.outsideEdits {
            content = FileText(content).replacingLine(at: edit.lineIndex, with: edit.replacementLine)
        }
        let final = MarkerBlock.append(original: content, newBlock: MarkerBlock.generate(entries: plan.entries))
        #expect(final.contains("# export TOOLS="))
        #expect(final.contains("# OpenCode CLI"))
        #expect(final.contains("typeset -U path PATH"))
        // 注释行数量：8 条收编行
        #expect(final.split(separator: "\n").filter { $0.hasPrefix("# export") }.count == 8)
    }

    @Test func lastAssignmentWinsForDuplicateKeys() throws {
        let content = """
        export A="first"
        export A="second"
        """
        let plan = try AdoptionScanner.plan(fileContent: content, currentEntries: [])
        #expect(plan.adoptedKeys == ["A"])
        #expect(
            plan.entries == [
                .record(VariableRecord(key: "A", rawValue: "second", shellEnabled: true, guiEnabled: false, source: .adopted))
            ]
        )
        #expect(plan.outsideEdits.count == 2)
    }

    @Test func skipsComplexLinesWithoutTouchingThem() throws {
        let content = """
        export GOOD="1"
        export BAD=a b
        export  Multi="3"
        """
        let plan = try AdoptionScanner.plan(fileContent: content, currentEntries: [])
        #expect(plan.adoptedKeys == ["GOOD", "Multi"])
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.line == #"export BAD=a b"#)
        #expect(plan.outsideEdits.count == 2)
    }

    @Test func collidesWithExistingManagedRecordUpdateValueNotDuplicate() throws {
        // 已有工具管理的 A 记录；文件块外又手写了一条 A（后写覆盖）→ 更新记录值并注释，不产生重复记录
        let existing: [ManagedEntry] = [
            .record(VariableRecord(key: "A", rawValue: "old", source: .toolCreated)),
        ]
        let content = MarkerBlock.generate(entries: existing) + "\n\nexport A=\"newer\"\n"
        let plan = try AdoptionScanner.plan(fileContent: content, currentEntries: existing)
        #expect(plan.adoptedKeys.isEmpty)
        let records = plan.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        #expect(records.map(\.key) == ["A"])
        #expect(records.first?.rawValue == "newer")
    }

    @Test func withExistingBlockAppendsAdoptedAndMovesPathToEnd() throws {
        let existing: [ManagedEntry] = [
            .record(VariableRecord(key: "A", rawValue: "1", source: .toolCreated)),
            .record(VariableRecord(key: "PATH", rawValue: "$PATH", source: .toolCreated)),
        ]
        let block = MarkerBlock.generate(entries: existing)
        let content = "export J=\"$A/jre\"\n" + block + "\n\n# 后加的\nexport K=\"2\"\n"
        let plan = try AdoptionScanner.plan(fileContent: content, currentEntries: existing)

        let records = plan.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        // 收编记录追加在尾部；PATH 记录（块内已有）移动到收编记录之后，保证 $J 引用先声明
        #expect(records.map(\.key) == ["A", "J", "K", "PATH"])
        #expect(records.first { $0.key == "J" }?.source == .adopted)
        #expect(records.first { $0.key == "A" }?.source == .toolCreated)
        #expect(records.last?.rawValue == "$PATH")
        #expect(plan.mergedPathLineCount == 0)
        #expect(plan.outsideEdits.count == 2)
    }

    @Test func mergesOutsidePathLineIntoExistingPathRecord() throws {
        let existing: [ManagedEntry] = [
            .record(VariableRecord(key: "PATH", rawValue: "$HOME/bin:$PATH", source: .toolCreated)),
        ]
        let block = MarkerBlock.generate(entries: existing)
        let content = block + "\n\nexport PATH=\"/usr/local/extra:$PATH\"\n"
        let plan = try AdoptionScanner.plan(fileContent: content, currentEntries: existing)
        let records = plan.entries.compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }
        #expect(records.count == 1)
        // 块内 PATH 在文件里的位置（块首）早于块外行 → 块外行后写、前插
        #expect(records.first?.rawValue == "/usr/local/extra:$HOME/bin:$PATH")
        #expect(plan.mergedPathLineCount == 1)
    }

    @Test func secondAdoptionFindsNothing() throws {
        let first = try AdoptionScanner.plan(fileContent: Fixtures.adoptionFile, currentEntries: [])
        var content = Fixtures.adoptionFile
        for edit in first.outsideEdits {
            content = FileText(content).replacingLine(at: edit.lineIndex, with: edit.replacementLine)
        }
        content = MarkerBlock.append(original: content, newBlock: MarkerBlock.generate(entries: first.entries))

        let second = try AdoptionScanner.plan(fileContent: content, currentEntries: first.entries)
        #expect(second.adoptedKeys.isEmpty)
        #expect(second.outsideEdits.isEmpty)
        #expect(second.mergedPathLineCount == 0)
        #expect(second.entries == first.entries)
    }
}
