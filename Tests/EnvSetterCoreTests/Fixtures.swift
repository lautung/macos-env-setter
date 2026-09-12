import Foundation
@testable import EnvSetterCore

/// 与真实 ~/.zprofile 同构的合成夹具：8 条 export、变量互引用、自引用、两条 PATH 行、注释与空行。
enum Fixtures {
    static let adoptionFile = """
    export TOOLS="/Users/tester/development/tools"
    export JAVA_HOME="$TOOLS/jdk/jdk-21/Contents/Home"
    export MAVEN_HOME="$TOOLS/maven/apache-maven-3"
    export SDK_HOME="/Users/tester/Library/Android/sdk"
    export SDK_ROOT="$SDK_HOME"
    export RUBYOPT="-rlogger${RUBYOPT:+ $RUBYOPT}"
    export PATH="$TOOLS/bin:/Users/tester/development/flutter/bin:$SDK_HOME/platform-tools:$JAVA_HOME/bin:$PATH"

    # OpenCode CLI
    export PATH="/Users/tester/.opencode/bin:$PATH"
    """

    static let expectedMergedPath =
        "/Users/tester/.opencode/bin:$TOOLS/bin:/Users/tester/development/flutter/bin:$SDK_HOME/platform-tools:$JAVA_HOME/bin:$PATH"

    static let nonPathKeys = [
        "TOOLS", "JAVA_HOME", "MAVEN_HOME", "SDK_HOME", "SDK_ROOT", "RUBYOPT",
    ]
}

enum TestSupport {
    static func makeSandbox() throws -> (home: URL, paths: EnginePaths) {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "envsetter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = EnginePaths.sandboxed(home: home)
        return (home, paths)
    }

    @discardableResult
    static func write(_ content: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// 逐行模拟 zsh 对若干条 PATH 赋值行的求值，用于验证 compose 的语义保持。
    /// 前插/后插段按数组判断是否为空（保留空段 = 当前目录语义），不是按拼接后的字符串判断。
    static func evaluatePathSequentially(lines: [String], base: String) -> String {
        var current = base
        for line in lines {
            let entries = PathList.entries(fromRawValue: line)
            guard let anchorIndex = entries.firstIndex(where: { entry in
                if case .anchor = entry { return true }
                return false
            }) else {
                current = PathList.rawValue(from: entries) // 无锚点 = 整条替换
                continue
            }
            let pre = Array(entries[..<anchorIndex])
            let post = Array(entries[entries.index(after: anchorIndex)...])
            var parts: [String] = []
            if !pre.isEmpty { parts.append(pre.map(\.rawText).joined(separator: ":")) }
            parts.append(current)
            if !post.isEmpty { parts.append(post.map(\.rawText).joined(separator: ":")) }
            current = parts.joined(separator: ":")
        }
        return current
    }
}
