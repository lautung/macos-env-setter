import Testing
import Foundation
@testable import EnvSetterCore

/// 端到端：真实 zsh 登录 shell 求值。收编前后 `env -i HOME=沙盒 zsh -l -c env` 输出必须语义一致。
struct ZshIntegrationTests {
    @available(macOS 13.0, *)
    private func runLoginEnv(home: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "env"]
        process.environment = [
            "HOME": home.path,
            "TERM": "xterm-256color",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(stderrText)")
        return String(decoding: data, as: UTF8.self)
    }

    private func sortedEnv(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("_=") } // zsh 自己注入的 _ 随命令路径变化
            .sorted()
    }

    @Test func adoptedProfileProducesIdenticalLoginEnv() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)

        let before = sortedEnv(try runLoginEnv(home: home))
        // 收编前应能看到夹具里的变量
        #expect(before.contains { $0.hasPrefix("JAVA_HOME=") })
        #expect(before.contains { $0.hasPrefix("RUBYOPT=") })

        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        let after = sortedEnv(try runLoginEnv(home: home))
        #expect(after == before, """
        收编前后登录环境不一致。
        -- 仅收编前有：
        \(Set(before).subtracting(after).sorted().joined(separator: "\n"))
        -- 仅收编后有：
        \(Set(after).subtracting(before).sorted().joined(separator: "\n"))
        """)
    }

    @Test func singleQuotedLiteralDollarKeepsLoginEnvIdentical() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        // 单引号里的 `$$` 是字面量；若被改写成双引号会展开成 PID——验收语义一致性必须抓住这一点。
        let content = """
        export SECRET_TOKEN='pa$$word'
        export GREETING="hello $USER"
        """
        try TestSupport.write(content, to: paths.zprofileURL)

        let before = sortedEnv(try runLoginEnv(home: home))

        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        let after = sortedEnv(try runLoginEnv(home: home))
        let delta = Set(before).symmetricDifference(after).sorted().joined(separator: "\n")
        #expect(after == before, "收编前后登录环境不一致：\n\(delta)")

        // 单引号值在块内保持单引号原样
        let written = try TestSupport.read(paths.zprofileURL)
        #expect(written.contains(#"export SECRET_TOKEN='pa$$word'"#))
    }

    @Test func driftReloadKeepsLoginEnvConsistentWithFile() throws {
        let (home, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(Fixtures.adoptionFile, to: paths.zprofileURL)
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)

        // 用户手工在块内新增一条变量 → 漂移 → 文件为准
        let content = try TestSupport.read(paths.zprofileURL)
        let edited = content.replacingOccurrences(
            of: MarkerBlock.endMarker,
            with: "export HAND_ADDED=\"yes\"\n\(MarkerBlock.endMarker)"
        )
        try TestSupport.write(edited, to: paths.zprofileURL)
        let result = try engine.load()
        #expect(result.driftDetected)
        #expect(
            result.entries.contains { entry in
                if case .record(let record) = entry { return record.key == "HAND_ADDED" }
                return false
            }
        )

        let after = sortedEnv(try runLoginEnv(home: home))
        #expect(after.contains { $0 == "HAND_ADDED=yes" })
    }
}
