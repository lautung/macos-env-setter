import Foundation
import EnvSetterCore

// 供验收与诊断用的最小 CLI：status / adopt [--apply] / restore / gui。
// 正式入口是 #8 的 SwiftUI 应用；本工具直接走真实路径。

func printUsage() {
    print(
        """
        用法：envsetter <命令>

        命令：
          status            查看状态（漂移、记录、备份）
          adopt             预览收编计划（不落盘）
          adopt --apply     执行收编并显式应用（先备份；含 GUI 层同步）
          restore           列出备份
          restore <文件名>  恢复指定备份
          gui               诊断 GUI 层（脚本 / LaunchAgent / 登录项 / 注入值）
          gui --sync        只重跑 GUI 层：重写 setenv.sh、注册 LaunchAgent、立即注入当前会话
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
        if let diagnosis = try engine.guiDiagnosis() {
            print(diagnosis.isHealthy ? "✅ GUI 层（launchd）诊断正常。" : "⚠️  GUI 层有需要注意的项（运行 `envsetter gui` 查看）。")
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
        let result = try engine.apply(entries: plan.entries, outsideEdits: plan.outsideEdits)
        print("✅ 已收编并应用（已先备份到 \(engine.paths.backupsDirectory.path)）。")
        describeGui(result.gui)
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

func describeGui(_ report: GuiApplyReport?) {
    guard let report else { return }
    print("== GUI 层（launchd）==")
    switch report.outcome {
    case .skipped:
        print("  没有启用 GUI 层的变量，未安装 LaunchAgent。")
        return
    case .applied: print("  ✅ 已同步。")
    case .partial: print("  ⚠️  部分完成（shell 层已写入，GUI 层见下）。")
    case .failed: print("  ❌ 未生效（shell 层已写入，不受影响）。")
    }
    let scriptNote = report.scriptWritten ? "已写入" : "未写入"
    print("  脚本：\(report.scriptURL.path)（\(scriptNote)，\(report.keys.count) 个变量）")
    if !report.keys.isEmpty { print("        变量：\(report.keys.joined(separator: "、"))") }
    if !report.removedKeys.isEmpty {
        print("  已清除残留：\(report.removedKeys.joined(separator: "、"))")
    }
    print("  LaunchAgent：\(report.agentRegistered ? "已注册" : "未注册")\(report.agentInstalled ? "（本次写入 plist）" : "")")
    print("  立即注入当前会话：\(report.liveSynced ? "成功" : "失败")")
    for mismatch in report.mismatches {
        print("  ⚠️  回读不一致 · \(mismatch.key)：域里 \(mismatch.actual ?? "（不存在）")，脚本算的是 \(mismatch.expected)")
    }
    if let warning = report.warning { print("  ⚠️  \(warning)") }
}

func checkMark(_ status: GuiCheckStatus) -> String {
    switch status {
    case .ok: return "✅"
    case .warning: return "⚠️ "
    case .failed: return "❌"
    }
}

func gui(_ engine: EnvSetterEngine, sync: Bool) {
    guard let layer = engine.gui else {
        print("❌ 引擎未接入 GUI 层。")
        return
    }
    if sync {
        guard let entries = loadAndReportDrift(engine) else { return }
        describeGui(layer.apply(entries: entries))
        return
    }
    do {
        guard let diagnosis = try engine.guiDiagnosis() else {
            print("❌ 引擎未接入 GUI 层。")
            return
        }
        print("== GUI 层诊断（\(layer.label)，\(layer.domain)）==")
        for check in diagnosis.checks {
            print("\(checkMark(check.status)) \(check.name)：\(check.detail)")
        }
        print(diagnosis.isHealthy ? "✅ 全部正常。" : "⚠️  有需要注意的项（见上）。")
    } catch {
        print("❌ 诊断失败：\(error)")
    }
}

let paths = EnginePaths.standard()
let engine = EnvSetterEngine(paths: paths, gui: GuiLayer(paths: paths))
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
case ("gui", nil):
    gui(engine, sync: false)
case ("gui", .some("--sync")):
    gui(engine, sync: true)
case ("gui", .some):
    printUsage()
    exit(2)
default:
    printUsage()
    exit(arguments.isEmpty ? 0 : 2)
}
