import Foundation
import EnvSetterCore

// 供验收与诊断用的最小 CLI：status / adopt [--apply] / restore。
// 正式入口是 #8 的 SwiftUI 应用；本工具直接走真实路径。

func printUsage() {
    print(
        """
        用法：envsetter <命令>

        命令：
          status            查看状态（漂移、记录、备份）
          adopt             预览收编计划（不落盘）
          adopt --apply     执行收编并显式应用（先备份）
          restore           列出备份
          restore <文件名>  恢复指定备份
        """
    )
}

func loadAndReportDrift(_ engine: EnvSetterEngine) -> [ManagedEntry]? {
    do {
        let result = try engine.load()
        if result.driftDetected {
            print("⚠️  检测到漂移：标记块被手工改动过，已以文件为准重新载入。")
        }
        if result.adoptedExistingBlock {
            print("ℹ️  发现已有标记块，已将其内容收编为当前状态。")
        }
        return result.entries
    } catch {
        print("❌ 载入失败：\(error)")
        return nil
    }
}

func describe(entries: [ManagedEntry]) {
    if entries.isEmpty { print("（暂无变量记录）") }
    for entry in entries {
        switch entry {
        case .record(let record):
            let layers = [record.shellEnabled ? "shell" : nil, record.guiEnabled ? "GUI" : nil]
                .compactMap { $0 }.joined(separator: "+")
            let source = record.source == .adopted ? "导入" : "创建"
            print("  \(record.key) [\(layers)/\(source)] = \(record.rawValue)")
        case .verbatim(let line):
            print("  （逐字保留）\(line)")
        }
    }
}

func status(_ engine: EnvSetterEngine) {
    guard let entries = loadAndReportDrift(engine) else { return }
    print("== 变量记录（声明顺序）==")
    describe(entries: entries)
    do {
        let drift = try engine.checkDrift()
        print(drift ? "⚠️  当前存在未处理的漂移。" : "✅ 无漂移。")
        let list = try engine.backupsList()
        print("== 备份（\(list.count) 份，\(BackupManager.retentionCount) 份轮转 + 基线）==")
        for info in list {
            print("  \(info.isBaseline ? "[基线] " : "      ")\(info.fileName)")
        }
    } catch {
        print("❌ 状态检查失败：\(error)")
    }
}

func adopt(_ engine: EnvSetterEngine, apply: Bool) {
    guard loadAndReportDrift(engine) != nil else { return }
    do {
        let plan = try engine.planAdoption()
        if plan.adoptedKeys.isEmpty && plan.mergedPathLineCount == 0 && plan.outsideEdits.isEmpty {
            print("✅ 没有可收编的块外 export 行。")
            return
        }
        print("== 收编计划 ==")
        print("将注释掉 \(plan.outsideEdits.count) 行并接管：")
        for key in plan.adoptedKeys { print("  · \(key)") }
        if plan.mergedPathLineCount > 0 {
            print("  · PATH（\(plan.mergedPathLineCount) 行合并进有序列表）")
        }
        for line in plan.skipped {
            print("  ⏭ 跳过第 \(line.lineIndex + 1) 行（\(line.reason)）：\(line.line)")
        }
        if !apply {
            print("（预览模式，未落盘；加 --apply 执行）")
            return
        }
        try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)
        print("✅ 已收编并应用（已先备份到 \(engine.paths.backupsDirectory.path)）。")
        print("== 应用后的变量记录 ==")
        describe(entries: plan.entries)
    } catch {
        print("❌ 收编失败：\(error)")
    }
}

func restoreList(_ engine: EnvSetterEngine) {
    do {
        let list = try engine.backupsList()
        if list.isEmpty { print("（暂无备份）") }
        for info in list {
            print("  \(info.isBaseline ? "[基线] " : "      ")\(info.fileName)")
        }
    } catch {
        print("❌ 列出备份失败：\(error)")
    }
}

func restore(_ engine: EnvSetterEngine, named name: String) {
    do {
        let list = try engine.backupsList()
        guard let info = list.first(where: { $0.fileName == name }) else {
            print("❌ 找不到备份：\(name)")
            return
        }
        try engine.restore(from: info)
        print("✅ 已恢复 \(name)（恢复前的内容也已备份）。")
    } catch {
        print("❌ 恢复失败：\(error)")
    }
}

let engine = EnvSetterEngine(paths: .standard())
let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.dropFirst().first) {
case ("status", _):
    status(engine)
case ("adopt", let second):
    guard second == nil || second == "--apply" else { printUsage(); exit(2) }
    adopt(engine, apply: second == "--apply")
case ("restore", nil):
    restoreList(engine)
case ("restore", .some(let name)):
    restore(engine, named: name)
default:
    printUsage()
    exit(arguments.isEmpty ? 0 : 2)
}
