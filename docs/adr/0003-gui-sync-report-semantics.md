# GUI 同步结果报告集中清理语义

Status: accepted

GUI 同步继续使用现有 `EnvSetterCore.GuiApplyReport` 表达结果，不新增同步或重试 module；报告提供规范的 `removalCandidates` 与 `clearedKeys`，并保留 `removedKeys` 作为已弃用的兼容别名。只有清理操作成功返回的 key 才属于已清除项；未尝试或失败的候选项都保留为待清理残留。报告继续携带共享 warning 和阶段详情，UI 与 CLI 各自组织摘要文案。这样既让调用方使用明确的清理结果，也避免破坏潜在的 SwiftPM 下游调用方。
