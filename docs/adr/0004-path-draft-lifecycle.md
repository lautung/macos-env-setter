# 将 PATH 行草稿生命周期收进 EnvSetterUI

PATH 行草稿由 `EnvSetterUI` 内的专门 module 管理行身份、编辑、重同步、归一化、提交与载入保护；`AppModel.entries` 中的 PATH 原始值仍是待生效状态的权威来源，语义编辑即时写回。外部替换 PATH 值或改变记录身份时，从当前记录重建行状态；编辑器自身的逐字写回保留尚未归一化的行。UI 通过稳定行 ID 操作，结构归一化尽量保留未变化行的 ID；明确删空表示空 PATH，与未载入状态区分。将编辑生命周期留在 UI 层，复用 Core 的原始 PATH 语义，避免 AppModel 漏同步及删除撤销后旧行状态复活编辑。
