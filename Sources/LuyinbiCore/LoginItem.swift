import Foundation
import ServiceManagement

/// 开机自启。
///
/// 常驻工具不能开机自启就是名不副实——你每次开机都得手动打开它，
/// 那"录完自动进深脑"就成了"记得打开它才自动"。
///
/// 用 SMAppService（macOS 13+）而不是往 ~/Library/LaunchAgents 写 plist：
/// 后者要自己管 plist 生命周期，而且用户在系统设置里关掉后我们无从得知，
/// 界面上的开关会和真实状态对不上。
public enum LoginItem {
    public static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 返回 nil 表示成功，否则是给人看的失败原因。
    public static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "系统拒绝了：\(error.localizedDescription)"
        }
    }

    /// 用户可能在系统设置里手动关过，界面每次显示前都该重新问一次真实状态。
    public static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return "已开启"
        case .requiresApproval:  return "等你在系统设置里批准"
        case .notFound:          return "系统没找到这个应用"
        default:                 return "未开启"
        }
    }
}
