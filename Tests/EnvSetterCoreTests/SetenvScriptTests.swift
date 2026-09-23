import Testing
import Foundation
@testable import EnvSetterCore

/// `setenv.sh` 的生成与解析，以及用真实 `/bin/sh` 验证展开语义。
struct SetenvScriptTests {
    private func record(
        _ key: String,
        _ value: String,
        gui: Bool = true,
        quote: QuoteStyle = .double
    ) -> ManagedEntry {
        .record(
            VariableRecord(
                key: key,
                rawValue: value,
                shellEnabled: true,
                guiEnabled: gui,
                quoteStyle: quote
            )
        )
    }

    private func index(of needle: String, in text: String) throws -> Int {
        let range = try #require(text.range(of: needle), "脚本里找不到：\(needle)")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    @Test func generatesAssignmentsThenInjectionsInDeclarationOrder() throws {
        let entries: [ManagedEntry] = [
            record("TOOLS", "/opt/tools"),
            record("JAVA_HOME", "$TOOLS/jdk/jdk-21/Contents/Home"),
            record("SHELL_ONLY", "terminal-only", gui: false),
            .verbatim(line: "export HAND_WRITTEN=\"$(date)\""),
        ]
        let script = SetenvScript.generate(entries: entries, label: "com.example.test")

        #expect(SetenvScript.enabledKeys(entries: entries) == ["TOOLS", "JAVA_HOME"])
        // GUI 层只管 guiEnabled 的记录：shell 专属变量与逐字保留行都不进脚本
        #expect(!script.contains("SHELL_ONLY"))
        #expect(!script.contains("HAND_WRITTEN"))

        // 先赋值（$ 引用在这一步展开），再逐条 setenv 取赋值结果
        #expect(script.contains(#"TOOLS="/opt/tools""#))
        #expect(script.contains(#"JAVA_HOME="$TOOLS/jdk/jdk-21/Contents/Home""#))
        #expect(script.contains(#"/bin/launchctl setenv TOOLS "$TOOLS""#))
        #expect(script.contains(#"/bin/launchctl setenv JAVA_HOME "$JAVA_HOME""#))
        #expect(try index(of: "TOOLS=\"/opt/tools\"", in: script) < index(of: "JAVA_HOME=\"", in: script))
        #expect(
            try index(of: "/bin/launchctl setenv TOOLS", in: script)
                < index(of: "/bin/launchctl setenv JAVA_HOME", in: script)
        )
        // --print 分支在真正的注入之前，且带 exit
        #expect(try index(of: SetenvScript.printFlag, in: script) < index(of: "/bin/launchctl setenv", in: script))
        #expect(script.contains("#!/bin/sh"))
        #expect(script.contains("com.example.test"))
    }

    @Test func emptyRecordSetStillGeneratesValidScript() throws {
        let script = SetenvScript.generate(entries: [])
        #expect(script.contains(SetenvScript.emptyNote))
        #expect(script.contains("exit 0"))
        #expect(!script.contains("/bin/launchctl setenv"))
        #expect(SetenvScript.enabledKeys(entries: []) == [])
        #expect(SetenvScript.appliedKeys(in: script) == [])
    }

    @Test func singleQuotedValueStaysLiteral() throws {
        let script = SetenvScript.generate(entries: [record("TOKEN", "pa$$word", quote: .single)])
        #expect(script.contains(#"TOKEN='pa$$word'"#))
        #expect(script.contains(#"/bin/launchctl setenv TOKEN "$TOKEN""#))
    }

    @Test func appliedKeysRoundTripsAndIgnoresForeignContent() throws {
        let entries: [ManagedEntry] = [
            record("A", "1"), record("B", "2"), record("C", "3", gui: false),
        ]
        let script = SetenvScript.generate(entries: entries)
        #expect(SetenvScript.appliedKeys(in: script) == ["A", "B"])

        // 只认本工具写出的格式（绝对路径 + 参数形状）；其它形态一律不算
        let foreign = """
        #!/bin/sh
        launchctl setenv A 1
        /bin/launchctl setenv 1BAD 2
        /bin/launchctl setenv A 1
        /bin/launchctl unsetenv A
        """
        #expect(SetenvScript.appliedKeys(in: foreign) == ["A"])
        #expect(SetenvScript.appliedKeys(in: "") == [])
    }

    @Test func parsePrintedValuesTakesFirstEqualsAndSkipsJunk() throws {
        let parsed = SetenvScript.parsePrintedValues(
            """
            JAVA_HOME=/opt/tools/jdk
            WITH_EQUALS=a=b=c
            WITH_SPACE=hello world
            (invalid line)
            1BAD=x
            EMPTY=
            """
        )
        #expect(parsed["JAVA_HOME"] == "/opt/tools/jdk")
        #expect(parsed["WITH_EQUALS"] == "a=b=c")
        #expect(parsed["WITH_SPACE"] == "hello world")
        #expect(parsed["EMPTY"] == "")
        #expect(parsed["1BAD"] == nil)
        #expect(parsed.count == 4)
    }

    // MARK: - 真实 /bin/sh 验证

    /// 跑脚本的 `--print` 分支（不调用 launchctl），拿展开后的值。
    private func printedValues(script: String, home: URL, path: String = LaunchAgent.defaultPath) throws -> [String: String] {
        let scriptURL = home.appending(path: "setenv-print-test.sh")
        try TestSupport.write(script, to: scriptURL)
        let outcome = SystemProcessRunner().run(
            executable: "/bin/sh",
            arguments: [scriptURL.path, SetenvScript.printFlag],
            environment: ["HOME": home.path, "PATH": path]
        )
        #expect(outcome.succeeded, "\(outcome.message)")
        return SetenvScript.parsePrintedValues(outcome.stdout)
    }

    /// 把 launchctl 换成 /bin/echo 跑脚本：观察注入阶段的真实参数（不碰真 launchd）。
    private func injectedArguments(script: String, home: URL, path: String) throws -> [String] {
        let probe = script.replacingOccurrences(of: LaunchAgent.launchctlPath, with: "/bin/echo")
        let probeURL = home.appending(path: "setenv-inject-test.sh")
        try TestSupport.write(probe, to: probeURL)
        let outcome = SystemProcessRunner().run(
            executable: "/bin/sh",
            arguments: [probeURL.path],
            environment: ["HOME": home.path, "PATH": path]
        )
        #expect(outcome.succeeded, "\(outcome.message)")
        return outcome.stdout.split(separator: "\n").map(String.init)
    }

    @Test func realShellExpandsReferencesInDeclarationOrder() throws {
        let (home, _) = try TestSupport.makeSandbox()
        let script = SetenvScript.generate(entries: [
            record("TOOLS", "/opt/tools"),
            record("JAVA_HOME", "$TOOLS/jdk/jdk-21/Contents/Home"),
            record("MAVEN_HOME", "$TOOLS/maven/apache-maven-3"),
            record("BRACED", "${TOOLS}/bin"),
            record("LITERAL", "pa$$word", quote: .single),
            record("SELF", "-rlogger${SELF:+ $SELF}"),
            record("WITH_SPACE", "hello world"),
            record("WITH_QUOTE", "say \"hi\""),
        ])
        let values = try printedValues(script: script, home: home)

        #expect(values["TOOLS"] == "/opt/tools")
        #expect(values["JAVA_HOME"] == "/opt/tools/jdk/jdk-21/Contents/Home")
        #expect(values["MAVEN_HOME"] == "/opt/tools/maven/apache-maven-3")
        #expect(values["BRACED"] == "/opt/tools/bin")
        // 单引号 = 字面量：`$` 不展开
        #expect(values["LITERAL"] == "pa$$word")
        // 自引用：GUI 层没有既存值，`${SELF:+ …}` 展开为空
        #expect(values["SELF"] == "-rlogger")
        #expect(values["WITH_SPACE"] == "hello world")
        #expect(values["WITH_QUOTE"] == #"say "hi""#)

        // 注入阶段拿到的是同一批展开值（顺序一致）
        let injected = try injectedArguments(script: script, home: home, path: LaunchAgent.defaultPath)
        #expect(
            injected == [
                "setenv TOOLS /opt/tools",
                "setenv JAVA_HOME /opt/tools/jdk/jdk-21/Contents/Home",
                "setenv MAVEN_HOME /opt/tools/maven/apache-maven-3",
                "setenv BRACED /opt/tools/bin",
                "setenv LITERAL pa$$word",
                "setenv SELF -rlogger",
                "setenv WITH_SPACE hello world",
                #"setenv WITH_QUOTE say "hi""#,
            ]
        )
    }

    /// 引用警告说的「这一段会展开成空」必须对得上真实 /bin/sh：
    /// 被引用的记录没进脚本（没开 GUI 开关）、或排在后面时，`ValueReferences.rendering` 给出的预览
    /// 就是脚本里实际算出来的值。
    @Test func guiReferencePreviewMatchesWhatTheScriptComputes() throws {
        let (home, _) = try TestSupport.makeSandbox()
        let entries: [ManagedEntry] = [
            record("TOOLS", "/opt/tools", gui: false), // 没开 GUI 开关：不进脚本
            record("AFTER", "$LATE/bin"), // 引用的变量排在后面：赋值时还没有值
            record("LATE", "/opt/late"),
            record("JAVA_HOME", "$TOOLS/jdk"), // 引用的变量在脚本里没有赋值
        ]
        let values = try printedValues(script: SetenvScript.generate(entries: entries), home: home)

        let emptied = try #require(
            ValueReferences.rendering("$TOOLS/jdk", quoteStyle: .double, emptying: "TOOLS")
        )
        #expect(values["JAVA_HOME"] == emptied)
        #expect(emptied == "/jdk")
        #expect(values["AFTER"] == "/bin")
    }

    @Test func pathAnchorResolvesToTheShellInheritedPath() throws {
        let (home, _) = try TestSupport.makeSandbox()
        // 声明顺序决定 `$引用` 能否展开：TOOLS 必须排在引用它的 PATH 之前（两层同理）。
        let entries: [ManagedEntry] = [
            record("TOOLS", "/opt/tools"),
            .record(
                VariableRecord(
                    key: "PATH",
                    rawValue: PathList.composeRawValues(["/opt/bin:$TOOLS/bin:$PATH"]),
                    shellEnabled: true,
                    guiEnabled: true
                )
            ),
        ]
        let script = SetenvScript.generate(entries: entries)
        let values = try printedValues(script: script, home: home, path: LaunchAgent.defaultPath)

        // 锚点展开成脚本继承到的 PATH（agent 场景下即 launchd 的默认 PATH），不是终端里的 PATH
        #expect(values["PATH"] == "/opt/bin:/opt/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
