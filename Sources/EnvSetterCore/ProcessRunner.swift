import Foundation

/// 一次外部命令的结果。非零退出是正常结果（launchctl 用退出码表达「找不到服务」这类状态）。
public struct ProcessOutcome: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }

    /// 诊断文案用的一行摘要：优先 stderr，退回 stdout。
    public var message: String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = text.isEmpty ? fallback : text
        return chosen.isEmpty ? "退出码 \(exitCode)" : chosen
    }
}

/// 执行外部命令的口子（`launchctl`、`/bin/sh`）。测试注入假实现，真实实现走 `Process`。
public protocol ProcessRunning: Sendable {
    /// `environment` 是子进程的**完整**环境（替换继承环境）：
    /// 这样 `$` 引用与 `$PATH` 锚点的展开只取决于脚本本身，不受 App 自己从哪启动、带着什么环境影响。
    func run(executable: String, arguments: [String], environment: [String: String]) -> ProcessOutcome
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], environment: [String: String]) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ProcessOutcome(exitCode: -1, stdout: "", stderr: "无法执行 \(executable)：\(error.localizedDescription)")
        }
        // 输出量都在几 KB 量级（launchctl 单服务信息、脚本 --print），先读完再 wait 不会撑爆管道缓冲。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutcome(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
