import Foundation
import UserNotifications

/// 完成通知。
///
/// 这是常驻后台工具的基本反馈：同步在你不看屏幕的时候发生，没有通知你就不知道它干了什么。
/// Python 版一直有，Swift 版之前漏了。
///
/// 用 UNUserNotificationCenter，失败时退回 osascript——ad-hoc 签名的应用申请通知权限
/// 有可能被系统拒，而 osascript 那条路一直能用（Python 版就是靠它）。宁可土一点也要有回音。
public enum Notify {
    private static var authorized: Bool?

    /// **没有正式 App Bundle 就别碰 UNUserNotificationCenter。**
    ///
    /// `swift run`/`swift build` 直接跑出来的可执行文件没有 `CFBundleIdentifier`——
    /// `UNUserNotificationCenter.current()` 这一步在这种进程里不是返回错误，是直接抛
    /// Objective-C 异常（`bundleProxyForCurrentProcess is nil`），Swift 的 try/catch
    /// 抓不住它，整个进程当场崩溃。这个模块本来就为了这种「签名不完整」的场合准备了
    /// osascript 兜底——只是漏了「连申请权限这一步都可能直接崩」这种情况。
    /// 判据用 `Bundle.main.bundleIdentifier`：读它本身不会崩，能提前避开会崩的那一步。
    private static var hasProperBundle: Bool { Bundle.main.bundleIdentifier != nil }

    public static func request() {
        guard hasProperBundle else { authorized = false; return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { ok, _ in authorized = ok }
    }

    public static func send(_ body: String, title: String = "深脑") {
        guard hasProperBundle, authorized != false else { fallback(body, title); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if err != nil { fallback(body, title) }
        }
    }

    private static func fallback(_ body: String, _ title: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
