import Testing
@testable import EnvSetterCore

struct PathListTests {
    @Test func splitsAnchorsAndEmptySegments() {
        #expect(
            PathList.entries(fromRawValue: "a:$PATH:b")
                == [.literal("a"), .anchor, .literal("b")]
        )
        #expect(
            PathList.entries(fromRawValue: "${PATH}:a")
                == [.anchor, .literal("a")]
        )
        // 空段 = 当前目录语义，必须保留
        #expect(
            PathList.entries(fromRawValue: "a::b")
                == [.literal("a"), .literal(""), .literal("b")]
        )
    }

    @Test func joinRoundTrip() {
        let raw = "/opt/bin:$PATH:/usr/local/bin:"
        #expect(PathList.rawValue(from: PathList.entries(fromRawValue: raw)) == raw)
    }

    @Test func composeMatchesUserFilePattern() {
        // 真实文件形态：第一条 PATH 前插多个目录，第二条再前插 opencode。
        let line1 = "$TOOLS/bin:/Users/t/flutter/bin:$SDK_HOME/platform-tools:$JAVA_HOME/bin:$PATH"
        let line2 = "/Users/t/.opencode/bin:$PATH"
        #expect(
            PathList.composeRawValues([line1, line2])
                == "/Users/t/.opencode/bin:$TOOLS/bin:/Users/t/flutter/bin:$SDK_HOME/platform-tools:$JAVA_HOME/bin:$PATH"
        )
    }

    @Test func composeCollapsesRepeatedAnchors() {
        #expect(PathList.composeRawValues(["a:$PATH", "b:$PATH"]) == "b:a:$PATH")
        #expect(PathList.composeRawValues(["a:$PATH", "$PATH:b"]) == "a:$PATH:b")
    }

    @Test func composeHandlesAppends() {
        // 前插再后插：结果 = e + 基底 + a
        #expect(PathList.composeRawValues(["e:$PATH", "$PATH:a"]) == "e:$PATH:a")
        // 后插再前插：前插的始终在最前
        #expect(PathList.composeRawValues(["$PATH:a", "e:$PATH"]) == "e:$PATH:a")
    }

    @Test func composeHandlesFullReplacement() {
        #expect(PathList.composeRawValues(["a:$PATH", "/only/this"]) == "/only/this")
        // 替换之后的前插/后插以替换内容为基底
        #expect(PathList.composeRawValues(["a:$PATH", "/only", "e:$PATH", "$PATH:x"]) == "e:/only:x")
    }

    @Test func composeIsSemanticallyEqualToSequentialEvaluation() {
        let bases = ["/usr/bin:/bin", "/usr/bin:/bin:/usr/sbin:/sbin"]
        let cases: [[String]] = [
            ["a:$PATH"],
            ["a:$PATH", "b:$PATH"],
            ["a:$PATH", "$PATH:b"],
            ["$PATH:a", "b:$PATH"],
            ["$PATH:a", "$PATH:b", "c:$PATH"],
            ["a:$PATH", "/only", "$PATH:x"],
            ["$PATH:"], // 空前插（保留空段语义）
        ]
        func expanded(_ raw: String, base: String) -> String {
            PathList.entries(fromRawValue: raw).map { entry in
                if case .anchor = entry { return base }
                return entry.rawText
            }.joined(separator: ":")
        }
        for base in bases {
            for lines in cases {
                let composed = expanded(PathList.composeRawValues(lines), base: base)
                let sequential = TestSupport.evaluatePathSequentially(lines: lines, base: base)
                #expect(composed == sequential, "lines: \(lines), base: \(base)")
            }
        }
    }

    @Test func hasAnchorDetection() {
        #expect(PathList.hasAnchor("$PATH:a"))
        #expect(PathList.hasAnchor("a:${PATH}"))
        #expect(!PathList.hasAnchor("a:b"))
        #expect(!PathList.hasAnchor("literal$PATHx")) // 非独立段不算锚点
    }
}
