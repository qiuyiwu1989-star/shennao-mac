import Foundation
import Combine
@preconcurrency import CoreBluetooth

/// 持续监听 + 自动同步引擎。
///
/// 为什么不能沿用 Python 版的「每 10 分钟扫一次」：
/// CB08 空闲约 7–8 分钟就停止 BLE 广播。定时扫描的窗口（8 秒）落在广播窗口里的概率
/// 大概只有 8/480 ≈ 1.7%——不是「偶尔错过」，是**几乎必然错过**。
/// 唯一可靠的做法是一直在听：录音笔一开机/一按停止就会重新广播，我们必须在那几分钟里
/// 随时能接住它。
///
/// 同步流程与 importer/pull.py 逐步对齐（落盘路径、清单键、幂等键都必须一致，
/// 两边要能交替使用而不互相打架）。
/// **本文件不实现任何删除**——删除由 Cleanup 模块负责。

// MARK: - 路径

/// 全部落盘位置。与 pull.py 里的 ROOT / DEST / RAW / MANIFEST 一一对应。
public struct SyncPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// 默认就是 iCloud 里那个「录音项目」目录，跟 luyinbi-cli 用的是同一个。
    public static let `default` = SyncPaths(
        root: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目"))

    public var dest: URL { root.appendingPathComponent("导入") }
    public var rawPackets: URL { dest.appendingPathComponent("原始包") }
    public var manifest: URL { dest.appendingPathComponent("manifest.json") }
    public var deepBrainConfig: URL { root.appendingPathComponent("importer/deepbrain.json") }

    public func ensureDirs() throws {
        try FileManager.default.createDirectory(at: rawPackets, withIntermediateDirectories: true)
    }
}

// MARK: - 清单

/// manifest.json。**格式必须与 Python 版完全兼容**——同一个文件两边轮流读写。
///
/// 实际磁盘格式（已核对 导入/manifest.json）：
///   imported: { "<20B截断名>|<秒>|<字节>": { file, bytes, at } }
///   uploaded: { "<base>": "<深脑会话 id>" }
///   deleted:  { "<base>": "<时间戳>" }        ← Cleanup 模块写的，我们只读不改
public struct SyncManifest: Codable, Equatable, Sendable {
    public struct Imported: Codable, Equatable, Sendable {
        public var file: String
        public var bytes: Int
        public var at: String
        public init(file: String, bytes: Int, at: String) {
            self.file = file; self.bytes = bytes; self.at = at
        }
    }

    public var imported: [String: Imported] = [:]
    public var uploaded: [String: String] = [:]
    public var deleted: [String: String] = [:]
    /// 收藏的 base 列表。放清单里而不是单开一个文件——
    /// 它和「已导入/已上传/已删除」是同一类账，一起读一起写不会打架。
    public var starred: [String] = []
    /// 上传**之前**定的标题与项目归属。
    ///
    /// 为什么只能在上传前定：录音链路产生的转写受 canonical 守卫保护，
    /// 事后改标题会 403。而 `POST /api/recordings` 本来就收 title 和 projectId——
    /// 建会话那一刻是唯一能定的时机，也正是有用的时刻：
    /// 刚开完会还记得这是什么，比事后在网页里对着一列时间戳猜要强。
    public var plan: [String: Plan] = [:]

    public struct Plan: Codable, Equatable, Sendable {
        public var title: String?
        public var projectId: String?
        public init(title: String? = nil, projectId: String? = nil) {
            self.title = title; self.projectId = projectId
        }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey { case imported, uploaded, deleted, starred, plan }

    /// 逐键容错解码：某一个键的结构变了（比如 Cleanup 换了 deleted 的写法），
    /// 不该把整份清单一起带走——那等于把「已导入」全忘光，下次会把设备里的东西重导一遍。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imported = (try? c.decode([String: Imported].self, forKey: .imported)) ?? [:]
        uploaded = (try? c.decode([String: String].self, forKey: .uploaded)) ?? [:]
        deleted = (try? c.decode([String: String].self, forKey: .deleted)) ?? [:]
        // 新增字段必须在这里补一行，否则「能写进去、重启后消失」——
        // 编译不报错，功能静默失效，最难查的那种。
        starred = (try? c.decode([String].self, forKey: .starred)) ?? []
        plan = (try? c.decode([String: Plan].self, forKey: .plan)) ?? [:]
    }

    public static func load(from url: URL) -> SyncManifest {
        guard let data = try? Data(contentsOf: url) else { return SyncManifest() }
        return (try? JSONDecoder().decode(SyncManifest.self, from: data)) ?? SyncManifest()
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        // sortedKeys 让 diff 稳定；withoutEscapingSlashes 对齐 Python 的 ensure_ascii=False 观感
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - 纯逻辑（可脱离蓝牙单测）

/// 去重、清单键、活动文件判定、列表合并。全是纯函数，不碰蓝牙也不碰磁盘，
/// 因为真机蓝牙在这台机器上跑不起来（TCC），这层必须能单独验证。
public enum SyncPlanner {

    /// 清单去重键。**必须与 pull.py 的 key_of() 逐字符一致**：
    ///   f"{entry.name}|{entry.time}|{entry.size}"
    /// 注意 entry.name 是列表里那个 20B 截断名，**结尾那个点要留着**
    /// （磁盘上真实的键长这样："note20260102-105203.|28|57240"）。
    /// 用 base 去点会让所有历史记录对不上，等于把整台设备重导一遍。
    public static func manifestKey(_ e: FileEntry) -> String {
        "\(e.name)|\(e.time)|\(e.size)"
    }

    /// 去掉扩展名和结尾的点，得到 note20260828-205856 这样的 base。
    /// pull.py 用的是 name.rstrip(".")，会去掉**所有**结尾的点，这里保持一致。
    public static func normalizedBase(_ s: String) -> String {
        var t = s
        for ext in [".opus", ".wav", ".ogg"] where t.lowercased().hasSuffix(ext) {
            t = String(t.dropLast(ext.count))
            break
        }
        while t.hasSuffix(".") { t = String(t.dropLast()) }
        return t
    }

    /// 正在录的那一条，绝对不能碰。
    ///
    /// 这是整个引擎最重要的一条闸。手动跑 pull.py 时人是知道自己在干嘛的；
    /// 自动同步不是——录音笔一边录一边广播，引擎就会去拉那个还在长的文件，
    /// 拿到一个腰斩的半截，然后用 "mac-ble-<base>" 这个幂等键推给深脑并 finalize。
    /// 深脑的清单一旦冻结就再也进不来新分片：等录完了想补，同一个 clientRequestId
    /// 只会拿回那个已完成的会话（DeepBrain.upload 里的 alreadyDone 分支），
    /// **完整录音永远进不去了**。这条路径此前已经真实炸过一次。
    ///
    /// - Parameters:
    ///   - status: 3-20 录音状态，1=录音中 2=未录音 3=暂停；取不到是 nil
    ///   - current: 3-24 当前文件名，取不到是 nil
    public static func isLive(_ e: FileEntry, status: UInt8?, current: String?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        // 状态取不到（nil）时按最坏情况处理：只要设备报了「当前文件」就当它在录。
        if let status, status != 1 && status != 3 { return false }
        return normalizedBase(current) == normalizedBase(e.name)
    }

    /// 本次要导的条目：清单里没有的 + 不是正在录的 + **本地还没有完整副本的**。
    ///
    /// 第三个条件是补上的。2026-08-29 出过一次：三条录音明明已经完整下到本地
    /// （裸包大小与设备报的一字节不差），清单却没记上账——于是每一轮都当成
    /// 「没导过」重下一遍，一整天在 30%→90%→30% 之间打转，一条都没进深脑。
    ///
    /// 清单写失败的原因可以再查，但**账本丢了不该让已经拿到手的文件重下**。
    /// 判据只认硬证据：本地裸包大小 == 设备报的大小，且能被 40 整除
    /// （40 B = 20 ms，除不尽就是截断）。差一个字节都按没下完处理——
    /// 宁可重下，也不能把半截录音当成完整的推上去。
    public static func pending(entries: [FileEntry], manifest: SyncManifest,
                               status: UInt8?, current: String?,
                               localRaw: [String: Int] = [:]) -> [FileEntry] {
        entries.filter { e in
            guard manifest.imported[manifestKey(e)] == nil else { return false }
            guard !isLive(e, status: status, current: current) else { return false }
            if let have = localRaw[normalizedBase(e.name)],
               have == Int(e.size), have % 40 == 0, have > 0 { return false }
            return true
        }
    }

    /// 一次下载算不算真的完整。
    ///
    /// 抽成纯函数是因为它是**安全关键**的：判错一次，半截录音就会冒充完整的推进深脑，
    /// 而本地看起来一切正常（2026-08-29 的三小时会议就是这么丢的）。
    /// 内联在下载循环里没法单测，出了事只能靠人肉复盘。
    public static func downloadComplete(got: Int, announced: UInt32) -> Bool {
        got > 0 && got == Int(announced) && got % 40 == 0
    }

    /// 本地已经有完整副本、但清单没记账的条目。补记用，不重下。
    public static func unrecorded(entries: [FileEntry], manifest: SyncManifest,
                                  status: UInt8?, current: String?,
                                  localRaw: [String: Int]) -> [FileEntry] {
        entries.filter { e in
            guard manifest.imported[manifestKey(e)] == nil else { return false }
            guard !isLive(e, status: status, current: current) else { return false }
            guard let have = localRaw[normalizedBase(e.name)] else { return false }
            return have == Int(e.size) && have % 40 == 0 && have > 0
        }
    }

    /// 设备列表 + 本地磁盘 + 清单 → 界面用的状态链。
    ///
    /// 用并集而不是只用设备列表：设备里删掉的老录音在本地和深脑里还在，
    /// 界面上不该凭空消失（[设备] 那一格空着就行）。
    public static func buildItems(entries: [FileEntry],
                                  manifest: SyncManifest,
                                  localOgg: [String: Int],
                                  rawOpus: [String: Int],
                                  status: UInt8?,
                                  current: String?,
                                  errors: [String: String],
                                  brain: [String: (status: String, transcript: String?, error: String?)],
                                  unconfirmed: [String: Int] = [:],
                                  titles: [String: String] = [:],
                                  uploadAttempts: [String: Int] = [:],
                                  plans: [String: SyncManifest.Plan] = [:],
                                  skippedShort: [String: Double] = [:],
                                  pendingDelete: Set<String> = [],
                                  starred: Set<String> = []) -> [RecordingItem] {
        var out: [String: RecordingItem] = [:]

        for e in entries {
            let base = normalizedBase(e.name)
            var item = RecordingItem(base: base, durationSec: Int(e.time), deviceSize: e.size)
            if isLive(e, status: status, current: current) { item.lastError = "录音中，本次跳过" }
            out[base] = item
        }

        for (base, bytes) in localOgg {
            var item = out[base] ?? RecordingItem(base: base, durationSec: 0)
            item.localBytes = bytes
            // 设备上已经没有的条目，时长只能从留档的裸包反推（40B = 20ms）
            if item.durationSec == 0, let raw = rawOpus[base] {
                item.durationSec = Int(OggWrap.durationSeconds(rawLength: raw))
            }
            out[base] = item
        }

        for (base, sid) in manifest.uploaded where out[base] != nil {
            out[base]?.sessionId = sid
            if let b = brain[base] {
                out[base]?.brainStatus = b.status
                out[base]?.transcriptId = b.transcript
                out[base]?.brainErrorCode = b.error
                // 失败要给人话，不是把裸错误码摆在界面上
                if b.status == "failed" {
                    out[base]?.lastError = BrainFailure.explain(b.error)
                }
                if let tid = b.transcript {
                    out[base]?.unconfirmedSpeakers = unconfirmed[tid] ?? 0
                    // 有标题就用标题。列表里「8月28日 22:41:52」认不出是哪场会。
                    if let t = titles[tid] { out[base]?.brainTitle = t }
                }
            } else {
                // 还没查过服务端状态。已经拿到会话 id 就至少是「在处理」，不是失败。
                out[base]?.brainStatus = "processing"
            }
        }

        for (base, n) in uploadAttempts where out[base] != nil { out[base]?.uploadAttempts = n }
        for (base, p) in plans where out[base] != nil {
            out[base]?.plannedTitle = p.title
            out[base]?.plannedProjectId = p.projectId
        }

        for (base, msg) in errors where out[base] != nil { out[base]?.lastError = msg }

        // 文件名就是时间戳，倒序即最新在前
        for base in out.keys {
            out[base]?.skippedShortSeconds = skippedShort[base]
            out[base]?.pendingDeviceDelete = pendingDelete.contains(base)
            out[base]?.starred = starred.contains(base)
        }
        return out.values.sorted { $0.base > $1.base }
    }
}

// MARK: - 进度节流

/// download 的进度回调跑在蓝牙队列上，一秒能来几百次。
/// 不节流就等于往主线程灌几百个 Task，界面会被自己的进度条卡死。
///
/// 加锁段单独抽成同步方法（admit），**绝不在 async 上下文里跨 await 持锁**——
/// BLEClient 里的 popPending / snapshotDiscovered 是同一个写法。
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var lastPct = -1
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval = 0.4) { self.minInterval = minInterval }

    /// 返回 nil 表示这一次不用报。
    func admit(_ pct: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard pct != lastPct, now.timeIntervalSince(last) >= minInterval else { return nil }
        last = now; lastPct = pct
        return pct
    }
}

// MARK: - 待推队列

/// 已落盘、还没进深脑的条目。
///
/// 队列不是纯内存的：真相来自磁盘（DEST 下有 .ogg 但 manifest.uploaded 里没有），
/// 所以 App 重启、断电、上传中途崩溃都不会丢掉「这条还欠深脑一次」。
/// 内存里只额外记退避信息。
public struct PendingUpload: Identifiable, Sendable {
    public var id: String { base }
    public let base: String
    public let oggBytes: Int
    public var attempts: Int = 0
    public var lastError: String?
    public var nextAttempt: Date = .distantPast
}

// MARK: - 引擎

@MainActor
public final class SyncEngine: ObservableObject, SyncEngineObserving {

    // MARK: 对界面暴露
    @Published public private(set) var device = DeviceInfo()
    @Published public private(set) var items: [RecordingItem] = []
    @Published public private(set) var phase: SyncPhase = .idle
    @Published public private(set) var lastRun: Date?
    @Published public private(set) var lastSummary: String = ""
    /// 监听循环是否在跑（跟 phase 分开：同步过程中 phase 不是 waitingForDevice，但监听仍然开着）
    @Published public private(set) var monitoring = false
    /// 已落盘、欠深脑的队列。上传失败不影响音频，只是排进这里等重试。
    @Published public private(set) var uploadQueue: [PendingUpload] = []
    /// 设备-账号绑定不一致，等着人确认（spec 019）。非 nil 时这支笔的同步全部拦下——
    /// 见 runSync 里的绑定检查。界面（DevicePage）据此显示确认卡片。
    @Published public private(set) var pendingBindMismatch: BindMismatch?
    /// base -> 文件后缀（ogg / m4a）。上传时要按它取文件和 mime。
    private var uploadExt: [String: String] = [:]

    // MARK: 配置
    public let paths: SyncPaths
    /// 同一台设备两次自动同步之间的冷却。刚同步完设备通常还在广播，
    /// 没有这道闸就会连上—断开—连上地空转。
    public var cooldown: TimeInterval
    /// 单次扫描窗口 / 两次扫描之间的间隔，见 monitorLoop 的注释。
    public var deviceNameHint: String

    // MARK: 内部状态
    private var client: BLEClient?
    /// 清理开关。默认关闭；改了立刻落盘，下次启动仍然有效。
    @Published public var cleanup = CleanupSettings() {
        didSet { cleanup.save(to: paths.cleanupSettings) }
    }

    private lazy var log = SyncLog(url: paths.syncLog)
    fileprivate var retryRounds: [String: Int] = [:]
    /// transcriptId -> 还没指认的说话人个数
    /// 因为太短而没推的：base -> 实际时长秒。界面上要说清楚是「按规则跳过」不是「失败」。
    /// 语音活动检测结果。只用于提示，不参与是否推送的决策。
    @Published public private(set) var voiceReports: [String: VoiceActivity.Report] = [:]
    private var skippedShort: [String: Double] = [:]
    /// 人手点了「从设备删除」但设备还没出现的，排队等着
    private var pendingDeviceDelete: Set<String> = []
    private var unconfirmedSpeakers: [String: Int] = [:]
    /// transcript_id -> 标题。与 unconfirmedSpeakers 同一轮批量拉。
    private var brainTitles: [String: String] = [:]
    private var brainPollTask: Task<Void, Never>?
    private var idleRounds: [String: Int] = [:]
    private var cleanupLoaded = false
    private var brain: DeepBrain?
    private var monitorTask: Task<Void, Never>?
    private var isSyncing = false
    /// 设备 id → 上次触发同步的时刻（冷却用）
    private var lastTriggered: [String: Date] = [:]
    /// base → 最近一次错误，喂给 items.lastError
    private var errors: [String: String] = [:]
    /// base → 深脑会话状态，只活在内存里（Python 版清单没有这两个字段，不往里加）
    private var brainState: [String: (status: String, transcript: String?, error: String?)] = [:]
    private var lastEntries: [FileEntry] = []
    private var lastStatus: UInt8?
    private var lastCurrent: String?

    public init(paths: SyncPaths = .default,
                cooldown: TimeInterval = 60,
                deviceNameHint: String = "CB08") {
        self.paths = paths
        self.cooldown = cooldown
        self.deviceNameHint = deviceNameHint
        refreshLocalView()
    }

    // MARK: - 开关

    /// 开始持续监听。幂等：重复调用不会起第二个循环。
    /// 从磁盘读回清理开关。init 里不能读（paths 还没定），所以放在 start 里。
    private func loadCleanupSettingsOnce() {
        guard !cleanupLoaded else { return }
        cleanupLoaded = true
        let loaded = CleanupSettings.load(from: paths.cleanupSettings)
        if loaded.deleteAfterSync != cleanup.deleteAfterSync
            || loaded.coolingDays != cleanup.coolingDays {
            cleanup = loaded
        }
    }

    public func start() {
        loadCleanupSettingsOnce()
        recoverStrandedRecordings()
        startBrainPolling()
        log.write("开始持续监听（广播流，冷却 \(Int(cooldown))s，自动清理 \(cleanup.deleteAfterSync ? "开" : "关")）")
        guard monitorTask == nil else { return }
        monitoring = true
        if phase == .idle { phase = .waitingForDevice }
        monitorTask = Task { [weak self] in await self?.monitorLoop() }
    }

    /// 停止监听。
    ///
    /// 故意做成「协作式」而不是硬取消：正在下载/上传时直接 cancel，
    /// BLEClient.nextFrame 里的 `try? await Task.sleep` 在取消态下会立刻返回，
    /// 那个 while 循环就变成空转跑满一个核，直到超时才退出。
    /// 所以只有在没同步时才真取消；正在同步就让它自己收尾。
    public func stop() {
        log.write("停止监听")
        brainPollTask?.cancel()
        brainPollTask = nil
        monitoring = false
        if !isSyncing {
            monitorTask?.cancel()
            monitorTask = nil
            if !isFailed(phase) { phase = .idle }
        }
    }

    /// 手动立刻同步一次。忽略冷却，但不会和正在跑的同步并发。
    public func syncNow() {
        guard !isSyncing else {
            lastSummary = "正在同步中，忽略这次手动触发"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // 手动触发给更长的扫描窗口：人按了按钮就是愿意多等几秒
            guard let target = await self.discover(seconds: 8) else {
                // 蓝牙这条路走不通，至少把欠深脑的补推掉——两件事本来就该解耦。
                // 先推再置 phase：flushUploadQueue 自己会收尾 phase，顺序反了会把 failed 冲掉。
                await self.flushUploadQueue()
                self.phase = .failed("没找到录音笔，确认已开机且未被手机 App 占用")
                self.lastSummary = "没找到录音笔"
                return
            }
            await self.runSync(target: target)
        }
    }

    /// 只补推，不碰蓝牙。等价于 pull.py --upload-only。
    public func retryUploads() {
        Task { [weak self] in await self?.flushUploadQueue(force: true) }
    }

    // MARK: - 监听循环

    /// 用「短扫描 + 短间隔」近似持续监听。
    ///
    /// 折中说明（重要）：BLEClient 目前只有 `scan(seconds:)`——开扫描、睡一段、停扫描、返回快照。
    /// 真正的持续监听应该是 delegate 回调式的：扫描一直开着，didDiscover 一来就推给上层。
    /// 现在用的是 BLEClient.advertisements() 广播流：设备一广播就收到，
    /// 不再有「扫一段/歇一段」的空窗。去重和冷却在这一层做。
    private func monitorLoop() async {
        // 用广播流而不是「扫 3 秒歇 2 秒」的轮询。
        //
        // 轮询有个结构性问题：录音笔空闲 7–8 分钟就停止广播，而两次扫描之间的空窗
        // 正好可能覆盖它醒着的那段。改成持续监听之后，它一广播我们就知道。
        //
        // 去重和冷却必须在这里做：流是「每响一次给一次」，同一台设备一秒可能来好几条。
        let client = ensureClient()
        client.onDisconnect = { [weak self] err in
            // 回调在蓝牙队列上，改 @Published 必须回主线程
            Task { @MainActor in
                guard let self else { return }
                self.device.connected = false
                self.log.write("设备意外断开" + (err.map { "：\($0.localizedDescription)" } ?? ""))
                if self.monitoring && !self.isSyncing { self.phase = .waitingForDevice }
            }
        }

        if phase == .idle { phase = .waitingForDevice }

        for await found in client.advertisements() {
            if !monitoring || Task.isCancelled { break }
            if isSyncing { continue }              // 正在同步就跳过，别断流
            if isFailed(phase) { phase = .waitingForDevice }
            guard let target = pick([found]), passedCooldown(target) else { continue }
            await runSync(target: target)
        }

        monitorTask = nil
        if monitoring == false && !isFailed(phase) && !isSyncing { phase = .idle }
    }

    private func pick(_ found: [Discovered]) -> Discovered? {
        if let hit = found.first(where: { $0.byService }) { return hit }
        let hint = deviceNameHint.lowercased()
        return found.first { $0.name.lowercased().contains(hint) }
    }

    /// 冷却判定。按设备 UUID 记，不按名字——同名设备不止一台时名字会张冠李戴。
    /// 空转退避：连着好几轮什么都没导也没推，就把重连间隔往后拖。
    ///
    /// 起因是真机日志里看到的：设备一直在手边时，引擎每 60 秒就重连一次，
    /// 一整天几百次连接——耗设备的电，还会挡住手机连它（BLE 从机同一时间只能连一个主机）。
    /// 有新东西就立刻把间隔打回 60 秒，所以"录完马上就同步"的体验不受影响。
    private static let idleBackoff: [TimeInterval] = [60, 120, 300, 600]

    private func currentCooldown(_ key: String) -> TimeInterval {
        let n = min(idleRounds[key] ?? 0, Self.idleBackoff.count - 1)
        return max(cooldown, Self.idleBackoff[n])
    }

    /// 一轮同步结束后调用：有产出就清零退避，没有就加一档。
    private func noteRoundOutcome(_ key: String, productive: Bool) {
        if productive {
            if (idleRounds[key] ?? 0) > 0 { log.write("有新内容，重连间隔打回 \(Int(cooldown))s") }
            idleRounds[key] = 0
        } else {
            let n = min((idleRounds[key] ?? 0) + 1, Self.idleBackoff.count - 1)
            idleRounds[key] = n
            if n < Self.idleBackoff.count {
                log.write("空转第 \(n) 轮，下次重连间隔 \(Int(Self.idleBackoff[n]))s")
            }
        }
    }

    private func passedCooldown(_ d: Discovered) -> Bool {
        let key = d.peripheral.identifier.uuidString
        if let t = lastTriggered[key],
           Date().timeIntervalSince(t) < currentCooldown(key) { return false }
        lastTriggered[key] = Date()
        return true
    }

    private func discover(seconds: TimeInterval) async -> Discovered? {
        guard let found = try? await ensureClient().scan(seconds: seconds, nameHint: deviceNameHint) else {
            return nil
        }
        guard let target = pick(found) else { return nil }
        lastTriggered[target.peripheral.identifier.uuidString] = Date()
        return target
    }

    // MARK: - 一次完整同步

    /// 连接 → 读设备信息 → 拉列表 → 只导没导过的 → 封 Ogg 落盘 → 推深脑 → 断开。
    /// 步骤顺序照 pull.py，**不含任何删除**。
    private func runSync(target: Discovered) async {
        isSyncing = true
        defer { isSyncing = false }

        do { try paths.ensureDirs() } catch {
            phase = .failed("建不了导入目录：\(describe(error))")
            return
        }

        let client = ensureClient()
        phase = .connecting
        device.name = target.name

        do {
            try await client.connect(target)
        } catch {
            device.connected = false
            phase = .failed(describe(error))
            lastSummary = "连接失败：\(describe(error))"
            log.write("连接失败：\(describe(error))")
            lastRun = Date()
            return
        }
        device.connected = true
        log.write("已连接 \(target.name) rssi=\(target.rssi)")
        // 无论中途从哪儿返回，都必须断开——不断开录音笔会一直被我们占着，
        // 手机 App 连不上，而且它也不会进入低功耗重新广播。
        defer {
            client.disconnect()
            device.connected = false
        }

        guard await ensureDeviceBinding(target) else { return }

        await readDeviceInfo(client)

        phase = .listing
        let entries: [FileEntry]
        let gotDone: Bool
        do {
            (entries, gotDone) = try await client.fileList()
        } catch {
            phase = .failed(describe(error))
            lastSummary = "读列表失败：\(describe(error))"
            log.write("读列表失败：\(describe(error))")
            lastRun = Date()
            return
        }
        lastEntries = entries
        refreshLocalView()

        var manifest = SyncManifest.load(from: paths.manifest)
        let rawOnDisk = scanLocal(paths.rawPackets, ext: "opus")

        // 先补账：本地已经有完整副本却没记上的，登记一下就行，别再下一遍。
        let recovered = SyncPlanner.unrecorded(entries: entries, manifest: manifest,
                                               status: lastStatus, current: lastCurrent,
                                               localRaw: rawOnDisk)
        if !recovered.isEmpty {
            for e in recovered {
                let b = SyncPlanner.normalizedBase(e.name)
                manifest.imported[SyncPlanner.manifestKey(e)] = SyncManifest.Imported(
                    file: "\(b).ogg", bytes: rawOnDisk[b] ?? 0, at: Self.stamp(Date()))
            }
            try? manifest.save(to: paths.manifest)
            log.write("补记 \(recovered.count) 条：本地已有完整副本但清单没记账，"
                      + recovered.map { SyncPlanner.normalizedBase($0.name) }.joined(separator: "、"))
        }

        let todo = SyncPlanner.pending(entries: entries, manifest: manifest,
                                       status: lastStatus, current: lastCurrent,
                                       localRaw: rawOnDisk)
        let skipped = entries.count - todo.count

        var imported = 0
        for e in todo {
            let base = SyncPlanner.normalizedBase(e.name)
            errors[base] = nil
            let throttle = ProgressThrottle()
            phase = .downloading(base, 0)

            let res: BLEClient.DownloadResult
            do {
                res = try await client.download(
                    candidates: e.candidates, expectSize: e.size,
                    onProgress: { [weak self] got, expect in
                        guard let expect, expect > 0 else { return }
                        let pct = min(100, Int(Double(got) / Double(expect) * 100))
                        guard let p = throttle.admit(pct) else { return }
                        // 回调在蓝牙队列上，@Published 只能在主线程改
                        Task { @MainActor in self?.phase = .downloading(base, p) }
                    })
            } catch {
                errors[base] = describe(error)
                refreshLocalView()
                continue
            }

            guard res.ok else {
                let why = res.endCode.flatMap { Proto.importEndMeaning[$0] }
                    ?? res.endCode.map { "结束码 \($0)" } ?? "无应答"
                errors[base] = "下载失败：\(why)（试过 \(res.tried.joined(separator: "、"))）"
                // 失败必须留痕。以前这条路径一行日志都不写，而「同步结束」只在整轮
                // 跑完时才写——于是一条反复下载失败的录音，在日志里**完全不存在**，
                // 只能靠盯着界面上的百分比来回跳才发现。查了半天就是因为这个。
                log.write(String(format: "下载失败 %@：%@ 拿到 %d/%@ B 续传%d次 %.0fs",
                                 base, why, res.data.count,
                                 String(e.size), res.resumes, res.seconds))
                refreshLocalView()
                continue
            }

            // 设备说「传完了」不等于真传完了。
            //
            // 2026-08-29 的实事：这条 3 小时录音只收到 7,200,666 字节（应有 21,602,000），
            // 设备照样回了 endCode 0，于是 `res.ok` 为真、文件落盘、上传把它当成完整录音推走，
            // 时长按裸包算出 3600.333 秒——服务端 ffmpeg 一比对就报 OUTPUT_INVALID，
            // 而本地看起来一切正常。一条三小时的会议就这么没进深脑。
            //
            // 所以这里加一道硬闸：**收到的字节必须与设备报的大小一字不差**，
            // 且能被 40 整除（40 B = 20 ms 一包，除不尽就是截断在半包上）。
            // 对不上就当失败重下，绝不落盘——宁可重来，也不能让半截录音冒充完整的。
            let want = Int(e.size)
            if !SyncPlanner.downloadComplete(got: res.data.count, announced: e.size) {
                let pct = want > 0 ? Double(res.data.count) / Double(want) * 100 : 0
                errors[base] = String(format: "只收到 %d/%d 字节（%.1f%%），设备却报了完成——按未完成处理",
                                      res.data.count, want, pct)
                log.write(String(format: "下载不完整 %@：收到 %d/%d 字节（%.1f%%）续传%d次，丢弃重来",
                                 base, res.data.count, want, pct, res.resumes))
                refreshLocalView()
                continue
            }

            // 落盘。裸包先留档，再封 Ogg——顺序反了的话封装崩了就什么都没留下。
            let outName: String
            do {
                try Data(res.data).write(to: paths.rawPackets
                    .appendingPathComponent("\(base).opus"), options: .atomic)
                if OggWrap.looksRaw(res.data) {
                    let ogg = try OggWrap.wrap(res.data)
                    try Data(ogg).write(to: paths.dest
                        .appendingPathComponent("\(base).ogg"), options: .atomic)
                    outName = "\(base).ogg"
                } else {
                    // 设备直接吐了成品（比如 wav），原样落，不去猜它的格式
                    try Data(res.data).write(to: paths.dest
                        .appendingPathComponent(res.filename), options: .atomic)
                    outName = res.filename
                }
            } catch {
                errors[base] = "落盘失败：\(describe(error))"
                refreshLocalView()
                continue
            }

            // 落盘即记账：清单立刻写回磁盘，不等这一轮全部跑完。
            // 中途拔电/崩溃时，已经拿到手的文件不该被下次当成「没导过」重导一遍。
            manifest = SyncManifest.load(from: paths.manifest)   // 重读：Cleanup 可能刚写过 deleted
            manifest.imported[SyncPlanner.manifestKey(e)] = SyncManifest.Imported(
                file: outName, bytes: res.data.count, at: Self.stamp(Date()))
            try? manifest.save(to: paths.manifest)
            imported += 1
            log.write("导入 \(outName) \(res.data.count)B \(String(format: "%.1f", res.kbps))KB/s"
                      + (res.resumes > 0 ? " 续传\(res.resumes)次" : ""))
            // 顺带做一次语音活动检测。**只记录不拦截**：
            // 判据只在 8 个样本上验过，最接近阈值的那条离阈值 1.7 倍。
            // 攒够几十条之前，宁可让人看见"我认为这条是噪音"，也不替他做决定。
            if outName.hasSuffix(".ogg") {
                let vURL = paths.dest.appendingPathComponent(outName)
                let b = base
                // 先把 log 取出来：lazy var 在并发闭包里访问会触发 self 捕获告警
                let logger = log
                Task.detached(priority: .utility) { [weak self] in
                    guard let r = VoiceActivity.analyze(audio: vURL) else { return }
                    if !r.isLikelySpeech {
                        logger.write("语音检测：\(b) 疑似没有人声——\(r.reason)（仅记录，未拦截）")
                    }
                    await MainActor.run { [weak self] in self?.voiceReports[b] = r }
                }
            }

            // 导入时就把波形算好。Opus 解码 12 分钟要三秒多，等用户点开再算就是干等；
            // 而这会儿他本来就在等同步，多花三秒无感。
            if outName.hasSuffix(".ogg") {
                let audioURL = paths.dest.appendingPathComponent(outName)
                let root = paths.root
                Task.detached(priority: .utility) {
                    _ = Waveform.load(base: base, audio: audioURL, root: root)
                }
            }
            refreshLocalView()
        }

        // 推深脑放在蓝牙之后：下载和上传解耦，上传慢/失败都不该占着录音笔的连接。
        // 但深脑要网络，断开蓝牙再推更稳，所以这里只把队列刷一遍，
        // 队列本身是从磁盘推导的，包含这一轮刚落盘的和历史欠的。
        let uploaded = await flushUploadQueue()

        // 清理放在推深脑之后、断开蓝牙之前。本轮刚上传的不会被本轮删掉——
        // 深脑那时还没转写完，闸 A 就挡住了；冷静期默认 3 天，本来也轮不到它。
        // 人手排队的删除优先于自动清理执行——人的意愿不该排在规则后面。
        var cleanNote = ""
        let manualDeleted = await runPendingDeletes(client: client, entries: entries,
                                                    recordStatus: device.recordStatus)
        if manualDeleted > 0 { cleanNote = "按你的要求删了 \(manualDeleted) 条" }

        if cleanup.deleteAfterSync {
            phase = .cleaning
            let r = await performCleanup(client: client, entries: entries,
                                         recordStatus: device.recordStatus,
                                         deviceCurrent: lastCurrent,
                                         brain: brain, settings: cleanup)
            if !r.note.isEmpty {
                cleanNote += (cleanNote.isEmpty ? "" : "，") + r.note
                log.write("清理：\(r.note)")
            }
            if r.deleted > 0 { refreshLocalView() }
        }

        lastRun = Date()
        var parts: [String] = []
        if imported > 0 { parts.append("导入 \(imported) 条") }
        if skipped > 0 { parts.append("跳过 \(skipped) 条已导") }
        if uploaded > 0 { parts.append("入深脑 \(uploaded) 条") }
        if parts.isEmpty { parts.append("没有新录音（设备内 \(entries.count) 条）") }
        if !cleanNote.isEmpty { parts.append(cleanNote) }
        if !gotDone { parts.append("列表未收到 2-18，按空闲收尾") }
        if let live = lastCurrent, !live.isEmpty { parts.append("\(SyncPlanner.normalizedBase(live)) 录音中已跳过") }
        lastSummary = parts.joined(separator: "，")
        log.write("同步结束：\(lastSummary)")
        // 归档刚发生变化的时刻做体检，代价 0.2 秒，等于白送。
        // 深脑 30 天后清音频，问题必须在那之前被发现。
        if imported > 0 { _ = runArchiveAudit() }
        // 只在真有产出时通知。没新东西也弹一下，几天之后你就会把通知关掉。
        if imported > 0 || uploaded > 0 || !cleanNote.isEmpty {
            Notify.send(lastSummary)
        }
        noteRoundOutcome(target.peripheral.identifier.uuidString,
                         productive: imported > 0 || uploaded > 0)
        phase = monitoring ? .waitingForDevice : .idle
    }

    /// 电量低提醒的阈值和状态。
    /// 只在「跨过阈值那一次」提醒，不是每次同步都喊——喊多了就没人听了。
    private static let lowBatteryThreshold: UInt8 = 20
    private var warnedLowBattery = false

    private func checkBattery(_ level: UInt8?) {
        guard let level, level != 110 else { warnedLowBattery = false; return }  // 110 = 充电中
        if level <= Self.lowBatteryThreshold {
            if !warnedLowBattery {
                warnedLowBattery = true
                log.write("录音笔电量 \(level)%，偏低")
                Notify.send("录音笔只剩 \(level)% 电，出门前记得充", title: "电量偏低")
            }
        } else if level > Self.lowBatteryThreshold + 10 {
            warnedLowBattery = false          // 回滞：充上去一截才复位，免得在阈值上下反复喊
        }
    }

    private func readDeviceInfo(_ client: BLEClient) async {
        device.battery = (try? await client.battery()) ?? nil
        checkBattery(device.battery)
        device.firmware = (try? await client.firmware()) ?? nil
        device.gain = (try? await client.gain()) ?? nil
        device.recordStatus = (try? await client.recordStatus()) ?? nil
        if let cap = (try? await client.capacity()) ?? nil {
            device.capacityRemain = cap.remain
            device.capacityTotal = cap.total
        }
        lastStatus = device.recordStatus
        lastCurrent = (try? await client.currentFilename()) ?? nil
    }

    // MARK: - 待推队列

    /// 从磁盘重建队列：DEST 下有 .ogg、manifest.uploaded 里没有的，就是欠深脑的。
    /// 已有的退避信息（尝试次数、下次时间）保留下来，不会因为重建被抹平。
    private func rebuildUploadQueue(_ manifest: SyncManifest, local: [String: (bytes: Int, ext: String)]) {
        let old = Dictionary(uniqueKeysWithValues: uploadQueue.map { ($0.base, $0) })
        uploadExt = local.mapValues(\.ext)
        uploadQueue = local.keys
            .filter { manifest.uploaded[$0] == nil }
            .sorted()
            .map { base in
                let prev = old[base]
                return PendingUpload(base: base, oggBytes: local[base]?.bytes ?? 0,
                                     attempts: prev?.attempts ?? 0,
                                     lastError: prev?.lastError,
                                     nextAttempt: prev?.nextAttempt ?? .distantPast)
            }
    }

    /// 把队列里到点的条目推给深脑。返回本次成功的条数。
    ///
    /// 失败只记在队列上，**不动已落盘的音频**——音频已经安全了，
    /// 上传是可以无限重试的另一件事（幂等键保证重试不会建重复会话）。
    @discardableResult
    private func flushUploadQueue(force: Bool = false) async -> Int {
        var manifest = SyncManifest.load(from: paths.manifest)
        rebuildUploadQueue(manifest, local: scanUploadable(paths.dest))
        guard !uploadQueue.isEmpty else { refreshLocalView(); return 0 }

        guard let brain = await ensureBrain() else {
            lastSummary = "深脑未接通，本次只落盘（先用 Python 版登录）"
            refreshLocalView()
            return 0
        }

        let rawSizes = scanLocal(paths.rawPackets, ext: "opus")
        let now = Date()
        var ok = 0
        for (idx, job) in uploadQueue.enumerated() {
            guard force || job.nextAttempt <= now else { continue }
            let base = job.base
            let ext = uploadExt[base] ?? "ogg"
            let url = paths.dest.appendingPathComponent("\(base).\(ext)")
            guard var data = try? Data(contentsOf: url) else { continue }

            // 录音笔有 3 小时上限，到点自动断开、隔 1 秒开下一条。
            // 一场三个半小时的会因此变成两条，在深脑里成了两场互不相干的会——
            // 说话人各认一遍、洞察各出一份、承诺分散在两处。
            //
            // 设备的切分是**它的**限制，不是内容的事实，不该让下游每一层都去理解。
            // 所以在推上去之前就拼回一条：裸包是定长 40 字节的 opus 帧，
            // 首尾相接即合法，零损耗、不重编码。
            var mergedBases: [String] = [base]
            if ext == "ogg" {
                let ordered = rawSizes.keys.sorted()
                var cursor = base
                while let nextBase = ordered.first(where: { $0 > cursor
                        && Continuation.isContinuation(
                            prevBase: cursor,
                            prevSeconds: OggWrap.durationSeconds(rawLength: rawSizes[cursor] ?? 0),
                            nextBase: $0) }) {
                    mergedBases.append(nextBase)
                    cursor = nextBase
                }
            }
            if mergedBases.count > 1 {
                let raws = mergedBases.compactMap { b -> [UInt8]? in
                    (try? Data(contentsOf: paths.rawPackets.appendingPathComponent("\(b).opus")))
                        .map { [UInt8]($0) }
                }
                // 少一段就整个不合——宁可分开推，也不能拼出一条缺了中间的时间线。
                if raws.count == mergedBases.count,
                   let joined = Continuation.concatRawPackets(raws),
                   let ogg = try? OggWrap.wrap(joined) {
                    data = Data(ogg)
                    log.write("合并 \(mergedBases.count) 段（录音笔 3 小时上限切开的同一场）："
                              + mergedBases.joined(separator: " + "))
                } else {
                    mergedBases = [base]
                    log.write("放弃合并 \(base)：有段落缺失或长度不合，按单条推")
                }
            }
            // 时长各按各的来源算，别混：
            //   · ogg 来自录音笔，裸包长度换算最准（40B = 20ms）；封装后带页头，按字节算会偏。
            //   · m4a 是本机录的，AAC 是变码率，字节数换算毫无意义——直接读文件。
            let duration: Double
            if ext == "m4a" {
                duration = AudioTranscode.duration(of: url) ?? 0
            } else if mergedBases.count > 1 {
                // 合并之后时长是各段之和，不能再用单条的裸包大小
                duration = mergedBases.reduce(0.0) {
                    $0 + OggWrap.durationSeconds(rawLength: rawSizes[$1] ?? 0)
                }
            } else {
                duration = rawSizes[base].map { OggWrap.durationSeconds(rawLength: $0) }
                    ?? OggWrap.durationSeconds(rawLength: data.count)
            }
            // 时长算不出来就别推：服务端拿它做 manifest 校验，0 会被判成非法。
            guard duration > 0 else { continue }

            // 太短的只落盘不推：花钱的是转写和分析，不是下载。
            // force=true（人手点「推送」）时忽略这道门槛——你说要推就是要推。
            let floor = cleanup.minUploadSeconds
            if !force, floor > 0, duration < Double(floor) {
                if skippedShort[base] == nil {
                    skippedShort[base] = duration
                    log.write(String(format: "%@ 只有 %.0f 秒，短于 %d 秒门槛，只落盘不推深脑",
                                     base, duration, floor))
                }
                continue
            }
            skippedShort[base] = nil

            phase = .uploading(base, "准备")
            do {
                let up = try await brain.upload(
                    audio: [UInt8](data),
                    // 上传前定过名字就用它，没定就用文件名
                    title: manifest.plan[base]?.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? base,
                    durationSec: duration,
                    // 幂等键必须与 Python 版一模一样，否则两边会各建一个会话。
                    // 前缀区分来源：录音笔来的是 mac-ble，本机录的是 mac-mic，
                    // 否则同名文件会撞成同一个会话。
                    clientRequestId: "\(ext == "m4a" ? "mac-mic" : "mac-ble")-\(base)"
                        + (mergedBases.count > 1 ? "-merged\(mergedBases.count)" : ""),
                    mime: ext == "m4a" ? "audio/mp4" : "audio/ogg",
                    // 真实录音时刻，不是上传时刻
                    startedAt: Continuation.startedAt(base: base),
                    projectId: manifest.plan[base]?.projectId,
                    onStep: { [weak self] step in
                        Task { @MainActor in self?.phase = .uploading(base, step) }
                    })
                manifest = SyncManifest.load(from: paths.manifest)
                // 合并推上去的话，**每一段**都要记同一个会话 id。
                // 只记第一段的话，后面那段下一轮会被当成没推过、再单独推一遍——
                // 同一段音频在深脑里出现两次，一次在合并的会里、一次自己一条。
                for b in mergedBases {
                    manifest.uploaded[b] = up.sessionId
                    errors[b] = nil
                    brainState[b] = ("processing", nil, nil)
                }
                try? manifest.save(to: paths.manifest)
                log.write("推深脑 \(mergedBases.joined(separator: "+")) 会话 \(up.sessionId)"
                          + (up.alreadyDone ? "（幂等重放，未重传）" : ""))
                ok += 1
            } catch {
                var job = uploadQueue[idx]
                job.attempts += 1
                job.lastError = describe(error)
                // 指数退避，封顶 30 分钟。深脑那头可能是网络抖动，也可能是登录过期，
                // 后者重试再快也没用，别把日志刷爆。
                let delay = min(1800, 30 * pow(2, Double(job.attempts - 1)))
                job.nextAttempt = Date().addingTimeInterval(delay)
                uploadQueue[idx] = job
                errors[base] = "推深脑失败（第 \(job.attempts) 次）：\(job.lastError ?? "")"
                log.write("推深脑失败 \(base) 第\(job.attempts)次：\(job.lastError ?? "")"
                          + "，\(Int(delay))s 后重试")
            }
        }

        await refreshBrainStatus(manifest)
        rebuildUploadQueue(manifest, local: scanUploadable(paths.dest))
        refreshLocalView()
        // 单独补推（retryUploads）时没人接手 phase，得自己收回来，
        // 否则界面会永远停在「推送 xxx」上。runSync 里会再覆盖一次，无害。
        if case .uploading = phase { phase = monitoring ? .waitingForDevice : .idle }
        return ok
    }

    /// 已经到终点的不用再查：转写好了，或者明确失败了。
    private func isTerminal(_ s: (status: String, transcript: String?, error: String?)?) -> Bool {
        guard let s else { return false }
        if s.status == "ready", s.transcript != nil { return true }
        return s.status == "failed" || s.status == "deleted"
    }

    /// 查一下已推条目在深脑那边处理到哪了。查不到不算错，界面上就停在「处理中」。
    private func refreshBrainStatus(_ manifest: SyncManifest, limit: Int = 12) async {
        guard let brain = await ensureBrain() else { return }
        let todo = manifest.uploaded
            .filter { !isTerminal(brainState[$0.key]) }
            .sorted { $0.key > $1.key }
            .prefix(limit)
        guard !todo.isEmpty else { return }
        for (base, sid) in todo {
            guard let st = try? await brain.sessionState(sid) else { continue }
            brainState[base] = (st.status, st.transcriptId, st.errorCode)
        }
        // 顺带批量拉一次「还没指认的说话人」——待办区靠它判断要不要认人。
        // 放在这里而不是单独一轮：本来就已经连着深脑了，省一次往返。
        let tids = brainState.values.compactMap { $0.transcript }
        if !tids.isEmpty, let counts = try? await brain.unconfirmedSpeakerCounts(transcriptIds: tids) {
            unconfirmedSpeakers = counts
        }
        // 标题走同一轮。原来只有「点开某条」才查一条，于是列表里永远是时间戳。
        if !tids.isEmpty, let ts = try? await brain.transcriptTitles(tids) {
            brainTitles = ts
        }
        refreshLocalView()
    }

    /// 独立于蓝牙的深脑状态轮询。
    ///
    /// 必须独立：转写要几十秒到几分钟，那时候录音笔早断开了，而原来的刷新只挂在同步流程里，
    /// 结果就是界面永远停在「分析中」——连已经失败的也显示成分析中，把问题盖住了。
    private func startBrainPolling() {
        brainPollTask?.cancel()
        brainPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshBrainStatus(SyncManifest.load(from: self.paths.manifest))
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    // MARK: - 视图刷新

    /// 磁盘 + 清单 + 内存态 → items。每次状态变化都重算，保证界面和磁盘不会各说各话。
    private func refreshLocalView() {
        let manifest = SyncManifest.load(from: paths.manifest)
        let localOgg = scanLocal(paths.dest, ext: "ogg")
        let rawOpus = scanLocal(paths.rawPackets, ext: "opus")
        items = SyncPlanner.buildItems(entries: lastEntries, manifest: manifest,
                                       localOgg: localOgg, rawOpus: rawOpus,
                                       status: lastStatus, current: lastCurrent,
                                       errors: errors, brain: brainState, unconfirmed: unconfirmedSpeakers,
                                       titles: brainTitles,
                                       uploadAttempts: Dictionary(
                                           uploadQueue.map { ($0.base, $0.attempts) },
                                           uniquingKeysWith: { a, _ in a }),
                                       plans: manifest.plan,
                                       skippedShort: skippedShort, pendingDelete: pendingDeviceDelete,
                                       starred: Set(SyncManifest.load(from: paths.manifest).starred))
    }

    /// 目录下某扩展名的文件：base → 字节数。
    /// 补转落单的录音。
    ///
    /// 本机录音是「录成 caf → 转成 m4a → 进队列」三步。中间那步可能没跑成：
    /// App 在转码前被关掉、转码那一版还没做出来、或者转码本身失败。
    /// 结果是磁盘上躺着一个 caf，队列里什么都没有，界面上这条录音等于**不存在**——
    /// 人录了七秒钟，以为存下来了。
    ///
    /// 这确实发生过（2026-08-29，一条 6.9 秒的 caf 搁浅了一下午）。所以启动时扫一遍，
    /// 有 caf 没同名 m4a 的就补转。转码不删源文件，补转失败也只是维持原状，不会更糟。
    private func recoverStrandedRecordings() {
        let cafs = scanLocal(paths.dest, ext: "caf")
        guard !cafs.isEmpty else { return }
        let done = scanLocal(paths.dest, ext: "m4a")
        let stranded = cafs.keys.filter { done[$0] == nil }
        guard !stranded.isEmpty else { return }
        Task.detached(priority: .utility) { [paths, log] in
            for base in stranded.sorted() {
                let src = paths.dest.appendingPathComponent("\(base).caf")
                do {
                    let out = try AudioTranscode.toM4A(src)
                    try? FileManager.default.removeItem(at: src)
                    log.write(String(format: "补转搁浅录音 %@ → m4a（%.1f 秒）", base, out.seconds))
                } catch {
                    log.write("补转 \(base) 失败：\(error)——原始 caf 留着")
                }
            }
        }
    }

    /// 本机可上传的音频：录音笔来的是 .ogg，Mac 自己录的转码后是 .m4a。
    ///
    /// 之前这里只扫 .ogg，于是 Mac 录的音永远进不了上传队列——
    /// 录音功能看起来做完了，实际推不上去。
    /// 同名同时存在时以 .m4a 为准（它是转码产物，ogg 不会和它同名）。
    private func scanUploadable(_ dir: URL) -> [String: (bytes: Int, ext: String)] {
        var out: [String: (bytes: Int, ext: String)] = [:]
        for ext in ["ogg", "m4a"] {
            for (base, bytes) in scanLocal(dir, ext: ext) { out[base] = (bytes, ext) }
        }
        return out
    }

    private func scanLocal(_ dir: URL, ext: String) -> [String: Int] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: Int] = [:]
        for n in names where n.lowercased().hasSuffix(".\(ext)") {
            let base = String(n.dropLast(ext.count + 1))
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size])
                .flatMap { $0 as? NSNumber }?.intValue ?? 0
            out[base] = size
        }
        return out
    }

    // MARK: - 杂项

    /// BLEClient 一实例化就会触发蓝牙权限检查，所以按需创建：
    /// 只补推深脑（retryUploads）时不该被蓝牙权限拖累。
    private func ensureClient() -> BLEClient {
        if let client { return client }
        let c = BLEClient()
        client = c
        return c
    }

    /// 深脑接不通不是致命错误——照 pull.py 的做法，落盘照做，只是不推。
    private func ensureBrain() async -> DeepBrain? {
        if let brain { return brain }
        guard let cfg = try? DeepBrainConfig.load(from: paths.deepBrainConfig) else { return nil }
        let b = DeepBrain(config: cfg)
        guard (try? await b.connect()) != nil else { return nil }
        brain = b
        return b
    }

    // MARK: - 设备-账号绑定（spec 019）

    /// 这支笔（按 CoreBluetooth peripheral UUID 认）该不该跟当前账号同步。
    ///
    /// 返回 false 表示整轮同步就此打住——**不下载、不推送**。这是
    /// 2026-09-03 事故之后补的闸：那次账号登错了，同步在没人看一眼的
    /// 情况下自己跑完，三份录音笔文件静默进了错账号。这道闸挡在下载
    /// 之前，比只挡上传更彻底：连本地磁盘都不会沾上放错地方的录音。
    ///
    /// 没绑过的笔（第一次连上）**不需要人手确认**：既然还没绑过，
    /// 就没有"这次跟上次不一致"的风险，直接绑给当前账号、起个默认名字。
    /// 需要人手确认的只有"绑过、且绑的不是当前账号"这一种情况。
    private func ensureDeviceBinding(_ target: Discovered) async -> Bool {
        guard let brain = await ensureBrain() else {
            phase = .failed("深脑未接通，无法确认这支笔该同步进哪个账号（请先登录）")
            lastRun = Date()
            return false
        }
        let peripheralId = target.peripheral.identifier.uuidString
        let currentOrg = brain.org ?? ""
        let currentEmail = DeepBrain.signedInEmail ?? "当前账号"

        if let bound = DeviceBinding.binding(for: peripheralId) {
            if bound.orgId == currentOrg { return true }
            pendingBindMismatch = BindMismatch(
                peripheralId: peripheralId, deviceName: target.name,
                previousEmail: bound.email, currentEmail: currentEmail)
            phase = .failed("「\(target.name)」上次同步到「\(bound.email)」，"
                            + "现在登录的是「\(currentEmail)」——打开「设备」页确认后才会继续同步")
            log.write("拦下同步：\(target.name) 绑定的账号跟当前登录的不一致，等待人手确认")
            lastRun = Date()
            Notify.send("「\(target.name)」上次绑的是别的账号，打开深脑确认后才会继续同步",
                       title: "深脑 · 需要确认")
            return false
        }

        // 第一次见这支笔：不用弹窗打断，直接绑给当前账号——这本来就是"对"的账号，
        // 没有需要人确认的风险。名字随手起一个，用户想改的话去「设备」页改。
        let defaultName = "\(target.name)-\(Host.current().localizedName ?? "Mac")"
        if await bindDevice(peripheralId, orgId: currentOrg, email: currentEmail,
                            deviceNo: defaultName, brain: brain) {
            log.write("首次绑定「\(target.name)」到当前账号「\(currentEmail)」，命名为「\(defaultName)」")
            return true
        }
        // 撞名重试一次（同一台 Mac 主机名 + 设备名组合被占，概率很低但不是零）。
        let retryName = "\(defaultName)-\(Int.random(in: 100...999))"
        if await bindDevice(peripheralId, orgId: currentOrg, email: currentEmail,
                            deviceNo: retryName, brain: brain) {
            log.write("首次绑定「\(target.name)」到当前账号「\(currentEmail)」，命名为「\(retryName)」（原名字被占用）")
            return true
        }
        // 绑定登记失败不是"账号不对"的安全风险，只是元数据没记上——
        // 不该因为这个把一支笔本该正常的同步卡住，下次连接会自然重试。
        log.write("绑定「\(target.name)」失败：重试后仍冲突，本轮跳过绑定但照常同步")
        return true
    }

    private func bindDevice(_ peripheralId: String, orgId: String, email: String,
                            deviceNo: String, brain: DeepBrain) async -> Bool {
        guard case .ok = await brain.selfRegisterDevice(provider: "cb08", deviceNo: deviceNo) else {
            return false
        }
        DeviceBinding.bind(peripheralId, orgId: orgId, email: email, deviceNo: deviceNo)
        return true
    }

    /// 界面调用：账号不匹配警告里用户点了「继续」——把这支笔重新绑给当前账号。
    ///
    /// **不是原地改绑**：旧的 `(provider, device_no)` 还在前一个账号名下（数据库
    /// 唯一约束不允许跨账号复用同一个名字），所以这里用一个新名字重新走一遍
    /// 自助绑定，而不是尝试"转移"旧的那一条——前一个账号已经同步过的内容
    /// 完全不受影响，见确认弹窗里的措辞。
    public func resolveBindMismatch(newDeviceName: String) async -> Bool {
        guard let mismatch = pendingBindMismatch else { return false }
        guard let brain = await ensureBrain() else { return false }
        let currentOrg = brain.org ?? ""
        let currentEmail = DeepBrain.signedInEmail ?? "当前账号"
        let name = newDeviceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        guard await bindDevice(mismatch.peripheralId, orgId: currentOrg, email: currentEmail,
                               deviceNo: name, brain: brain) else { return false }
        log.write("确认换绑「\(mismatch.deviceName)」到「\(currentEmail)」，命名为「\(name)」")
        pendingBindMismatch = nil
        if isFailed(phase) { phase = .waitingForDevice }
        return true
    }

    /// 界面调用：账号不匹配警告里用户点了「取消」——保持原样，这支笔这次不同步。
    public func dismissBindMismatch() {
        pendingBindMismatch = nil
    }

    private func isFailed(_ p: SyncPhase) -> Bool {
        if case .failed = p { return true }
        return false
    }

    /// 错误文案。故意逐个列已知类型，而不是 `e as? CustomStringConvertible`——
    /// 后者对任何 Error 都恒成立（编译器会警告），拿到的却是 NSError 的默认描述，
    /// 反而把 BLEError / DeepBrainError 精心写的中文原因盖掉了。
    private func describe(_ e: Error) -> String {
        switch e {
        case let e as BLEError: return e.description
        case let e as DeepBrainError: return e.description
        case let e as Proto.ProtoError: return e.description
        default: return e.localizedDescription
        }
    }

    /// 与 Python 版 time.strftime("%Y-%m-%d %H:%M:%S") 一致。
    /// 用 en_US_POSIX 固定住格式，否则中文区会冒出「上午/下午」。
    nonisolated static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - BLEClient 改造备忘

/// BLEClient 还剩一条没做的改造。
///
/// 现在的长扫描是 `withServices: nil`——为了兼容广播里不带 AE20 的固件。代价是：
/// 附近 BLE 设备多时会把它们全捞进来白烧 CPU；而且 **App 进后台时 nil 扫描会被系统忽略**，
/// 只有限定服务 UUID 的扫描后台才生效。菜单栏常驻应用迟早撞上这一条。
///
/// 正解是双通道：限定服务的长扫描 + 偶尔一次 nil 兜底短扫。属于调度设计，值得单独一轮做。
///
/// （其余四条——广播流、AllowDuplicates、断连回调、disconnect 竞态——都已落地。）
public enum BLEClientUpgradeNotes {}

// MARK: - 设备清理

/// 清理开关。默认关闭——删除不可逆，必须由人明确打开。
public struct CleanupSettings: Codable, Sendable {
    public var deleteAfterSync: Bool = false
    public var coolingDays: Int = 3

    /// 短于这个时长的录音**只落盘、不推深脑**。默认 5 分钟。
    ///
    /// 为什么是"不推"而不是"不下载"：下载几乎不花钱（BLE 三十秒），
    /// 花钱的是转写和分析。本地留一份，随时能试听、想推时一键推；
    /// 而"不下载"会让你彻底失去它——等哪天想起"那段挺重要"就晚了。
    /// 设为 0 表示不过滤。
    public var minUploadSeconds: Int = 300

    public static func load(from url: URL) -> CleanupSettings {
        (try? JSONDecoder().decode(CleanupSettings.self, from: Data(contentsOf: url)))
            ?? CleanupSettings()
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public extension SyncPaths {
    var cleanupSettings: URL { root.appendingPathComponent("out/swift-settings.json") }
}

public extension SyncEngine {

    /// 同步完成后的清理。六道闸全过才删，逐个删且每删一个重拉列表确认。
    ///
    /// 时机说明：这一步跑在推深脑之后、断开蓝牙之前。本轮刚上传的录音**不会**在本轮被删——
    /// 深脑那时还没转写完（status 不是 ready），闸 A 就把它挡住了。这不是缺陷：
    /// 冷静期默认 3 天，本来也轮不到它。
    func performCleanup(client: BLEClient, entries: [FileEntry],
                        recordStatus: UInt8?, deviceCurrent: String?,
                        brain: DeepBrain?, settings: CleanupSettings) async -> (deleted: Int, note: String) {
        guard settings.deleteAfterSync else { return (0, "") }
        guard let brain else { return (0, "清理跳过：没接通深脑，无法确认是否已同步") }

        let manifest = SyncManifest.load(from: paths.manifest)
        let planner = Cleanup.Planner(lookup: { [weak brain] sid in
            guard let brain else { return nil }
            return try await brain.sessionState(sid)
        })
        let decisions = await planner.plan(entries, uploaded: manifest.uploaded,
                                           dest: paths.dest, rawDir: paths.rawPackets,
                                           coolingDays: settings.coolingDays, now: Date(),
                                           recordStatus: recordStatus.map(Int.init),
                                           deviceCurrent: deviceCurrent)
        return await execute(decisions, entries: entries, client: client)
    }

    /// 显式擦除：只看本地留档完整性，不看深脑、不看冷静期。
    /// **只能由人手动触发**，自动流程永远不会走到这里。
    func performWipe(client: BLEClient, entries: [FileEntry],
                     recordStatus: UInt8?, deviceCurrent: String?) async -> (deleted: Int, note: String) {
        let decisions = Cleanup.planWipe(entries, dest: paths.dest, rawDir: paths.rawPackets,
                                         recordStatus: recordStatus.map(Int.init),
                                         deviceCurrent: deviceCurrent)
        return await execute(decisions, entries: entries, client: client)
    }

    private func execute(_ decisions: [Cleanup.Decision], entries: [FileEntry],
                         client: BLEClient) async -> (Int, String) {
        var deleted = 0
        var failed = 0
        for d in decisions where d.delete {
            guard let entry = entries.first(where: { $0.base == d.name }) else { continue }
            // 最后一道闸：删之前真的去解一次码。
            // 前面六道闸只查了 ogg 的头四字节，「ogg 是坏的但看起来双份留档齐全」
            // 能一路过闸，然后设备上那份就没了。这类洞平时不出事，出事就是永久丢失。
            let audit = ArchiveAudit.audit(base: d.name,
                                           expectedBytes: Int(entry.size),
                                           expectedSeconds: Int(entry.time),
                                           dest: paths.dest, rawDir: paths.rawPackets)
            guard audit.status.isHealthy else {
                log.write("删除前体检不过，跳过 \(d.name)：\(audit.detail)")
                failed += 1
                continue
            }
            // deleteOne 内部会重拉列表确认它真的消失了——应答不可信，旧固件根本不发 2-13
            guard let result = try? await client.deleteOne(entry) else { failed += 1; continue }
            if result.0 {
                deleted += 1
                // 每删一条立刻写回：中途断电也不会把"已删"这笔账丢掉。
                // 重读是为了不覆盖别处刚写的 imported/uploaded。
                var fresh = SyncManifest.load(from: paths.manifest)
                fresh.deleted[d.name] = Self.stamp(Date())
                try? fresh.save(to: paths.manifest)
            } else {
                failed += 1
            }
        }
        var note = ""
        if deleted > 0 { note = "清理 \(deleted) 条" }
        if failed > 0 { note += (note.isEmpty ? "" : "，") + "删除失败 \(failed) 条" }
        return (deleted, note)
    }
}

// MARK: - 日志

/// 往文件里追加同步日志。
///
/// 为什么必须有：这个 App 常驻后台自己干活，出问题时人不在场。
/// 没有日志，一次半夜失败的同步就什么痕迹都不留，只能靠复现——而蓝牙问题往往复现不了。
/// 写文件而不是 print：SwiftPM 产出的 .app 由 Finder 启动时 stdout 直接进虚空。
public final class SyncLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private static let maxBytes = 2 * 1024 * 1024   // 超过就轮转，别把 iCloud 撑爆

    public init(url: URL) { self.url = url }

    public func write(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > Self.maxBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.txt")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

public extension SyncPaths {
    var syncLog: URL { root.appendingPathComponent("out/swift-同步日志.txt") }
}

// MARK: - 失败分类与重推

/// 深脑侧失败码的分类。
///
/// 为什么要分：`INVALID_ASR_TIMELINE` 在深脑的 finalizer 里明确标着 `retryable: false`——
/// 同一份音频重推一百次结果都一样。给这种失败摆一个「重试」按钮是害人，
/// 用户会反复点、反复失败，最后以为是软件坏了。
public enum BrainFailure {
    /// 重推同一份音频不会有不同结果
    public static let permanent: Set<String> = [
        "INVALID_ASR_TIMELINE",     // 转写没返回任何语音段
        "PROVIDER_REJECTED",
        "ASR_TASK_EVIDENCE_MISSING",
        "MANIFEST_INCOMPLETE",
        "OBJECT_MISMATCH",
    ]

    public static func retryable(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return true }   // 不知道原因就允许试一次
        return !permanent.contains(code)
    }

    /// 给人看的解释。不要把裸错误码摆在界面上。
    public static func explain(_ code: String?) -> String {
        switch code {
        case "INVALID_ASR_TIMELINE":
            return "转写没能识别出任何语音。这段录音里可能没有清晰人声（比如放在包里、只有环境噪音），重推同一份音频结果不会变。"
        case "PROVIDER_UNAVAILABLE":
            return "转写服务暂时不可用，属于临时故障，可以重推。"
        case "PROVIDER_REJECTED":
            return "转写服务拒绝了这份音频，多半是格式或时长不被支持。"
        case "ASR_TASK_EVIDENCE_MISSING":
            return "转写任务丢了凭据，无法确认结果。"
        case "MANIFEST_INCOMPLETE":
            return "分片清单不完整，音频没能拼齐。"
        case "FINALIZATION_FAILED", "INTERNAL_ERROR":
            return "深脑收尾时出错，属于临时故障，可以重推。"
        case .some(let c) where !c.isEmpty:
            return "深脑侧失败：\(c)"
        default:
            return "深脑侧失败，原因未知。"
        }
    }
}

public extension SyncEngine {

    /// 把一条已失败的录音重新推一遍。
    ///
    /// 不能复用原来的 clientRequestId：那个会话已经 finalize 了，同一个幂等键只会拿回它本身
    /// （`DeepBrain.upload` 的 alreadyDone 分支），等于什么都没做。所以换一个带轮次后缀的键，
    /// 在深脑那边建一个全新的会话。
    func repushFailed(_ base: String) {
        Task { @MainActor in
            guard let brain = await ensureBrain() else {
                log.write("重推 \(base) 失败：没接通深脑")
                return
            }
            let ogg = paths.dest.appendingPathComponent("\(base).ogg")
            guard let data = try? Data(contentsOf: ogg), !data.isEmpty else {
                log.write("重推 \(base) 失败：本地没有 ogg")
                return
            }
            let raw = paths.rawPackets.appendingPathComponent("\(base).opus")
            let dur = (try? Data(contentsOf: raw)).map { OggWrap.durationSeconds(rawLength: $0.count) } ?? 0
            var manifest = SyncManifest.load(from: paths.manifest)
            let round = (retryRounds[base] ?? 1) + 1
            retryRounds[base] = round
            phase = .uploading(base, "重推第 \(round) 轮")
            do {
                let up = try await brain.upload(audio: [UInt8](data), title: base, durationSec: dur,
                                                clientRequestId: "mac-ble-\(base)-r\(round)")
                manifest.uploaded[base] = up.sessionId
                try? manifest.save(to: paths.manifest)
                brainState[base] = ("processing", nil, nil)
                log.write("重推 \(base) 第 \(round) 轮 → 新会话 \(up.sessionId)")
                await refreshBrainStatus(manifest)
            } catch {
                log.write("重推 \(base) 第 \(round) 轮失败：\(describe(error))")
            }
            phase = monitoring ? .waitingForDevice : .idle
            refreshLocalView()
        }
    }
}

public extension SyncEngine {
    /// 给界面用的深脑客户端（已登录）。说话人指认要直接读写 speakers 表。
    /// allowUnauthenticated: 登录页需要一个还没登录的客户端去调 signIn。
    func uiBrain(allowUnauthenticated: Bool = false) async -> DeepBrain? {
        if let b = await ensureBrain() { return b }
        guard allowUnauthenticated,
              let cfg = try? DeepBrainConfig.load(from: paths.deepBrainConfig) else { return nil }
        return DeepBrain(config: cfg)
    }

    /// 请求从设备重新下载某一条。
    ///
    /// 实现方式是把它从「已导入」清单里划掉——下一轮同步就会把它当新文件重下，
    /// 不需要另写一条下载路径。设备此刻不在也没关系，等它出现自然会补上。
    ///
    /// 注意这会覆盖本地已有的 ogg 和裸包，正是这个按钮的本意（怀疑本地那份坏了）。
    func requestRedownload(_ base: String) {
        var manifest = SyncManifest.load(from: paths.manifest)
        let keys = manifest.imported.keys.filter { $0.hasPrefix("\(base).|") || $0.hasPrefix("\(base)|") }
        guard !keys.isEmpty else {
            log.write("重下 \(base)：清单里没有它，跳过")
            return
        }
        for k in keys { manifest.imported.removeValue(forKey: k) }
        try? manifest.save(to: paths.manifest)
        log.write("已把 \(base) 标记为待重下，设备下次出现时会重新拉取")
        lastSummary = "\(base) 已标记为待重下"
        refreshLocalView()
        syncNow()
    }
}

// MARK: - 人手指定的设备删除

public extension SyncEngine {

    /// 这条从设备上删掉会丢什么。界面弹确认框之前必须先问这个。
    ///
    /// 分三种，后果完全不同：
    ///   - 本地有留档 → 只是设备上少一份，音频还在本机（长期归档本来就靠本机）
    ///   - 本地没留档但已入深脑 → 深脑 30 天后会清原始音频，之后就彻底没了
    ///   - 两边都没有 → 删了就是永久消失
    func deleteImpact(_ base: String) -> String {
        let hasLocal = FileManager.default.fileExists(
            atPath: paths.rawPackets.appendingPathComponent("\(base).opus").path)
        let manifest = SyncManifest.load(from: paths.manifest)
        let inBrain = manifest.uploaded[base] != nil
        if hasLocal { return "本机已有留档，删掉只是设备上少一份，音频不会丢。" }
        if inBrain { return "本机没有留档。深脑 30 天后会清掉原始音频，之后这段录音就彻底没有了。" }
        return "本机没有留档，也没进过深脑。删掉就是永久消失，无法恢复。"
    }

    /// 人手点的删除：排队，等设备下次出现时执行。
    ///
    /// 和自动清理不是一回事——自动清理要过六道闸（已入深脑、留档完整、过冷静期…），
    /// 这里是「你说不要就不要」，只保留一道闸：设备不能正在录音。
    /// 后果由上面的 deleteImpact 讲清楚，人确认过了就照办。
    func requestDeviceDelete(_ base: String) {
        pendingDeviceDelete.insert(base)
        log.write("已排队从设备删除 \(base)，等设备出现时执行")
        lastSummary = "\(base) 已排队从设备删除"
        refreshLocalView()
        syncNow()
    }

    func cancelDeviceDelete(_ base: String) {
        pendingDeviceDelete.remove(base)
        refreshLocalView()
    }

    /// 同步流程里执行排队的删除。返回删掉几条。
    func runPendingDeletes(client: BLEClient, entries: [FileEntry],
                           recordStatus: UInt8?) async -> Int {
        guard !pendingDeviceDelete.isEmpty else { return 0 }
        guard recordStatus == 2 else {
            log.write("设备不在「未录音」状态，本轮不执行人工删除")
            return 0
        }
        var done = 0
        for base in pendingDeviceDelete {
            guard let entry = entries.first(where: { $0.base == base }) else {
                pendingDeviceDelete.remove(base)      // 设备上已经没有了
                continue
            }
            guard let r = try? await client.deleteOne(entry) else { continue }
            if r.0 {
                done += 1
                pendingDeviceDelete.remove(base)
                var m = SyncManifest.load(from: paths.manifest)
                m.deleted[base] = Self.stamp(Date())
                try? m.save(to: paths.manifest)
                log.write("已按你的要求从设备删除 \(base)：\(r.1)")
            } else {
                log.write("从设备删除 \(base) 失败：\(r.1)")
            }
        }
        refreshLocalView()
        return done
    }
}

public extension SyncEngine {
    /// 手动推一条（无视时长门槛）。
    /// 门槛是省钱用的默认规则，不是禁令——你说要推就是要推。
    func pushNow(_ base: String) {
        Task { @MainActor in
            guard let brain = await ensureBrain() else {
                log.write("手动推送 \(base) 失败：没接通深脑"); return
            }
            let ogg = paths.dest.appendingPathComponent("\(base).ogg")
            guard let data = try? Data(contentsOf: ogg), !data.isEmpty else {
                log.write("手动推送 \(base) 失败：本地没有 ogg"); return
            }
            let raw = paths.rawPackets.appendingPathComponent("\(base).opus")
            let dur = (try? Data(contentsOf: raw)).map { OggWrap.durationSeconds(rawLength: $0.count) } ?? 0
            phase = .uploading(base, "手动推送")
            do {
                let up = try await brain.upload(audio: [UInt8](data), title: base, durationSec: dur,
                                                clientRequestId: "mac-ble-\(base)")
                var m = SyncManifest.load(from: paths.manifest)
                m.uploaded[base] = up.sessionId
                try? m.save(to: paths.manifest)
                brainState[base] = ("processing", nil, nil)
                skippedShort[base] = nil
                log.write("手动推送 \(base) → 会话 \(up.sessionId)")
                await refreshBrainStatus(m)
            } catch {
                log.write("手动推送 \(base) 失败：\(describe(error))")
            }
            phase = monitoring ? .waitingForDevice : .idle
            refreshLocalView()
        }
    }
}

public extension SyncEngine {
    /// 收藏/取消收藏。纯本地，不碰深脑——个人偏好没必要去改服务端数据结构。
    /// 上传前定标题与项目。已经推上去的改不了——canonical 守卫挡着，
    /// 而且改了也不会同步回深脑，只会让两边显示不一致。
    func setPlan(_ base: String, title: String?, projectId: String?) {
        var m = SyncManifest.load(from: paths.manifest)
        guard m.uploaded[base] == nil else { return }
        let t = title?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if t == nil && projectId == nil { m.plan.removeValue(forKey: base) }
        else { m.plan[base] = SyncManifest.Plan(title: t, projectId: projectId) }
        try? m.save(to: paths.manifest)
        refreshLocalView()
    }

    func toggleStar(_ base: String) {
        var m = SyncManifest.load(from: paths.manifest)
        if let i = m.starred.firstIndex(of: base) { m.starred.remove(at: i) }
        else { m.starred.append(base) }
        try? m.save(to: paths.manifest)
        refreshLocalView()
    }
}

public extension SyncEngine {
    /// 跑一次本地归档体检。只读，0.2 秒级。
    func runArchiveAudit() -> ArchiveAudit.Report {
        let r = ArchiveAudit.run(paths: paths)
        log.write("归档体检：\(r.summary)")
        // 只在有问题时打扰。天天报平安会让人从此不看通知。
        if r.hasProblems { Notify.send(r.summary, title: "本地归档有问题") }
        return r
    }
}
