# UI 原型走查

Type: prototype
Status: open
Blocked by: 03

## Question

用 /prototype 做一个 SwiftUI 粗原型并和用户走查，回答「界面长什么样、交互顺不顺」：

1. 主界面布局：单一全局列表 + 新建/编辑表单的形态；变量多时的搜索/过滤。
2. PATH 专用 UI：有序条目列表、拖拽排序、重复条目提示的具体呈现。
3. 两层状态的呈现：一条变量「shell 已写 / GUI 已写 / 待生效」如何在列表与编辑页表达；生效语义提示（只影响之后新启动的进程）怎么讲清楚；「重启指定 App」助手与 BTM/launchctl getenv 诊断入口要不要进 v1（见 01 票 findings 第 4 点）。
4. 备份恢复与导入的入口放在哪；秘密值（token 类）打码显示要不要进 v1（见 02 票 findings 第 8 点）。
