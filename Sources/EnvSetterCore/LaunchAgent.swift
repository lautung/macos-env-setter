import Foundation

/// LaunchAgent（GUI 层的持久化）：`~/Library/LaunchAgents/<label>.plist`，`RunAtLoad` 调工具生成的 setenv.sh。
/// 变量变化只需重写脚本，不必重注册 agent——plist 里只有 Label / ProgramArguments / RunAtLoad。
public enum LaunchAgent {
    /// 工具自己的 label（反向 DNS，原型走查时定下）。
    public static let defaultLabel = "com.lautung.env-setter"
    public static let launchctlPath = "/bin/launchctl"
    public static let shellPath = "/bin/sh"
    /// launchd 给 agent 的默认 PATH（同 `sysctl -n user.cs_path`）。
    /// 登录时 agent 启动继承到的就是它，GUI 层的 `$PATH` 锚点在那一刻解析成它——不是终端里的 PATH。
    /// 工具算期望值时也固定用它（见 `GuiLayer.launchdLikeEnvironment`），与跑脚本的进程继承到什么无关。
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func plistURL(label: String, paths: EnginePaths) -> URL {
        paths.launchAgentsDirectory.appending(path: "\(label).plist")
    }

    /// plist 内容。用 PropertyListSerialization 生成，值里的 `&`、`<` 等由它负责转义。
    public static func plistData(label: String, scriptPath: String) throws -> Data {
        let payload: [String: Any] = [
            "Label": label,
            "ProgramArguments": [shellPath, scriptPath],
            "RunAtLoad": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    /// 磁盘上的 plist 是否已是目标内容。
    /// 比对解析后的内容而非字节：PropertyListSerialization 的键序不保证稳定，字节比对会造成无谓的重写与重注册。
    public static func plistMatches(existing: Data, label: String, scriptPath: String) -> Bool {
        guard let expected = try? plistData(label: label, scriptPath: scriptPath) else { return false }
        return dictionary(from: existing) == dictionary(from: expected)
    }

    /// 解析 plist 里的 Label（诊断用；读不出来说明不是有效 plist）。
    public static func label(inPlist data: Data) -> String? {
        dictionary(from: data)?["Label"] as? String
    }

    static func dictionary(from data: Data) -> NSDictionary? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? NSDictionary
    }
}
