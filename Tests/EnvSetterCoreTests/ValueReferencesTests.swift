import Testing
@testable import EnvSetterCore

struct ValueReferencesTests {
    @Test func scansBareAndBracedReferences() {
        let references = ValueReferences.scan(#"$JAVA_HOME/bin:${PATH}"#, quoteStyle: .double)
        #expect(references == [
            ValueReference(name: "JAVA_HOME", text: "$JAVA_HOME", isPlain: true),
            ValueReference(name: "PATH", text: "${PATH}", isPlain: true),
        ])
    }

    @Test func skipsFormsWithoutAVariableName() {
        for raw in ["$$", "$1", "$?", "$@", "$(date)", "${#A}", "${1}", "$"] {
            #expect(ValueReferences.scan(raw, quoteStyle: .double).isEmpty, "raw: \(raw)")
        }
        // 特殊参数是 `$` 加一个字符：`$$A` 里的 `A` 是字面量，不是引用
        #expect(ValueReferences.scan("$$A", quoteStyle: .double).isEmpty)
        #expect(ValueReferences.scan("$1FOO", quoteStyle: .double).isEmpty)
        // 命令替换里的引用照常扫出来（它在脚本里也照常展开）
        #expect(ValueReferences.scan("$(dirname $A)", quoteStyle: .double).map(\.name) == ["A"])
    }

    /// 原始值里没有「转义掉 `$`」的写法：写回时 `\` 会被转义成 `\\`（`ShellLine.quotedValue`），
    /// 所以 `\$A` 里的 `$A` 照样是引用。
    @Test func backslashDoesNotEscapeReferencesInRawValues() {
        #expect(ValueReferences.scan(#"\$A"#, quoteStyle: .double).map(\.name) == ["A"])
    }

    @Test func singleQuotedValuesHaveNoReferences() {
        #expect(ValueReferences.scan("$JAVA_HOME/bin", quoteStyle: .single).isEmpty)
        // 一个引用也没有，也就没有「按空展开」这回事：值原样
        #expect(
            ValueReferences.rendering("$JAVA_HOME/bin", quoteStyle: .single, emptying: "JAVA_HOME")
                == "$JAVA_HOME/bin"
        )
    }

    @Test func bracedFormsCarryTheirWholeTextAndTheirFallbackFlag() {
        let references = ValueReferences.scan("${JAVA_HOME:-/opt/jdk}/bin", quoteStyle: .double)
        #expect(references.map(\.name) == ["JAVA_HOME"])
        #expect(references.map(\.text) == ["${JAVA_HOME:-/opt/jdk}"])
        // 自带兜底的写法：变量没有值时展开成默认值，不是空
        #expect(references.map(\.isPlain) == [false])
    }

    /// 大括号里的内容也要接着扫：`${A:-$B}` 里的 `$B` 同样是一处引用。
    @Test func scansInsideBracedFallbacks() {
        let references = ValueReferences.scan("${JAVA_HOME:-$DEFAULT_JDK}/bin", quoteStyle: .double)
        #expect(references.map(\.name) == ["JAVA_HOME", "DEFAULT_JDK"])
        #expect(references.map(\.isPlain) == [false, true])
    }

    @Test func renderingEmptiesPlainReferences() {
        #expect(ValueReferences.rendering("$JAVA_HOME/bin", quoteStyle: .double, emptying: "JAVA_HOME") == "/bin")
        #expect(ValueReferences.rendering("/a:$PATH", quoteStyle: .double, emptying: "PATH") == "/a:")
        #expect(ValueReferences.rendering("${A}:$B", quoteStyle: .double, emptying: "A") == ":$B")
        // 出现多次就都按空展开
        #expect(ValueReferences.rendering("$A/x:$A/y", quoteStyle: .double, emptying: "A") == "/x:/y")
        // 没引用到这个变量就原样返回
        #expect(ValueReferences.rendering("$B/bin", quoteStyle: .double, emptying: "A") == "$B/bin")
    }

    /// 自带兜底的写法展开成什么取决于写法本身，界面不该给出一个确定的预览。
    @Test func renderingRefusesToGuessFallbackForms() {
        #expect(ValueReferences.rendering("${JAVA_HOME:-/opt/jdk}/bin", quoteStyle: .double, emptying: "JAVA_HOME") == nil)
        #expect(ValueReferences.rendering(#"-rlogger${RUBYOPT:+ $RUBYOPT}"#, quoteStyle: .double, emptying: "RUBYOPT") == nil)
        // 同一个变量既有朴素写法又有兜底写法：一样不给预览
        #expect(ValueReferences.rendering("$A:${A:-x}", quoteStyle: .double, emptying: "A") == nil)
    }

    @Test func renderingMatchesTheAdoptedPathFixture() {
        let raw = "$TOOLS/bin:/Users/tester/development/flutter/bin:$JAVA_HOME/bin:$PATH"
        #expect(
            ValueReferences.rendering(raw, quoteStyle: .double, emptying: "TOOLS")
                == "/bin:/Users/tester/development/flutter/bin:$JAVA_HOME/bin:$PATH"
        )
    }
}
