import AppKit
import LuyinbiCore
import SwiftUI

/// 全局单例：引擎和界面模型都挂在这儿。
///
/// 为什么不是 @StateObject：主窗口是用 AppKit 直接建的（见下），
/// 它和 MenuBarExtra 需要共用同一份模型，SwiftUI 的 scene 生命周期管不到它。
@MainActor
final class AppState {
    static let shared = AppState()
    let engine = SyncEngine()
    let model: AppModel
    private var wired = false

    private init() { model = AppModel(engine: engine) }

    func wire() {
        guard !wired else { return }
        wired = true
        model.importFolder = engine.paths.dest
        model.projectRoot = engine.paths.root
        model.actions.syncNow = { [engine] in engine.syncNow() }
        // 重推要按条走 repushFailed：那条会话已经 finalize 了，
        // 笼统刷队列会走幂等重放（拿回同一个已完成的会话），等于什么都没做。
        model.actions.repush = { [engine] item in engine.repushFailed(item.base) }
        model.actions.redownload = { [engine] item in engine.requestRedownload(item.base) }
        model.actions.pushNow = { [engine] item in engine.pushNow(item.base) }
        model.actions.deleteImpact = { [engine] item in engine.deleteImpact(item.base) }
        model.actions.deleteFromDevice = { [engine] item in engine.requestDeviceDelete(item.base) }
        model.actions.toggleStar = { [engine] item in engine.toggleStar(item.base) }
        model.actions.setPlan = { [engine] item, title, pid in
            engine.setPlan(item.base, title: title, projectId: pid)
        }
        model.actions.runAudit = { [engine, weak model] in
            model?.auditReport = engine.runArchiveAudit()
        }
        model.actions.openLog = { [engine] in NSWorkspace.shared.open(engine.paths.syncLog) }
        model.actions.checkSession = { [engine] in
            guard let cfg = try? DeepBrainConfig.load(from: engine.paths.deepBrainConfig) else { return .none }
            return await DeepBrain.checkSession(config: cfg)
        }
        model.actions.resolveBindMismatch = { [engine] name in await engine.resolveBindMismatch(newDeviceName: name) }
        model.actions.dismissBindMismatch = { [engine] in engine.dismissBindMismatch() }
        model.cleanupEnabled = engine.cleanup.deleteAfterSync
        model.coolingDays = engine.cleanup.coolingDays
        model.minUploadMinutes = engine.cleanup.minUploadSeconds / 60
        model.actions.setMinUploadMinutes = { [engine, weak model] m in
            engine.cleanup.minUploadSeconds = m * 60
            model?.minUploadMinutes = m
        }
        model.actions.setCleanup = { [engine, weak model] on in
            engine.cleanup.deleteAfterSync = on
            model?.cleanupEnabled = on
        }
        model.actions.openMainWindow = { AppState.shared.showMainWindow() }
        model.refreshAuthAsync()
        Notify.request()
        model.actions.signIn = { [engine, weak model] email, pwd in
            guard let brain = await engine.uiBrain(allowUnauthenticated: true) else {
                return "读不到深脑配置"
            }
            do {
                try await brain.signIn(email: email, password: pwd)
                model?.signedIn = true
                model?.signedInEmail = DeepBrain.signedInEmail
                model?.brain = brain
                engine.start()
                return nil
            } catch { return "\(error)" }
        }
        // **退出登录必须无条件清掉本地凭证。**
        // 原来走 `uiBrain()`（allowUnauthenticated 默认 false）——而它内部要先
        // ensureBrain() 成功才给实例。于是凭证一旦失效，uiBrain() 返回 nil、
        // signOut() 根本不执行，TokenStore.clear() 也就没跑：界面显示已退出，
        // 磁盘上那份坏 token 原封不动，下次启动又被当成「已登录」。
        // 2026-09-07：这正是「退出登录也救不回来」的那一环——**最需要退出的时候，
        // 退出功能恰好因为同一个原因失灵**。清本地这件事不该依赖网络。
        model.actions.signOut = { [weak model] in
            TokenStore.clear()
            Task { await AppState.shared.engine.uiBrain(allowUnauthenticated: true)?.signOut() }
            model?.signedIn = false
            model?.signedInEmail = nil
        }
        model.actions.setLoginItem = { [weak model] on in
            if let err = LoginItem.set(on) {
                let a = NSAlert(); a.messageText = "开机自启设置失败"; a.informativeText = err
                a.runModal()
            }
            model?.launchAtLogin = LoginItem.enabled
        }
        engine.start()
        // 深脑客户端异步取，取到了说话人面板才出现
        Task { [engine, model] in model.brain = await engine.uiBrain() }
    }

    // MARK: - 主窗口
    private var window: NSWindow?

    /// 主窗口用 AppKit 建，不用 SwiftUI 的 Window 场景。
    ///
    /// 原因是实测出来的：应用里只要有 MenuBarExtra，`Window` 场景就不会在启动时实例化，
    /// 必须等显式 openWindow 才创建——表现为双击应用什么都不出现，
    /// 用窗口列表查也只有菜单栏那条 1470x33 的条，主窗口根本不存在。
    /// AppKit 建窗是确定的，建了就在。
    func showMainWindow() {
        if let w = window {
            bringUp(w)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "深脑"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false          // 关掉还能再打开
        w.minSize = NSSize(width: 860, height: 520)
        w.contentView = NSHostingView(rootView: RootContentView(model: model))
        w.setFrameAutosaveName("deepbrain.main")
        w.center()
        window = w
        bringUp(w)
        // 推到真的上屏为止。启动瞬间窗口可能被 SwiftUI 的场景初始化排到后面，
        // 单推一次不够——实测连开三次只有一次成功。这里最多补推 10 次（约 2.5 秒），
        // 一旦可见就停，正常情况下第一次就成了，不会有额外开销。
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak w] t in
            guard let w else { t.invalidate(); return }
            tries += 1
            if w.isVisible && w.occlusionState.contains(.visible) || tries >= 10 {
                t.invalidate()
                return
            }
            MainActor.assumeIsolated { self.bringUp(w) }
        }
    }

    /// 窗口跑到屏幕外面就拉回来。
    ///
    /// setFrameAutosaveName 会记住上次的位置——如果那是一台已经拔掉的外接显示器，
    /// 恢复出来的坐标可能是 x = -5766 这种。窗口确实存在、系统也认为它"显示"着，
    /// 但你在屏幕上什么都看不到，表现又是「打开没反应」。
    private func ensureOnScreen(_ w: NSWindow) {
        let frame = w.frame
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard !visible else { return }
        w.center()
    }

    private func bringUp(_ w: NSWindow) {
        ensureOnScreen(w)
        NSApp.activate(ignoringOtherApps: true)
        // orderFrontRegardless 比 makeKeyAndOrderFront 硬：
        // 后者在应用不是前台时可能什么都不做。
        w.orderFrontRegardless()
        w.makeKey()
    }
}

@main
struct LuyinbiRootApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @ObservedObject private var model = AppState.shared.model

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            // 菜单栏：脑子图标 + 极简状态后缀。图标用 SF Symbols，绝不用 emoji。
            HStack(spacing: 2) {
                Image(systemName: model.menuBarSymbol)
                if !model.menuBarSuffix.isEmpty {
                    Text(model.menuBarSuffix).font(.system(size: 11, weight: .medium))
                }
            }
        }
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不要在这里调 setActivationPolicy(.regular)。
        // Info.plist 里没有 LSUIElement，应用默认就是 regular，这一句是多余的；
        // 而且实测它会让刚建好的窗口被重新排序、有时候直接不上屏——
        // 连开三次只有一次能看到窗口，用户看到的就是"时灵时不灵"。
        AppState.shared.wire()
        AppState.shared.showMainWindow()
    }

    /// 点 Dock 图标 / 再次打开应用时把窗口找回来。
    /// 没有这个，关掉窗口之后就再也打不开了：应用还在跑，但用户没有任何入口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showMainWindow()
        return true
    }

    /// 关掉主窗口不等于退出——这是常驻工具，退出只走菜单里的「退出」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}


/// 根视图：没登录先给引导页，别把人扔进一个空表格。
struct RootContentView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.signedIn {
        case .some(true):  MainWindowView(model: model)
        case .some(false): WelcomeView(model: model)
        case .none:
            // 还在查登录态。这一格通常一闪而过，但不能没有——
            // 空白会让人以为界面坏了。
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在检查登录状态").font(DS.bodyFont(DS.T.title))
                    .foregroundStyle(DS.body(scheme == .dark))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.bg(scheme == .dark))
            .onAppear { model.refreshAuthAsync() }
        }
    }
}
