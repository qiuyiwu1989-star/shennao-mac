import AppKit
import Combine
import Foundation
import LuyinbiCore

/// 界面能触发的所有动作。
/// 现在全是回调（默认实现只做「能马上做的」，比如开文件夹、开网页），
/// 真引擎接进来时在 LuyinbiRootApp 里把 syncNow / repush / redownload 覆盖掉即可。
struct AppActions {
    var syncNow: @MainActor () -> Void = {}
    var openImportFolder: @MainActor () -> Void = {}
    /// 开/关「同步后自动清理设备」。删除不可逆，所以打开前界面必须先弹确认。
    var setCleanup: @MainActor (Bool) -> Void = { _ in }
    var setMinUploadMinutes: @MainActor (Int) -> Void = { _ in }
    /// 登录。返回 nil 表示成功，否则是给人看的失败原因。
    var signIn: @MainActor (String, String) async -> String? = { _, _ in "未接线" }
    var signOut: @MainActor () -> Void = {}
    var setLoginItem: @MainActor (Bool) -> Void = { _ in }
    var openLog: @MainActor () -> Void = {}
    var openMainWindow: @MainActor () -> Void = {}
    /// 从设备上删掉这一条（人手指定，不走自动清理那六道闸）
    var deleteFromDevice: @MainActor (RecordingItem) -> Void = { _ in }
    var toggleStar: @MainActor (RecordingItem) -> Void = { _ in }
    /// 上传前定标题与项目。已推上去的不生效（引擎侧也挡着）。
    var setPlan: @MainActor (RecordingItem, String?, String?) -> Void = { _, _, _ in }
    var runAudit: @MainActor () -> Void = {}
    /// 手动推给深脑（无视时长门槛）
    var pushNow: @MainActor (RecordingItem) -> Void = { _ in }
    /// 这条从设备删掉会丢什么——弹确认框之前要问
    var deleteImpact: @MainActor (RecordingItem) -> String = { _ in "" }
    var openBrainHome: @MainActor () -> Void = {}
    var openBrainSession: @MainActor (RecordingItem) -> Void = { _ in }
    var repush: @MainActor (RecordingItem) -> Void = { _ in }
    var redownload: @MainActor (RecordingItem) -> Void = { _ in }
    var revealLocal: @MainActor (RecordingItem) -> Void = { _ in }
    var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    /// 账号不匹配警告里点了「继续」：换个名字重新绑给当前账号（spec 019）。
    /// 返回 false 表示绑定没成功（多半是名字又撞了），界面留在原地让人换个名字重试。
    var resolveBindMismatch: @MainActor (String) async -> Bool = { _ in false }
    /// 账号不匹配警告里点了「取消」：这支笔这次不同步，警告卡片消失。
    var dismissBindMismatch: @MainActor () -> Void = {}
    /// 真去验一次会话还能不能用（不是只看本地存没存过 token）。
    var checkSession: @MainActor () async -> DeepBrain.AuthState = { .none }
}

/// 界面侧的唯一数据源。
///
/// 引擎的状态抄一份到这里，界面只认这一份。
///
/// **抄的时机是订阅，不是轮询。** 原来是 0.4 秒一个 Timer + 一个把所有条目
/// 拼成字符串的「指纹」来判断变没变。那个指纹漏掉了 18 个字段里的 9 个，
/// 而漏掉的恰好是**用户自己动作会改的那些**：收藏、待删除、待认人数、
/// 深脑标题、太短跳过……于是点了收藏没反应、点了从设备删除那一行不变、
/// 认完人「认人 N」还挂着。当初写这层的理由（"引擎由另一条线在写，
/// 不能假设它是 ObservableObject"）早就不成立了：`SyncEngine` 就是
/// ObservableObject，七个被抄的属性全带 @Published（2026-09-07 review）。
@MainActor
final class AppModel: ObservableObject {

    // MARK: 从引擎抄过来的快照
    @Published private(set) var device = DeviceInfo()
    @Published fileprivate(set) var items: [RecordingItem] = []
    @Published private(set) var phase: SyncPhase = .idle
    /// 设备-账号绑定不一致，等着人确认（spec 019）。非 nil 时「设备」页要显示确认卡片。
    @Published private(set) var pendingBindMismatch: BindMismatch?
    /// 整条推送链为什么停着。非 nil 时主窗口顶部显示横幅。
    @Published private(set) var uploadBlocked: String?
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: String = ""

    // MARK: 纯界面状态
    @Published var selection: RecordingItem.ID?

    /// 此刻正在被搬运的那一条。分类时用它把「正在进行」和「卡住」分开。
    var busyBase: String? {
        switch phase {
        case .downloading(let n, _), .uploading(let n, _): return n
        default: return nil
        }
    }

    /// 动作回调。默认值在 init 里补成「能直接干活」的版本。
    var actions = AppActions()

    /// 导入文件夹。接真引擎时应由引擎的配置覆盖这一行。
    var importFolder: URL = FileManager.default.homeDirectoryForCurrentUser
    /// 项目根目录，波形缓存写在它下面的 out/waveform
    var projectRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目/导入")

    /// 深脑站点。接真引擎时应由引擎的配置覆盖这一行。
    var brainBaseURL = URL(string: "https://shennao.zaowuyun.com")!
    /// 哪个大面板开着。nil = 正常详情。
    @Published var panel: Panel?
    enum Panel { case audit }
    /// 归档体检结果，菜单和面板共用
    @Published var auditReport: ArchiveAudit.Report?
    /// 已登录的深脑客户端。登录/退出要用。
    @Published var brain: DeepBrain?
    @Published var cleanupEnabled = false
    @Published var coolingDays = 3
    @Published var minUploadMinutes = 5
    /// nil = 还没查出来。**绝不能在这里同步读钥匙串**：
    /// 重新签名后系统会弹授权框，那个模态框会把窗口创建整个卡住——
    /// 表现为"打开应用什么都不出现"，极难联想到是钥匙串引起的。
    /// 窗口先摆出来，登录态异步查。
    @Published var signedIn: Bool?
    @Published var signedInEmail: String?
    /// 会话被服务端判为失效时给人看的一句话。登录页据此说明"为什么又要登一次"。
    @Published var sessionNotice: String?
    @Published var launchAtLogin = false

    /// base → transcriptId。
    var transcriptIdMap: [String: String] {
        Dictionary(uniqueKeysWithValues: items.compactMap { i in
            i.transcriptId.map { (i.base, $0) }
        })
    }


    func applyBrainTitle(base: String, title: String) {
        guard let i = items.firstIndex(where: { $0.base == base }) else { return }
        guard items[i].brainTitle != title else { return }
        items[i].brainTitle = title
    }

    /// 查登录态。
    ///
    /// **先用本地那份把界面点亮，再去服务端真验一次。**
    /// 只看本地会犯 2026-09-07 那个错：存着一个早就失效的 token，
    /// 界面一直显示「已登录」、永远不弹登录页，而后台每一次推送都在静默失败。
    /// 只等服务端又太慢——开窗要先干等一个网络往返，断网时更是永远转圈。
    /// 所以两段式：本地先给个乐观值，服务端回话后再纠正。
    func refreshAuthAsync() {
        Task.detached(priority: .utility) {
            let has = DeepBrain.hasCredentials
            let mail = DeepBrain.signedInEmail
            let login = LoginItem.enabled
            await MainActor.run {
                self.signedIn = has
                self.signedInEmail = mail
                self.launchAtLogin = login
            }
            guard has else { return }
            let state = await self.actions.checkSession()
            await MainActor.run {
                switch state {
                case .expired:
                    // 服务端明确不认这份凭证：清掉，把人送去登录页。
                    // 留着它只会让每一次推送继续静默失败，而界面还说「已登录」。
                    self.actions.signOut()
                    self.sessionNotice = "登录已失效，请重新登录"
                case .valid:
                    self.sessionNotice = nil
                case .unreachable, .none:
                    // 连不上说明不了什么，别把人踢出去。
                    break
                }
            }
        }
    }

    private var engine: SyncEngine?
    private var cancellable: AnyCancellable?

    init(engine: SyncEngine? = nil) {
        installDefaultActions()
        attach(engine)
    }


    // MARK: - 接引擎

    /// 换数据源就调这一个方法。
    func attach(_ newEngine: SyncEngine?) {
        engine = newEngine
        pull()
        // objectWillChange 是**变更之前**发的，所以要挪到下一轮 runloop 再读，
        // 否则抄到的是旧值。`.common` 模式：拖窗口、开菜单时也不能停。
        cancellable = newEngine?.objectWillChange
            .receive(on: RunLoop.main, options: nil)
            .sink { [weak self] _ in self?.pull() }
    }

    private func pull() {
        guard let engine else { return }
        device = engine.device
        items = engine.items
        phase = engine.phase
        pendingBindMismatch = engine.pendingBindMismatch
        uploadBlocked = engine.uploadBlocked
        lastRun = engine.lastRun
        lastSummary = engine.lastSummary
        // 选中的行如果没了，清掉选中，别让详情面板悬空。
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
    }


    // MARK: - 派生状态

    var selectedItem: RecordingItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    /// 引擎是不是正忙。菜单栏图标和设备卡的转圈都看它。
    var isBusy: Bool {
        switch phase {
        case .idle, .waitingForDevice, .failed: return false
        default: return true
        }
    }

    /// 菜单栏标题。全程只用文字和符号，不用 emoji。
    /// 菜单栏图标用脑子（深脑的品牌符号），不用文字——
    /// 一个「录」字在满是图标的菜单栏里根本看不见，用户会以为程序没起来。
    var menuBarSymbol: String {
        switch phase {
        case .failed: return "exclamationmark.triangle"
        default:      return "brain"
        }
    }

    /// 图标右边的极简状态后缀。只在真的在搬东西时才出现，平时保持干净。
    var menuBarSuffix: String {
        switch phase {
        case .downloading(_, let pct):  return " \(pct)%"
        case .uploading:                return " ↑"
        case .connecting, .listing:     return " ·"
        case .cleaning:                 return " ···"
        default:                        return ""
        }
    }

    /// 某一条录音此刻是不是正在被搬运。返回（说明文字，进度 0…1，nil 表示进度未知）。
    func activity(for item: RecordingItem) -> (label: String, fraction: Double?)? {
        switch phase {
        case .downloading(let name, let pct) where name.contains(item.base):
            return ("下载中", Double(pct) / 100.0)
        case .uploading(let name, let step) where name.contains(item.base):
            return ("推送：\(step)", nil)
        default:
            return nil
        }
    }

    // MARK: - 默认动作

    private func installDefaultActions() {
        actions.openImportFolder = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.importFolder)
        }
        actions.openBrainHome = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.brainBaseURL)
        }
        actions.openBrainSession = { [weak self] item in
            guard let self else { return }
            // 深脑的转写页是 /zh/transcript/<transcriptId>——带播放器、发言人面板、
            // 文字记录点击跳转的那一页，正是从 Mac 跳过去最该落的地方。
            // （此前我用的 /analyze?transcript= 是分析页，不是这一页。）
            guard let tid = item.transcriptId else { return }
            let url = self.brainBaseURL
                .appendingPathComponent("zh")
                .appendingPathComponent("transcript")
                .appendingPathComponent(tid)
            NSWorkspace.shared.open(url)
        }
        actions.revealLocal = { [weak self] item in
            guard let self else { return }
            let file = self.importFolder.appendingPathComponent("\(item.base).ogg")
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                NSWorkspace.shared.open(self.importFolder)
            }
        }
    }
}
