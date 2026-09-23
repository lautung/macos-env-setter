import Testing
import Foundation
@testable import EnvSetterCore

/// LaunchAgent plist 的生成与比对。
struct LaunchAgentTests {
    @Test func plistPinsPathAndCarriesLabelProgramArgumentsRunAtLoad() throws {
        let data = try LaunchAgent.plistData(label: "com.example.test", scriptPath: "/tmp/setenv.sh")
        let parsed = try #require(LaunchAgent.dictionary(from: data))
        #expect(parsed["Label"] as? String == "com.example.test")
        #expect(parsed["ProgramArguments"] as? [String] == ["/bin/sh", "/tmp/setenv.sh"])
        #expect(parsed["RunAtLoad"] as? Bool == true)
        #expect(parsed["EnvironmentVariables"] as? [String: String] == ["PATH": LaunchAgent.defaultPath])
    }

    @Test func plistComparisonIgnoresKeyOrderAndFormatting() throws {
        let expected = try LaunchAgent.plistData(label: "com.example.test", scriptPath: "/tmp/setenv.sh")

        // 同样内容、键序与缩进都不同的手写 plist
        let reordered = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>EnvironmentVariables</key><dict><key>PATH</key><string>\(LaunchAgent.defaultPath)</string></dict>
            <key>RunAtLoad</key><true/>
            <key>ProgramArguments</key>
            <array><string>/bin/sh</string><string>/tmp/setenv.sh</string></array>
            <key>Label</key><string>com.example.test</string>
        </dict>
        </plist>
        """
        #expect(
            LaunchAgent.plistMatches(
                existing: Data(reordered.utf8), label: "com.example.test", scriptPath: "/tmp/setenv.sh"
            )
        )

        // 脚本路径变了就不算一致（需要重写 plist）
        #expect(
            !LaunchAgent.plistMatches(
                existing: Data(reordered.utf8), label: "com.example.test", scriptPath: "/tmp/other.sh"
            )
        )
        #expect(
            !LaunchAgent.plistMatches(
                existing: Data("not a plist".utf8), label: "com.example.test", scriptPath: "/tmp/setenv.sh"
            )
        )
        #expect(LaunchAgent.label(inPlist: expected) == "com.example.test")
    }

    /// 没有 `EnvironmentVariables` 的旧 plist 不算当前内容——应用时会重写并重新注册。
    /// 钉住的是升级路径：钉 PATH 之前装下的 agent 必须被认出来、被换掉，否则它会一直用域里已有的 PATH 重跑。
    @Test func legacyPlistWithoutPinnedPathIsNotCurrent() throws {
        let legacy = Fixtures.legacyPlist(label: "com.example.test", scriptPath: "/tmp/setenv.sh")
        #expect(
            !LaunchAgent.plistMatches(
                existing: Data(legacy.utf8), label: "com.example.test", scriptPath: "/tmp/setenv.sh"
            )
        )
    }

    @Test func specialCharactersInPathSurviveRoundTrip() throws {
        let path = "/Users/tester/Library/Application Support/EnvSetter & Co/setenv.sh"
        let data = try LaunchAgent.plistData(label: "com.example.test", scriptPath: path)
        let parsed = try #require(LaunchAgent.dictionary(from: data))
        #expect(parsed["ProgramArguments"] as? [String] == ["/bin/sh", path])
        #expect(LaunchAgent.plistMatches(existing: data, label: "com.example.test", scriptPath: path))
    }
}
