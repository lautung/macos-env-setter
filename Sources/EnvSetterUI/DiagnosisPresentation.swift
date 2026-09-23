import EnvSetterCore

/// 诊断清单在界面上的取用方式。纯逻辑，不依赖 SwiftUI，可直接测。
extension GuiDiagnosis {
    /// 「打开系统设置的登录项面板」按钮的显示条件：后台项那一行不是通过状态。
    ///
    /// 按标题常量判定，而不是对标题做子串匹配——标题是清单的行身份（见 `GuiCheckTitle`），
    /// 以后改标题时这里会编译期报错，不会悄悄变成「那一行找不到」。
    public var hasBackgroundItemProblem: Bool {
        checks.contains { $0.name == GuiCheckTitle.backgroundItem && $0.status != .ok }
    }
}
