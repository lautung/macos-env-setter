import Testing
@testable import EnvSetterCore

struct ShellLineTests {
    @Test func parsesUnquotedValue() {
        let parsed = ShellLine.parseExportLine("export FOO=bar")
        #expect(parsed == ParsedExport(key: "FOO", rawValue: "bar", quoteStyle: .double))
    }

    @Test func parsesIndentedAndTabbed() {
        #expect(ShellLine.parseExportLine("  \t export FOO=bar")?.key == "FOO")
        #expect(ShellLine.parseExportLine("export\tFOO=bar")?.key == "FOO")
    }

    @Test func parsesEmptyValue() {
        #expect(ShellLine.parseExportLine("export EMPTY=") == ParsedExport(key: "EMPTY", rawValue: "", quoteStyle: .double))
    }

    @Test func parsesDoubleQuotedKeepingDollarRefs() {
        let parsed = ShellLine.parseExportLine(#"export JAVA_HOME="$CODEX_DEV_TOOLS/jdk""#)
        #expect(parsed == ParsedExport(key: "JAVA_HOME", rawValue: "$CODEX_DEV_TOOLS/jdk", quoteStyle: .double))
    }

    @Test func parsesSelfReferenceAndBraces() {
        let parsed = ShellLine.parseExportLine(#"export RUBYOPT="-rlogger${RUBYOPT:+ $RUBYOPT}""#)
        #expect(parsed?.rawValue == #"-rlogger${RUBYOPT:+ $RUBYOPT}"#)
    }

    @Test func parsesEscapedQuoteAndBackslash() {
        #expect(ShellLine.parseExportLine(#"export A="a\"b\\c""#)?.rawValue == #"a"b\c"#)
        #expect(ShellLine.parseExportLine(#"export A="cost\$5""#)?.rawValue == "cost$5")
        // zsh 双引号里未知转义保留反斜杠
        #expect(ShellLine.parseExportLine(#"export A="a\qb""#)?.rawValue == #"a\qb"#)
    }

    @Test func parsesSingleQuotedLiterally() {
        let parsed = ShellLine.parseExportLine(#"export A='a\"b\c'"#)
        #expect(parsed?.rawValue == #"a\"b\c"#)
        #expect(parsed?.quoteStyle == .single)
    }

    @Test func singleQuotedLiteralDollarSurvivesRoundTrip() {
        let line = #"export PASS='pa$$word'"#
        let parsed = ShellLine.parseExportLine(line)
        #expect(parsed?.quoteStyle == .single)
        // 原样往返：单引号值重新导出后与原文逐字节一致，`$$` 不会被展开。
        #expect(ShellLine.exportLine(key: "PASS", rawValue: parsed!.rawValue, quoteStyle: .single) == line)
    }

    @Test func allowsTrailingComment() {
        #expect(ShellLine.parseExportLine(#"export A="v" # note"#)?.rawValue == "v")
        #expect(ShellLine.parseExportLine("export A=v # note")?.rawValue == "v")
    }

    @Test func rejectsNonExportAndComplexLines() {
        #expect(ShellLine.parseExportLine("FOO=bar") == nil)
        #expect(ShellLine.parseExportLine("# export FOO=bar") == nil)
        #expect(ShellLine.parseExportLine("exports FOO=bar") == nil)
        #expect(ShellLine.parseExportLine("export") == nil)
        #expect(ShellLine.parseExportLine("export FOO") == nil)
        #expect(ShellLine.parseExportLine("export FOO =bar") == nil)
        #expect(ShellLine.parseExportLine("export A=1 B=2") == nil)
        #expect(ShellLine.parseExportLine("export A=a b") == nil)
        #expect(ShellLine.parseExportLine(#"export A="unterminated"#) == nil)
        #expect(ShellLine.parseExportLine("export 2BAD=x") == nil)
        #expect(ShellLine.parseExportLine("export A=\"v\" trailing") == nil)
    }

    @Test func roundTripsTrickyValues() {
        let values = [
            "",
            "plain",
            "$REF/dir",
            "${REF:+ x}",
            #"has "quote" and \backslash"#,
            "`backtick`",
            "a#b",
            "$HOME:$PATH",
        ]
        for value in values {
            let line = ShellLine.exportLine(key: "KEY", rawValue: value)
            #expect(line.hasPrefix("export KEY=\""))
            #expect(ShellLine.parseExportLine(line)?.rawValue == value)
        }
    }

    @Test func quotingEscapesOnlyWhatDoubleQuotesNeed() {
        #expect(ShellLine.quotedValue("$PATH") == "\"$PATH\"")
        #expect(ShellLine.quotedValue(#"a"b"#) == #""a\"b""#)
        #expect(ShellLine.quotedValue(#"a\b"#) == #""a\\b""#)
        #expect(ShellLine.quotedValue("a`b") == #""a\`b""#)
    }

    @Test func simpleKeyValidation() {
        #expect(ShellLine.isSimpleKey("PATH"))
        #expect(ShellLine.isSimpleKey("_PRIVATE"))
        #expect(ShellLine.isSimpleKey("A1"))
        #expect(!ShellLine.isSimpleKey("1A"))
        #expect(!ShellLine.isSimpleKey("A-B"))
        #expect(!ShellLine.isSimpleKey(""))
    }
}
