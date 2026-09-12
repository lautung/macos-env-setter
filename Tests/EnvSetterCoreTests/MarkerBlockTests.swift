import Testing
@testable import EnvSetterCore

struct MarkerBlockTests {
    private let entries: [ManagedEntry] = [
        .record(VariableRecord(key: "TOOLS", rawValue: "/opt/tools", source: .adopted)),
        .record(VariableRecord(key: "JAVA_HOME", rawValue: "$TOOLS/jdk", source: .adopted)),
        .verbatim(line: "# 用户手写的注释"),
        .record(VariableRecord(key: "PATH", rawValue: "$HOME/bin:$PATH", source: .adopted)),
    ]

    @Test func locateFindsBlockAndRoundTripsInner() throws {
        let content = "before\n" + FixturesForBlock.block(for: entries) + "\nafter\n"
        let location = try MarkerBlock.locate(in: content)
        #expect(location != nil)
        let parsed = MarkerBlock.parse(innerContent: location!.innerContent)
        #expect(parsed == entries)
        #expect(location!.fullText == FixturesForBlock.block(for: entries))
    }

    @Test func locateReturnsNilWithoutBlock() throws {
        #expect(try MarkerBlock.locate(in: "export A=1\n") == nil)
        #expect(try MarkerBlock.locate(in: "") == nil)
    }

    @Test func locateThrowsOnMalformedMarkers() throws {
        #expect(throws: EngineError.malformedMarkerBlock.self) {
            _ = try MarkerBlock.locate(in: "\(MarkerBlock.beginMarker)\nno end\n")
        }
        #expect(throws: EngineError.malformedMarkerBlock.self) {
            _ = try MarkerBlock.locate(
                in: "\(MarkerBlock.beginMarker)\n\(MarkerBlock.beginMarker)\n\(MarkerBlock.endMarker)\n"
            )
        }
    }

    @Test func generateIncludesTemplateLines() {
        let block = MarkerBlock.generate(entries: [])
        let lines = block.split(separator: "\n").map(String.init)
        #expect(lines.first == MarkerBlock.beginMarker)
        #expect(lines.last == MarkerBlock.endMarker)
        #expect(lines.contains(MarkerBlock.typesetLine))
        #expect(lines.contains(MarkerBlock.headerComment))
    }

    @Test func parseSkipsTemplateLinesButKeepsUserComments() {
        let inner = """
        \(MarkerBlock.headerComment)
        \(MarkerBlock.typesetLine)
        # 我自己的注释
        export A="1"
        乱写的行 -> keep
        """
        let parsed = MarkerBlock.parse(innerContent: inner)
        #expect(
            parsed == [
                .verbatim(line: "# 我自己的注释"),
                .record(VariableRecord(key: "A", rawValue: "1", shellEnabled: true, guiEnabled: false, source: .adopted)),
                .verbatim(line: "乱写的行 -> keep"),
            ]
        )
    }

    @Test func spliceKeepsOutsideBytesIntact() throws {
        let block = FixturesForBlock.block(for: entries)
        let content = "HEAD\n\n" + block + "\n\nTAIL\n"
        let location = try MarkerBlock.locate(in: content)!

        let replacement = MarkerBlock.generate(entries: [.record(VariableRecord(key: "X", rawValue: "1"))])
        let spliced = MarkerBlock.splice(original: content, location: location, newBlock: replacement)

        #expect(spliced.hasPrefix("HEAD\n\n"))
        #expect(spliced.hasSuffix("\n\nTAIL\n"))
        #expect(spliced.contains(replacement))
        #expect(!spliced.contains("TOOLS")) // 旧记录整块消失
    }

    @Test func splicePreservesEmptyLinesInsideBlockRegion() throws {
        // 块内含空行：解析为 verbatim（空行原样保留），写回不丢
        let entries: [ManagedEntry] = [
            .verbatim(line: ""),
            .record(VariableRecord(key: "A", rawValue: "1", shellEnabled: true, guiEnabled: false, source: .adopted)),
            .verbatim(line: ""),
        ]
        let block = MarkerBlock.generate(entries: entries)
        let location = try MarkerBlock.locate(in: block)!
        let parsed = MarkerBlock.parse(innerContent: location.innerContent)
        #expect(parsed == entries)
        #expect(MarkerBlock.generate(entries: parsed) == block)
    }

    @Test func appendHandlesMissingTrailingNewlineAndEmptyFile() {
        #expect(MarkerBlock.append(original: "", newBlock: "B") == "B\n")
        #expect(MarkerBlock.append(original: "a\n", newBlock: "B") == "a\nB\n")
        #expect(MarkerBlock.append(original: "a", newBlock: "B") == "a\nB\n")
    }

    @Test func generateParseIdempotenceAcrossManyValues() {
        let values = [
            "", "plain", "$REF/${REF2:-x}", #"q"uote"\`"#, "a#b", "$PATH:/opt/bin",
        ]
        for value in values {
            let line = ShellLine.exportLine(key: "KEY", rawValue: value)
            #expect(ShellLine.parseExportLine(line)?.rawValue == value)
        }
    }
}

/// 块文本构造助手
enum FixturesForBlock {
    static func block(for entries: [ManagedEntry]) -> String {
        MarkerBlock.generate(entries: entries)
    }
}
