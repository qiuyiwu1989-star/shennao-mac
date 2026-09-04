import AppKit
import SwiftUI

/// 菜单栏那个「录」字点开之后的菜单。
/// 用的是 MenuBarExtra 默认的 .menu 样式：Text 会渲染成不可点的说明行，Button 是菜单项。
struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("状态：\(model.phase.label)")
        Text("上次同步：\(Fmt.time(model.lastRun))")
        if !model.lastSummary.isEmpty {
            Text(model.lastSummary)
        }
        if model.device.connected {
            Text("设备：\(model.device.name)　\(model.device.battery.map { "电量 \($0)%" } ?? "")")
        }

        Divider()

        Button("立即同步") { model.actions.syncNow() }
            .keyboardShortcut("s")
            .disabled(model.isBusy)

        // 走 AppKit 那条路，不用 SwiftUI 的 openWindow——
        // 有 MenuBarExtra 时 Window 场景根本不会被创建，openWindow 打不开不存在的东西。
        Button("打开主窗口") { model.actions.openMainWindow() }
        .keyboardShortcut("0")

        Divider()

        Button("打开导入文件夹") { model.actions.openImportFolder() }
        Button("打开深脑网页") { model.actions.openBrainHome() }
        Button("查看同步日志") { model.actions.openLog() }
        Button("体检本地归档") {
            model.actions.openMainWindow()
            model.panel = .audit
        }

        Divider()

        Button(model.launchAtLogin ? "开机自启（已开启）" : "开机自启（未开启）") {
            model.actions.setLoginItem(!model.launchAtLogin)
        }

        if let mail = model.signedInEmail {
            Button("退出登录（\(mail)）") {
                let a = NSAlert()
                a.messageText = "退出登录？"
                a.informativeText = "本机已导入的录音不会受影响，但在重新登录之前不能再推给深脑。"
                a.addButton(withTitle: "退出登录")
                a.addButton(withTitle: "取消")
                NSApplication.shared.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { model.actions.signOut() }
            }
        }

        Divider()

        Button("短录音门槛：\(model.minUploadMinutes) 分钟以下只落盘") {
            let alert = NSAlert()
            alert.messageText = "多少分钟以下的录音不推深脑？"
            alert.informativeText = "短录音照样下载并留在本机，只是不推给深脑转写——花钱的是转写和分析，不是下载。\n随时可以在详情里手动推。填 0 表示全部都推。"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
            field.stringValue = "\(model.minUploadMinutes)"
            alert.accessoryView = field
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), v >= 0, v <= 120 {
                model.actions.setMinUploadMinutes(v)
            }
        }

        Divider()

        // 删除不可逆，所以这里打开时要先弹确认；默认关闭。
        Button(model.cleanupEnabled
               ? "同步后自动清理设备（已开启，冷静期 \(model.coolingDays) 天）"
               : "同步后自动清理设备（已关闭）") {
            if model.cleanupEnabled {
                model.actions.setCleanup(false)
                return
            }
            let alert = NSAlert()
            alert.messageText = "开启后会删除录音笔里的文件"
            alert.informativeText = """
            只删同时满足这些条件的：已进深脑并转写完成、本地有裸包和 ogg 两份留档、\
            字节数和时长都对得上、录制时间超过 \(model.coolingDays) 天、且设备当前没在录音。

            任何一条拿不准都不删。删除不可逆。

            另外：深脑 30 天后会清掉原始音频（隐私承诺），\
            所以长期归档实际靠本机「导入/原始包」文件夹，别把它删了。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "我明白，开启")
            alert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                model.actions.setCleanup(true)
            }
        }

        Divider()

        Button("退出录音笔导入器") { model.actions.quit() }
            .keyboardShortcut("q")
    }
}
