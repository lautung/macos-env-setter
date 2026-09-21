import AppKit
import Foundation

/// 一个正在运行的 App（只取界面需要的字段，便于测试替身）。
public struct RunningApp: Identifiable, Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var bundleURL: URL?
    public var pid: pid_t

    public init(name: String, bundleIdentifier: String?, bundleURL: URL?, pid: pid_t) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.pid = pid
    }

    public var id: pid_t { pid }

    /// 没有 App 包路径就无从重新打开（极少见，但别让按钮点下去无声失败）。
    public var canRestart: Bool { bundleURL != nil }
}

/// 「重启指定 App」与「打开登录项设置」的口子。测试注入替身，真实实现走 NSWorkspace。
@MainActor
public protocol AppController {
    func runningApps() -> [RunningApp]
    /// 退出并重新打开。返回 nil = 成功；否则是给人看的失败说明。
    func restart(_ app: RunningApp) async -> String?
    /// 打开系统设置的「登录项与扩展」面板（后台项被关掉时的补救入口）。
    func openLoginItemsSettings()
}

/// 真机实现：请求退出 → 等它真的退出 → 重新打开。
///
/// 必须等退出：进程环境在启动时固定，没退出就重开只会开出一个仍带旧值的进程。
/// 等不到就如实报告并放弃重启——强杀可能让目标 App 丢文档。
@MainActor
public struct WorkspaceAppController: AppController {
    public init() {}

    public func runningApps() -> [RunningApp] {
        let ownBundle = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != ownBundle }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(
                    name: name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    pid: app.processIdentifier
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func restart(_ app: RunningApp) async -> String? {
        guard let url = app.bundleURL else {
            return "「\(app.name)」没有可重新打开的 App 包路径，请从 Dock 手工重开。"
        }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else {
            return "「\(app.name)」已经不在运行了，请刷新列表。"
        }
        guard running.terminate() else {
            return "无法请求「\(app.name)」退出。请手工退出后重新打开。"
        }

        let deadline = Date().addingTimeInterval(Self.terminationTimeout)
        while !running.isTerminated, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard running.isTerminated else {
            return "「\(app.name)」没有在 \(Int(Self.terminationTimeout)) 秒内退出（可能有未保存的文档）。已放弃重启。"
        }

        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return nil
        } catch {
            return "「\(app.name)」已退出，但重新打开失败：\(error.localizedDescription)。请从 Dock 重新打开。"
        }
    }

    public func openLoginItemsSettings() {
        // Ventura 起「后台项」开关在这个面板里；打不开也不报错——面板路径随系统版本变过。
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static let terminationTimeout: TimeInterval = 5
}
