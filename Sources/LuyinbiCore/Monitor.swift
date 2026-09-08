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

    /// 连续下载失败次数（按 manifestKey 记）。
    ///
    /// 设备列表里报着、但每次下载都拿回 0 字节的「僵尸条目」，因为从没成功过、
    /// 清单里也就没记账，于是**每一轮同步都把它当成新文件再试一遍**。
    /// 2026-09-07 实测：一条这样的文件从 8/30 到 9/7 试了 97 次，
    /// 每次都占掉一段本就只有 27KB/s 的蓝牙连接时间，日志里还刷满噪音。
    /// 攒够 `SyncPlanner.giveUpAfter` 次就不再自动重试——但绝不删账、
    /// 也不隐藏，界面上仍看得到并且能手动重试（设备换个姿势、固件重启都可能就好了）。
    public var downloadFailures: [String: Int] = [:]

    /// 重推轮次（按 base 记）。
    ///
    /// **必须跨重启活着。** 2026-09-07 review：原来只在内存里，重启之后
    /// `repushFailed` 又从 r2 开始。而 r2 那个会话如果已经是 failed，
    /// `DeepBrain.upload` 会抛「failed 状态挡着重传」——于是这条录音
    /// **在这台机器上再也重推不了了**，因为每次都在撞同一个键。
    public var repushRounds: [String: Int] = [:]

    public struct Plan: Codable, Equatable, Sendable {
        public var title: String?
        public var projectId: String?
        public init(title: String? = nil, projectId: String? = nil) {
            self.title = title; self.projectId = projectId
        }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case imported, uploaded, deleted, starred, plan, downloadFailures, repushRounds
    }

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
        downloadFailures = (try? c.decode([String: Int].self, forKey: .downloadFailures)) ?? [:]
        repushRounds = (try? c.decode([String: Int].self, forKey: .repushRounds)) ?? [:]
    }

    /// 这份清单是不是「读出来的」而不是「凭空造的」。
    ///
    /// **读不出来 ≠ 没有。** 2026-09-07 code review 抓到：原来 load 把三种情况
    /// 压成同一个空清单——文件不存在（首次运行，正确）、读不到（iCloud 驱逐 /
    /// 权限 / 瞬时故障）、解码失败（半截 JSON）。而每个写入点都是
    /// 「load → 改一个键 → .atomic save」，于是**空清单会被原子地永久写回去**，
    /// imported / uploaded / deleted / starred / plan / downloadFailures 一次全没。
    ///
    /// 这不是假想：Python 版 `pull.py` 写同一个文件用的是 `write_text`（先截断再写），
    /// Swift 只要在那个窗口读一次就会拿到半截 JSON。逐键容错解码器
    /// （`init(from:)`）正是为了防这一类丢失才写的，而 load 从它外面绕了过去。
    ///
    /// false = 这份是「读失败之后的空壳」，**任何人都不许拿它去覆盖磁盘**。
    public private(set) var isTrustworthy = true

    /// 磁盘上根本没有这个文件（首次运行）。这种空清单是可信的，可以正常写。
    public static func fresh() -> SyncManifest { SyncManifest() }

    public static func load(from url: URL) -> SyncManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return fresh() }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SyncManifest.self, from: data) else {
            var poisoned = SyncManifest()
            poisoned.isTrustworthy = false
            return poisoned
        }
        return decoded
    }

    public enum SaveError: Error, CustomStringConvertible {
        case refusedUntrustworthy
        public var description: String {
            "拒绝保存：这份清单来自一次失败的读取，写回去会把整本账抹掉"
        }
    }

    public func save(to url: URL) throws {
        // 拒绝把「读失败造出来的空壳」写回磁盘。宁可这一轮什么都不记，
        // 也不能把已导入/已上传/已删除的全部记录换成空的——
        // 后者的代价是整台设备按 27KB/s 重下一遍，外加收藏和标题全丢。
        guard isTrustworthy else { throw SaveError.refusedUntrustworthy }
        let enc = JSONEncoder()
        // sortedKeys 让 diff 稳定；withoutEscapingSlashes 对齐 Python 的 ensure_ascii=False 观感
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(self)
        // 写新的之前先留一份上一版。清单是这个 App 唯一不可再生的状态
        // （音频丢了还能从设备重下，账本丢了就只能靠重下整台设备来重建）。
        if let old = try? Data(contentsOf: url), !old.isEmpty {
            try? old.write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
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
    ///
    /// **两个 nil 的方向必须都朝安全那边倒。** 2026-09-07 code review 抓到：
    /// 原来第一行是 `guard let current else { return false }`——读不到「当前在录哪个」
    /// 就判定「没有正在录的」。而 `readDeviceInfo` 用 `try?` 吞掉读取失败，
    /// 27KB/s 的链路上 4 秒超时很常见，旧固件甚至可能根本不答 3-24。
    /// 于是**一次丢包就解除了这道闸**：正在长的文件被拉成半截，
    /// 而字节数与设备当时声称的大小恰好一致，下载完整性硬闸也拦不住它
    /// （它内部自洽，只是短）。接着以 `mac-ble-<base>` 推上去并 finalize，
    /// 完整版此后因为 `manifest.uploaded` 已有键，连队列都进不了。
    /// 这正是 2026-08-27「补传腰斩正在录的录音」那次事故的同一条路。
    ///
    /// 现在的判据：**设备说它在录（1/3），却说不出在录哪个 → 这一批全都不安全。**
    ///
    /// 只收窄到这一种组合，不扩大到「status 也读不到」。写宽的那版被自测挡下来了，
    /// 挡得对：`status == nil` 分不清「这次读失败」和「这个固件根本不实现 3-20」，
    /// 一律拦等于让老固件永远同步不了——**为了防一种丢失而制造另一种彻底不可用，
    /// 是更坏的交易**。status 读不到那一路交给上层记日志（readDeviceInfo）。
    public static func isLive(_ e: FileEntry, status: UInt8?, current: String?) -> Bool {
        let recording = status == 1 || status == 3
        guard let current, !current.isEmpty else {
            // 设备自称在录、却说不出在录哪个：这一批里任何一条都可能是它，全拦。
            return recording
        }
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
    /// 连续失败多少次之后不再自动重试。
    ///
    /// 5 次的来历：真实的可恢复失败（信号弱、设备正忙、连接抖动）实测最多两三次
    /// 就会成功一次；而**结构性坏掉的条目一次都不会成**（设备报着它、
    /// 一下载就回 0 字节，9 天 97 次没有一次例外）。5 次留足了给前者，
    /// 又不至于让后者无限占用连接时间。
    public static let giveUpAfter = 5

    public static func pending(entries: [FileEntry], manifest: SyncManifest,
                               status: UInt8?, current: String?,
                               localRaw: [String: Int] = [:]) -> [FileEntry] {
        entries.filter { e in
            guard manifest.imported[manifestKey(e)] == nil else { return false }
            guard !isLive(e, status: status, current: current) else { return false }
            if let have = localRaw[normalizedBase(e.name)],
               have == Int(e.size), have % 40 == 0, have > 0 { return false }
            // 连续失败够多次就不再自动重试。**只停自动，不停手动**——
            // 这是「别再浪费每一轮的连接时间」，不是「这条不要了」。
            if (manifest.downloadFailures[manifestKey(e)] ?? 0) >= giveUpAfter { return false }
            return true
        }
    }

    /// 一份断点还能不能接着用。
    ///
    /// **安全关键，所以抽成纯函数**（跟 downloadComplete 同一条理由）：判错一次，
    /// 拼出来的就是一段前后不属于同一个文件的字节——而它长度可能恰好是 40 的
    /// 整数倍、总大小也可能刚好凑够，下载完整性硬闸未必拦得住。
    ///
    /// - Parameters:
    ///   - savedFor: 存这份断点时、设备声称的大小
    ///   - announced: 这一次设备声称的大小
    public static func partialUsable(bytes: Int, savedFor: UInt32?, announced: UInt32) -> Bool {
        // 设备这次报的大小跟存断点那次不一样 → 这个文件变了（还在录 / 被替换 /
        // 是另一个同名文件），断点作废。
        guard let savedFor, savedFor == announced else { return false }
        guard bytes > 0, bytes < Int(announced) else { return false }   // 空的没用；够了就不叫断点
        return bytes % 40 == 0                                          // 必须停在整包边界
    }

    /// 攒够次数、已经被自动重试放弃的条目。界面据此显示「试了 N 次都没成，点这里再试」。
    public static func givenUp(entries: [FileEntry], manifest: SyncManifest) -> [FileEntry] {
        entries.filter { (manifest.downloadFailures[manifestKey($0)] ?? 0) >= giveUpAfter }
    }

    /// 一次下载算不算真的完整。
    ///
    /// 抽成纯函数是因为它是**安全关键**的：判错一次，半截录音就会冒充完整的推进深脑，
    /// 而本地看起来一切正常（2026-08-29 的三小时会议就是这么丢的）。
    /// 内联在下载循环里没法单测，出了事只能靠人肉复盘。
    /// - Parameter isRawOpus: 这次下回来的是不是裸 opus 包。
    ///   `% 40` 这条只对裸包成立——40 字节 = 20ms 一包，除不尽就是截在半包上。
    ///   设备也可能吐 wav（`FileEntry.candidates` 里 `.opus` 之后就是 `.wav`），
    ///   而 wav 的长度是任意的：2026-09-07 code review 发现，把 `% 40` 无差别地
    ///   套在 wav 上，**39/40 的概率会把一个完好的文件判成「不完整」**，
    ///   重试五次之后进「放弃」名单——这多半就是那条 9 天试了 97 次的僵尸条目。
    ///   对 wav 而言，「字节数与设备声称的一致」本身就是完整性判据。
    public static func downloadComplete(got: Int, announced: UInt32, isRawOpus: Bool = true) -> Bool {
        guard got > 0, got == Int(announced) else { return false }
        return isRawOpus ? got % 40 == 0 : true
    }

    /// 本地已经有完整副本、但清单没记账的条目。补记用，不重下。
    ///
    /// **必须同时确认 ogg 真的在**。2026-09-07 code review 抓到：原来只看裸包，
    /// 然后记一条 `file: "<base>.ogg"` 的账——而落盘那段是先写裸包、再封 ogg，
    /// 封装或写 ogg 失败时直接 `continue`，裸包留在原地、清单没记。
    /// 下一轮这里看到裸包完整就补账，**断言了一个从来没写成功的 ogg**。
    /// 此后 `pending` 因为「已记账」跳过它、`scanUploadable` 因为「没有 ogg」找不到它——
    /// 音频以裸包形式活着，但自动路径里再没有任何东西会去碰它。
    /// 这种「裸包在、ogg 不在」的该走 `needsRewrap`，本地封一次就行，不用重下。
    public static func unrecorded(entries: [FileEntry], manifest: SyncManifest,
                                  status: UInt8?, current: String?,
                                  localRaw: [String: Int],
                                  localOgg: Set<String>) -> [FileEntry] {
        entries.filter { e in
            guard hasCompleteRaw(e, manifest: manifest, status: status,
                                 current: current, localRaw: localRaw) else { return false }
            return localOgg.contains(normalizedBase(e.name))
        }
    }

    /// 裸包完整、但 ogg 不在：本地重封一次即可，**不必重下**。
    ///
    /// 裸包是设备原样吐出来的字节，封装是纯本地的确定性变换——
    /// 27KB/s 的链路上，为一个已经躺在磁盘上的文件重下一遍是纯粹的浪费。
    public static func needsRewrap(entries: [FileEntry], manifest: SyncManifest,
                                   status: UInt8?, current: String?,
                                   localRaw: [String: Int],
                                   localOgg: Set<String>) -> [FileEntry] {
        entries.filter { e in
            guard hasCompleteRaw(e, manifest: manifest, status: status,
                                 current: current, localRaw: localRaw) else { return false }
            return !localOgg.contains(normalizedBase(e.name))
        }
    }

    private static func hasCompleteRaw(_ e: FileEntry, manifest: SyncManifest,
                                       status: UInt8?, current: String?,
                                       localRaw: [String: Int]) -> Bool {
        guard manifest.imported[manifestKey(e)] == nil else { return false }
        guard !isLive(e, status: status, current: current) else { return false }
        guard let have = localRaw[normalizedBase(e.name)] else { return false }
        return have == Int(e.size) && have % 40 == 0 && have > 0
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
public final class SyncEngine: ObservableObject {

    // MARK: 对界面暴露
    @Published public private(set) var device = DeviceInfo()
    @Published public private(set) var items: [RecordingItem] = []
    @Published public private(set) var phase: SyncPhase = .idle
    @Published public private(set) var lastRun: Date?
    @Published public private(set) var lastSummary: String = ""
    /// 监听循环是否在跑（跟 phase 分开：同步过程中 phase 不是 waitingForDevice，但监听仍然开着）
    @Published public private(set) var monitoring = false
    /// 已落盘、欠深脑的队列。上传失败不影响音频，只是排进这里等重试。
    /// 已落盘、欠深脑的队列。界面不直接读它（读的是 items 的投影），所以不必 @Published。
    private(set) var uploadQueue: [PendingUpload] = []
    /// 设备-账号绑定不一致，等着人确认（spec 019）。非 nil 时这支笔的同步全部拦下——
    /// 见 runSync 里的绑定检查。界面（DevicePage）据此显示确认卡片。
    @Published public private(set) var pendingBindMismatch: BindMismatch?
    /// 整条推送链为什么停着（连不上深脑/登录失效）。非 nil 时主窗口顶部挂一条横幅。
    /// 症状（「推送卡住」）到处都是，病因只有一个地方知道——就是这里。
    @Published public private(set) var uploadBlocked: String?
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
    /// transcriptId -> 还没指认的说话人个数
    /// 因为太短而没推的：base -> 实际时长秒。界面上要说清楚是「按规则跳过」不是「失败」。
    /// 语音活动检测结果。只用于提示，不参与是否推送的决策。
    /// 语音活动检测结果。只喂日志，没有界面读它——所以不必 @Published。
    private var voiceReports: [String: VoiceActivity.Report] = [:]
    private var skippedShort: [String: Double] = [:]
    /// 人手点了「从设备删除」但设备还没出现的，排队等着
    private var pendingDeviceDelete: Set<String> = []
    private var unconfirmedSpeakers: [String: Int] = [:]
    /// transcript_id -> 标题。与 unconfirmedSpeakers 同一轮批量拉。
    private var brainTitles: [String: String] = [:]
    private var brainPollTask: Task<Void, Never>?
    private var uploadRetryTask: Task<Void, Never>?
    private var idleRounds: [String: Int] = [:]
    private var cleanupLoaded = false
    private var brain: DeepBrain?
    private var monitorTask: Task<Void, Never>?
    private var isSyncing = false

    /// 认领这一轮同步。**检查和置位必须是同一个动作。**
    ///
    /// 2026-09-07 code review：`syncNow` 原来在最外层同步地判 `!isSyncing`，
    /// 而 `isSyncing = true` 要等到 `runSync` 里才置——中间隔着一次
    /// `discover(seconds: 8)`。那 8 秒里 isSyncing 还是 false，于是监听循环
    /// 看到广播照样会起自己那一轮 runSync。
    /// 两轮同步共用同一个 BLEClient（一个 pending 队列、一个 seq），
    /// 帧会交错，谁先跑完谁的 `defer { client.disconnect() }` 就把另一边掐断。
    /// 截断守卫能兜住损坏的结果，但代价是白跑一次 BLE 会话，
    /// 而且**给一个其实没问题的文件记了一次下载失败**——攒够 5 次就被放弃了。
    ///
    /// `requestRedownload` / `requestDeviceDelete` 都会调 syncNow，
    /// 所以「点重新下载再点从设备删除」就足以触发。
    private func claimSync() -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        return true
    }
    /// 刷上传队列的互斥标志。见 flushUploadQueue 顶部的注释。
    private var isFlushing = false
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
        startUploadRetry()
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
        uploadRetryTask?.cancel()
        uploadRetryTask = nil
        monitoring = false
        if !isSyncing {
            monitorTask?.cancel()
            monitorTask = nil
            if !isFailed(phase) { phase = .idle }
        }
    }

    /// 手动立刻同步一次。忽略冷却，但不会和正在跑的同步并发。
    public func syncNow() {
        guard claimSync() else {
            lastSummary = "正在同步中，忽略这次手动触发"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSyncing = false }
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
            // 认领与执行之间不能再有 await，否则又回到 review 抓的那个竞态。
            guard claimSync() else { continue }
            await runSync(target: target)
            isSyncing = false
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
    /// **调用前必须已经 claimSync() 成功**，本函数不自己置位——
    /// 置位与检查分开正是 review 抓到的那个竞态的成因。
    private func runSync(target: Discovered) async {
        assert(isSyncing, "runSync 必须在 claimSync() 之后调用")

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

        // 顺序就是优先级：先拿到能不能下载的判据，再拉列表干活，
        // 显示用的读数留到最后（见 readSyncCriticalInfo 的注释）。
        await readSyncCriticalInfo(client)

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
        log.write("列表回来 \(entries.count) 条\(gotDone ? "" : "（未收到 2-18 结束帧，可能不完整）")")

        var manifest = SyncManifest.load(from: paths.manifest)
        let rawOnDisk = scanLocal(paths.rawPackets, ext: "opus")

        let oggOnDisk = Set(scanLocal(paths.dest, ext: "ogg").keys)

        // 先补账：裸包和 ogg 都在、只是清单没记上的，登记一下就行，别再下一遍。
        let recovered = SyncPlanner.unrecorded(entries: entries, manifest: manifest,
                                               status: lastStatus, current: lastCurrent,
                                               localRaw: rawOnDisk, localOgg: oggOnDisk)
        if !recovered.isEmpty {
            for e in recovered {
                let b = SyncPlanner.normalizedBase(e.name)
                manifest.imported[SyncPlanner.manifestKey(e)] = SyncManifest.Imported(
                    file: "\(b).ogg", bytes: rawOnDisk[b] ?? 0, at: Self.stamp(Date()))
            }
            persist(manifest)
            log.write("补记 \(recovered.count) 条：本地已有完整副本但清单没记账，"
                      + recovered.map { SyncPlanner.normalizedBase($0.name) }.joined(separator: "、"))
        }

        // 裸包完整但 ogg 不在：本地重封，不重下。
        // 这些是上一轮「裸包写成了、封装那步炸了」留下的——以前它们会被上面那段
        // 直接补账成「已导入」，从此再没有任何自动路径会碰它们（见 unrecorded 的注释）。
        let rewrap = SyncPlanner.needsRewrap(entries: entries, manifest: manifest,
                                             status: lastStatus, current: lastCurrent,
                                             localRaw: rawOnDisk, localOgg: oggOnDisk)
        for e in rewrap {
            let b = SyncPlanner.normalizedBase(e.name)
            let rawURL = paths.rawPackets.appendingPathComponent("\(b).opus")
            guard let raw = try? Data(contentsOf: rawURL) else {
                log.write("重封 \(b) 失败：裸包读不出来（\(rawURL.lastPathComponent)）")
                continue
            }
            do {
                let ogg = try OggWrap.wrap([UInt8](raw))
                try Data(ogg).write(to: paths.dest.appendingPathComponent("\(b).ogg"), options: .atomic)
                manifest = SyncManifest.load(from: paths.manifest)
                manifest.imported[SyncPlanner.manifestKey(e)] = SyncManifest.Imported(
                    file: "\(b).ogg", bytes: raw.count, at: Self.stamp(Date()))
                persist(manifest)
                log.write("重封 \(b)：裸包完整但 ogg 缺失，本地补封成功（没有重下）")
            } catch {
                log.write("重封 \(b) 失败：\(describe(error))——裸包留着，下一轮再试")
            }
        }
        if !rewrap.isEmpty { refreshLocalView() }

        let todo = SyncPlanner.pending(entries: entries, manifest: manifest,
                                       status: lastStatus, current: lastCurrent,
                                       localRaw: rawOnDisk)
        let skipped = entries.count - todo.count

        // **把「为什么没下」写清楚。** 2026-09-08 排查时最卡人的一点就是：
        // 日志只说「跳过 N 条已导」，而设备上明明有一条两小时的录音没下下来。
        // 到底是已记账、还是被当成正在录、还是攒够失败次数被放弃了，
        // 从日志里一个字都看不出来，只能对着代码反推。这几行就是补这个。
        if todo.isEmpty && !entries.isEmpty {
            var already = 0, live = 0, gaveUp = 0, haveLocal = 0
            for e in entries {
                let key = SyncPlanner.manifestKey(e)
                if manifest.imported[key] != nil { already += 1 }
                else if SyncPlanner.isLive(e, status: lastStatus, current: lastCurrent) { live += 1 }
                else if (manifest.downloadFailures[key] ?? 0) >= SyncPlanner.giveUpAfter { gaveUp += 1 }
                else if let have = rawOnDisk[SyncPlanner.normalizedBase(e.name)],
                        have == Int(e.size), have % 40 == 0, have > 0 { haveLocal += 1 }
            }
            log.write("这一轮没有要下的：已记账 \(already) / 正在录 \(live)"
                      + " / 试够次数放弃 \(gaveUp) / 本地已有完整副本 \(haveLocal)")
        } else if !todo.isEmpty {
            log.write("要下 \(todo.count) 条："
                      + todo.prefix(5).map { SyncPlanner.normalizedBase($0.name) }.joined(separator: "、")
                      + (todo.count > 5 ? " …" : ""))
        }

        var imported = 0
        for e in todo {
            let base = SyncPlanner.normalizedBase(e.name)
            errors[base] = nil
            let throttle = ProgressThrottle()
            phase = .downloading(base, 0)

            // 断点：上一次连接收到一半的字节。设备声称的大小必须和当时一致——
            // 对不上说明这个文件在设备上变了（还在录、或者被换过），
            // 那份断点就不能接着用，从头来。
            let partial = loadPartial(base: base, announced: e.size)
            if !partial.isEmpty {
                log.write(String(format: "接着上次的断点续传 %@：已有 %d/%@ B（%.0f%%）",
                                 base, partial.count, String(e.size),
                                 Double(partial.count) / Double(max(e.size, 1)) * 100))
            }

            let res: BLEClient.DownloadResult
            do {
                res = try await client.download(
                    candidates: e.candidates, expectSize: e.size,
                    resumeFrom: partial,
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

            // **被断线打断 ≠ 下载失败。** 存成断点，下次连上接着要，
            // 也不记失败计数——设备主动断链是常态（实测每 8 秒一次），
            // 把它算成「这个文件有问题」，五轮之后就会被误判成僵尸条目放弃掉。
            if res.disconnected {
                savePartial(base: base, announced: e.size, bytes: res.data)
                let pct = Double(res.data.count) / Double(max(e.size, 1)) * 100
                errors[base] = String(format: "传到 %.0f%% 时设备断开了，下次连上接着传", pct)
                log.write(String(format: "断线中断 %@：已存断点 %d/%@ B（%.0f%%），不计失败",
                                 base, res.data.count, String(e.size), pct))
                refreshLocalView()
                // 设备都断了，这一轮剩下的也别再试了，白等超时。
                break
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
                noteDownloadFailure(e)
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
            // 裸包还要能被 40 整除（40 B = 20 ms 一包，除不尽就是截断在半包上）。
            // 对不上就当失败重下，绝不落盘——宁可重来，也不能让半截录音冒充完整的。
            //
            // 「是不是裸包」按**成功的那个候选名**判，不按内容猜：设备吐 wav 时
            // 长度是任意的，拿 `% 40` 去卡它会把完好的文件误判成不完整（见
            // downloadComplete 的注释）。
            let gotRawOpus = !res.filename.lowercased().hasSuffix(".wav")
            let want = Int(e.size)
            if !SyncPlanner.downloadComplete(got: res.data.count, announced: e.size,
                                             isRawOpus: gotRawOpus) {
                let pct = want > 0 ? Double(res.data.count) / Double(want) * 100 : 0
                errors[base] = String(format: "只收到 %d/%d 字节（%.1f%%），设备却报了完成——按未完成处理",
                                      res.data.count, want, pct)
                log.write(String(format: "下载不完整 %@：收到 %d/%d 字节（%.1f%%）续传%d次，丢弃重来",
                                 base, res.data.count, want, pct, res.resumes))
                noteDownloadFailure(e)
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
            // 成功了就把失败账清零——判据是「**连续**失败」，
            // 不清的话一条平时偶尔抖一下的文件，攒够五次就再也不自动下了。
            manifest.downloadFailures[SyncPlanner.manifestKey(e)] = nil
            persist(manifest)
            dropPartial(base)          // 这条已经完整拿到了，断点没用了
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

        // 先把要碰设备的事做完：人手排的删除 → 自动清理。
        // 人的意愿排在规则前面。
        var cleanNote = ""
        let manualDeleted = await runPendingDeletes(client: client, entries: entries,
                                                    recordStatus: device.recordStatus,
                                                    listComplete: gotDone)
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

        // 活干完了，这时候才去读电量/固件/容量这些纯显示的。
        // 断了就算了——界面上留着上次的读数，比抢在前面读、把下载窗口吃掉强。
        await readDisplayInfo(client)

        // **碰设备的事全做完了，立刻放掉蓝牙，再去推深脑。**
        //
        // 这一段的注释一直写着「断开蓝牙再推更稳」，而代码并没有这么做：
        // disconnect() 挂在函数开头注册的 defer 上，真正执行是在整个 runSync
        // 返回之后——也就是**推完深脑之后**。一次合并的三个半小时录音要传
        // 20MB+，慢网下十几分钟，这期间录音笔一直被我们占着：
        // 耗它的电、挡着手机 App 连它（BLE 从机同时只接受一个主机）、
        // 也让它无法回到低功耗广播——而低功耗广播正是 idleBackoff 想省的东西。
        //
        // 显式断在这里；defer 里那次仍然留着，负责所有中途返回的错误路径
        // （disconnect 幂等，重复调用是空操作）。
        client.disconnect()
        device.connected = false

        let uploaded = await flushUploadQueue()

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

    /// **同步必需的两项**：设备在不在录、在录哪一个。
    ///
    /// 只读这两项，且**放在连接之后的第一步**。原来是先读电量/固件/增益/容量
    /// 再读这两项，六个串行 BLE 往返、最坏 25 秒——而 2026-09-08 实测
    /// 设备连上约 8 秒就主动断链，于是窗口的一大半花在纯显示信息上，
    /// 真正要干的活（拉列表、下载）还没开始就断了，一整天 0 次成功下载。
    ///
    /// `currentFilename` 只在设备自称在录时才问：它**没在录的时候本来就没有
    /// 「当前文件」**，白问一次要干等 4 秒超时——正是那 8 秒里最大的一笔浪费。
    private func readSyncCriticalInfo(_ client: BLEClient) async {
        device.recordStatus = (try? await client.recordStatus()) ?? nil
        lastStatus = device.recordStatus
        if lastStatus == 1 || lastStatus == 3 {
            lastCurrent = (try? await client.currentFilename()) ?? nil
            if lastCurrent == nil {
                log.write("设备说在录（状态 \(lastStatus.map(String.init) ?? "?")）却读不到当前文件名"
                          + "——这一批全部按「可能正在录」跳过，不冒截断的险")
            }
        } else {
            // 明确没在录：不存在「当前文件」，这一项就是 nil，不用去问。
            lastCurrent = nil
        }
        if lastStatus == nil {
            log.write("读不到录音状态——本轮仍按「没在录」处理（分不清读失败和固件不支持，"
                      + "一律拦会让老固件永远同步不了，见 SyncPlanner.isLive）")
        }
    }

    /// **纯显示信息**：电量、固件、增益、容量。设备页拿来摆着看的，
    /// 一项都不参与「要不要下载」的判断，所以放到干完活之后再读——
    /// 断线了就这一轮不更新，界面上还是上次的读数，没有任何损失。
    private func readDisplayInfo(_ client: BLEClient) async {
        guard client.isConnected else { return }
        device.battery = (try? await client.battery()) ?? nil
        checkBattery(device.battery)
        guard client.isConnected else { return }
        device.firmware = (try? await client.firmware()) ?? nil
        device.gain = (try? await client.gain()) ?? nil
        if let cap = (try? await client.capacity()) ?? nil {
            device.capacityRemain = cap.remain
            device.capacityTotal = cap.total
        }
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
        // **同一时刻只准有一条刷队列在跑。**
        // 调用点现在有四个：runSync 结尾、syncNow 找不到设备时的兜底、
        // retryUploads（界面按钮，无守卫）、10 分钟补推循环。
        // @MainActor 挡得住数据竞争，挡不住这个——每个 await 都是让出点，
        // 让出期间另一条路径可以整个走完，包括 rebuildUploadQueue 换掉队列本身。
        // 后果不只是重复上传（幂等键大多能兜住），还有按下标写回时的越界崩溃。
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var manifest = SyncManifest.load(from: paths.manifest)
        rebuildUploadQueue(manifest, local: scanUploadable(paths.dest))
        guard !uploadQueue.isEmpty else { refreshLocalView(); return 0 }

        guard let brain = await ensureBrain() else {
            lastSummary = "深脑未接通，本次只落盘"
            // **把「为什么推不上去」摆到界面上，而不是只留在日志里。**
            // 2026-09-07：登录失效期间，界面上每一条都显示「推送卡住」，
            // 而真正的原因（连不上深脑/登录失效）只写在同步日志里——
            // 用户看得见症状、看不见病因，只能一条条猜，最后花了几小时。
            // 队列里有东西、又接不通，就是**整条推送链停摆**，值得一句明说。
            uploadBlocked = "推送暂停：连不上深脑（\(uploadQueue.count) 条在等）——多半是登录失效，点右上角账号图标重新登录"
            refreshLocalView()
            return 0
        }
        uploadBlocked = nil

        let rawSizes = scanLocal(paths.rawPackets, ext: "opus")
        let now = Date()
        var ok = 0
        for (idx, job) in uploadQueue.enumerated() {
            guard force || job.nextAttempt <= now else { continue }
            let base = job.base
            // **同一轮里，被上一条合并进去的段不能再单独推一遍。**
            //
            // 2026-09-07 code review：合并 A+B 之后代码正确地记了 uploaded[B]，
            // 但循环**继续走到 B 自己那次迭代**，而迭代里没有任何地方复查
            // uploaded[base]。于是 B 以从没用过的幂等键 mac-ble-B 又建一个新会话：
            // 同一场会在深脑里出现两次（一次完整合并、一次只有后半段），
            // 双倍转写与分析开销，而且 uploaded[B] 被改写成指向那个单独的会话，
            // 合并出来的那条从此没人引用得到。
            // 原注释只推演了「下一轮」，漏了「同一轮」。
            manifest = SyncManifest.load(from: paths.manifest)
            guard manifest.uploaded[base] == nil else { continue }
            let ext = uploadExt[base] ?? "ogg"
            let url = paths.dest.appendingPathComponent("\(base).\(ext)")
            guard var data = try? Data(contentsOf: url) else {
                // 一秒钟前 scanUploadable 还列出了它，现在读不出来——
                // iCloud 把它驱逐上云了，或者权限/损坏。这条会永远停在「排队中」
                // 而没有任何痕迹，所以必须说话（原来这里是裸 continue）。
                log.write("读不出 \(base).\(ext)，本轮跳过（多半是 iCloud 把它驱逐上云了，先下载回本地）")
                errors[base] = "本地文件读不出来——可能被 iCloud「优化存储」挪上云了，在访达里下载回来再推"
                continue
            }

            // 录音笔有 3 小时上限，到点自动断开、隔 1 秒开下一条。
            // 一场三个半小时的会因此变成两条，在深脑里成了两场互不相干的会——
            // 说话人各认一遍、洞察各出一份、承诺分散在两处。
            //
            // 设备的切分是**它的**限制，不是内容的事实，不该让下游每一层都去理解。
            // 所以在推上去之前就拼回一条：裸包是定长 40 字节的 opus 帧，
            // 首尾相接即合法，零损耗、不重编码。
            var mergedBases: [String] = [base]
            if ext == "ogg" {
                // **已经推上去的段不能再被合并进来。**
                // 扫的是磁盘上所有裸包，不带任何「推过没有」的过滤——于是几周前
                // 单独推过的一段，可能被今天这次合并重新卷进去：深脑里多一份重复音频，
                // 而它原来那个会话再也没人引用得到（uploaded 指向被改写）。
                let ordered = rawSizes.keys.sorted().filter { manifest.uploaded[$0] == nil || $0 == base }
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
                persist(manifest)
                log.write("推深脑 \(mergedBases.joined(separator: "+")) 会话 \(up.sessionId)"
                          + (up.alreadyDone ? "（幂等重放，未重传）" : ""))
                ok += 1
            } catch {
                // **按 base 找，不按下标写回。** 下标是循环开始时那份快照的位置，
                // 而 `await brain.upload` 中间任何一次让出，都可能有另一条路径
                // 调 rebuildUploadQueue 把 uploadQueue 整个换成一个更短的数组——
                // 那时 `uploadQueue[idx]` 就是越界，@MainActor 上直接崩掉整个 App。
                // 2026-09-07 code review 抓到：加了 10 分钟补推循环之后，
                // 「补推正在跑」和「蓝牙同步刚结束也要刷一次」这两条真的会撞上。
                guard let live = uploadQueue.firstIndex(where: { $0.base == base }) else { continue }
                var job = uploadQueue[live]
                job.attempts += 1
                job.lastError = describe(error)
                // 指数退避，封顶 30 分钟。深脑那头可能是网络抖动，也可能是登录过期，
                // 后者重试再快也没用，别把日志刷爆。
                let delay = min(1800, 30 * pow(2, Double(job.attempts - 1)))
                job.nextAttempt = Date().addingTimeInterval(delay)
                uploadQueue[live] = job
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

    /// 独立的补推循环：只要还有欠深脑的，就定时试一次，**不依赖录音笔出现**。
    ///
    /// 2026-09-07 真实事故的收尾：登录失效期间下载照常、上传全挂；
    /// 登录 17:45 修好之后，那 4 条积压却一直躺到 17:59 人手点了「立即同步」才动。
    /// 原因是**刷上传队列只挂在两个地方**——一轮完整的蓝牙同步里，或者人手点按钮。
    /// 录音笔不在身边（空闲 7–8 分钟就停广播），积压就无限期不动，
    /// 而界面上只写「推送卡住」，看不出它在等的其实是一支笔。
    ///
    /// 下载要等设备是物理必然，上传不是——上传只需要网络。两件事本来就该解耦，
    /// 这个循环把它补上。队列空时几乎零成本（一次磁盘扫描），所以敢跑得勤一点。
    private func startUploadRetry() {
        uploadRetryTask?.cancel()
        uploadRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.uploadRetryInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // 正在同步就跳过：那一轮自己结束时会刷队列，两边同时推是白费力气。
                guard !self.isSyncing else { continue }
                await self.flushUploadQueue()
            }
        }
    }

    /// 补推间隔。10 分钟：够快到「开完会回到座位就已经在传了」，
    /// 又不至于在长期没网时把日志刷满。
    private static let uploadRetryInterval: TimeInterval = 600

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

    /// 保存清单，失败必须留痕。
    ///
    /// 13 个写入点原本全是 `try? manifest.save(...)`——而 save 现在会在
    /// 「这份清单来自一次失败的读取」时主动抛错拒绝写入（见 SyncManifest.save）。
    /// 用 `try?` 接住等于把那次拒绝也一起吞掉：账本没记上，日志里一个字都没有，
    /// 正是这个仓库反复强调不许出现的那种静默失败。
    private func persist(_ m: SyncManifest) {
        do {
            try m.save(to: paths.manifest)
        } catch {
            log.write("清单没保存成功：\(describe(error))——这一轮的记账没写下去，下一轮会重来")
        }
    }

    // MARK: - 跨连接断点
    //
    // 断点存在 `原始包/<base>.part`，旁边一个 `.part.size` 记着**当时设备
    // 声称的大小**。下次续传前必须核对这个大小：对不上就说明这个文件在设备上
    // 变了（还在录、被替换、或者是另一个同名文件），那份断点接着用会拼出
    // 一段前后不属于同一个文件的字节——而它长度可能恰好是 40 的整数倍、
    // 大小也可能刚好凑够，完整性硬闸未必拦得住。宁可从头下。

    private func partialURL(_ base: String) -> URL {
        paths.rawPackets.appendingPathComponent("\(base).part")
    }
    private func partialSizeURL(_ base: String) -> URL {
        paths.rawPackets.appendingPathComponent("\(base).part.size")
    }

    private func loadPartial(base: String, announced: UInt32) -> [UInt8] {
        let savedFor = (try? String(contentsOf: partialSizeURL(base), encoding: .utf8))
            .flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let data = try? Data(contentsOf: partialURL(base)),
              SyncPlanner.partialUsable(bytes: data.count, savedFor: savedFor, announced: announced) else {
            dropPartial(base)          // 对不上就丢掉重来，绝不将就
            return []
        }
        return [UInt8](data)
    }

    private func savePartial(base: String, announced: UInt32, bytes: [UInt8]) {
        // 只存整包边界的部分。最后那个不完整的包丢掉，下次从整包处接着要——
        // 40 字节的代价，换掉一整类错位风险。
        let keep = bytes.count - (bytes.count % 40)
        guard keep > 0 else { dropPartial(base); return }
        try? Data(bytes.prefix(keep)).write(to: partialURL(base), options: .atomic)
        try? String(announced).write(to: partialSizeURL(base), atomically: true, encoding: .utf8)
    }

    private func dropPartial(_ base: String) {
        try? FileManager.default.removeItem(at: partialURL(base))
        try? FileManager.default.removeItem(at: partialSizeURL(base))
    }

    /// 记一次下载失败。攒够 `SyncPlanner.giveUpAfter` 次就不再自动重试这一条。
    ///
    /// 每次都立刻写回磁盘，不攒到本轮结束——这份账要跨重启活着才有意义
    /// （那条重试了 97 次的文件，横跨 9 天和无数次重启，只在内存里记等于没记）。
    private func noteDownloadFailure(_ e: FileEntry) {
        var m = SyncManifest.load(from: paths.manifest)
        let key = SyncPlanner.manifestKey(e)
        let n = (m.downloadFailures[key] ?? 0) + 1
        m.downloadFailures[key] = n
        persist(m)
        if n == SyncPlanner.giveUpAfter {
            let base = SyncPlanner.normalizedBase(e.name)
            log.write("\(base) 连续 \(n) 次下载失败，不再自动重试（界面上仍可手动重试）")
            errors[base] = "试了 \(n) 次都没拿到内容，已停止自动重试——详情里点「重新下载」可以再试"
        }
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
        // **账号从本地读，不逼着先联网。** 2026-09-07 真实事故：这里原来先
        // `await ensureBrain()`（要连一次网、刷新一次 token），刷新失败
        // （refresh token 过期/失效，跟这支笔要不要绑是两回事）就直接把整轮
        // 同步拦停、且这一支路没有 log.write——表现是"蓝牙连不上"：设备页
        // 电量/容量永远是"—"，连接在几秒内又断开，日志里只有一串
        // "已连接"却全都没有"同步结束"。真正的病灶是登录失效，不是蓝牙。
        //
        // 账号信息本来就有本地缓存（TokenStore 的 org_id/email，登录时写的），
        // 判断"这支笔绑的账号对不对"根本不需要真的连一次网——只有"这支笔
        // 第一次见、需要去服务端登记"这一件事才要网络，且那件事失败了
        // 不该拖累下载。
        let peripheralId = target.peripheral.identifier.uuidString
        let currentOrg = TokenStore.get("org_id") ?? ""
        let currentEmail = DeepBrain.signedInEmail ?? "当前账号"

        if currentOrg.isEmpty {
            // 没登录：这不是"绑定"这一层该管的事——推深脑那一步（flushUploadQueue）
            // 本来就会因为登录失效而只落盘不推，且有自己的提示。这里放行，
            // 让下载照常进行；账号一旦登录/恢复，下次连接会正常走绑定检查。
            log.write("绑定检查跳过：还没登录，先只下载不做账号核对")
            return true
        }

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
        //
        // 登记这一步才真的要连网（写 iot_devices）。**连不上不能拖累下载**——
        // 2026-09-07 的教训就是把"要不要登记成功"和"能不能下载"绑在一起，
        // 一次 token 刷新失败就让整条下载链路陪着一起挂。连不上就记一句日志，
        // 下次连接自然会重试登记，这一轮照常同步。
        guard let brain = await ensureBrain() else {
            log.write("首次绑定「\(target.name)」暂时跳过：深脑接不通（登录可能失效了），本轮先同步，下次连接再试绑定")
            return true
        }
        let defaultName = "\(target.name)-\(Host.current().localizedName ?? "Mac")"
        let first = await bindDevice(peripheralId, orgId: currentOrg, email: currentEmail,
                                     deviceNo: defaultName, brain: brain)
        if first.ok {
            log.write("首次绑定「\(target.name)」到当前账号「\(currentEmail)」，命名为「\(defaultName)」")
            return true
        }
        // **只有真的撞名才值得换个名字重试。** 401 / 网络错误换名字一样会失败，
        // 白白再花掉一次网络往返——而这段跑在蓝牙连接窗口里，那个窗口很短。
        if case "这个名字已被占用" = first.why {
            let retryName = "\(defaultName)-\(Int.random(in: 100...999))"
            let second = await bindDevice(peripheralId, orgId: currentOrg, email: currentEmail,
                                          deviceNo: retryName, brain: brain)
            if second.ok {
                log.write("首次绑定「\(target.name)」到「\(currentEmail)」，命名为「\(retryName)」（原名字被占用）")
                return true
            }
            log.write("绑定「\(target.name)」失败：换名后仍不成——\(second.why)。本轮跳过绑定，照常同步")
            return true
        }
        log.write("绑定「\(target.name)」失败：\(first.why)。本轮跳过绑定，照常同步")
        return true
    }

    /// - Returns: 成功与否，以及**失败的真实原因**。
    ///
    /// 原来只返回 Bool，调用方于是一律写成「重试后仍冲突」。2026-09-08 实测：
    /// 真正的返回是 **401**（服务端那个端点当时只认 cookie，不认原生 Bearer），
    /// 跟重名毫无关系。日志里那句「仍冲突」把排查引向了完全错误的方向，
    /// 而它每 10 分钟就说一次、说了好几天。
    /// **断言原因之前必须先拿到原因。**
    private func bindDevice(_ peripheralId: String, orgId: String, email: String,
                            deviceNo: String, brain: DeepBrain) async -> (ok: Bool, why: String) {
        switch await brain.selfRegisterDevice(provider: "cb08", deviceNo: deviceNo) {
        case .ok:
            DeviceBinding.bind(peripheralId, orgId: orgId, email: email, deviceNo: deviceNo)
            return (true, "")
        case .deviceTaken:   return (false, "这个名字已被占用")
        case .unauthorized:  return (false, "登录失效（服务端不认这次请求）")
        case .failed(let m): return (false, m)
        }
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
        let r = await bindDevice(mismatch.peripheralId, orgId: currentOrg, email: currentEmail,
                                 deviceNo: name, brain: brain)
        guard r.ok else {
            log.write("换绑「\(mismatch.deviceName)」失败：\(r.why)")
            return false
        }
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

    // 「显式擦除」（planWipe：只看本地留档、不看深脑也不看冷静期）**这里不实现**。
    // 它原来有一份 performWipe，但零调用点、界面也故意没有入口——
    // 一个谁都够不到、又能一次抹光设备的函数，留着只是等哪天有人接错线。
    // 真要用走 Python 版的 `--wipe-verified`（原注释本来就是这么说的）。
    // 判据留在 Cleanup.planWipe 里，有自测钉着，随时可以重新接。

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
                persist(fresh)
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
            var rounds = SyncManifest.load(from: paths.manifest)
            let round = (rounds.repushRounds[base] ?? 1) + 1
            rounds.repushRounds[base] = round
            persist(rounds)
            phase = .uploading(base, "重推第 \(round) 轮")
            do {
                let up = try await brain.upload(audio: [UInt8](data), title: base, durationSec: dur,
                                                clientRequestId: "mac-ble-\(base)-r\(round)")
                // **清单在 await 之后才读。**
                // 原来快照取在上传之前，而上传一个 20MB 的文件要几分钟——
                // 这期间别的路径写进清单的东西（刚下完的 imported、Cleanup 的 deleted、
                // 下载失败计数、收藏与标题）在这一行全被回滚掉。
                // 「await 之后重读」这条纪律这个文件里到处都在讲，只有这里破了例，
                // 而它偏偏是界面上唯一的重推入口（2026-09-07 review）。
                var manifest = SyncManifest.load(from: paths.manifest)
                manifest.uploaded[base] = up.sessionId
                persist(manifest)
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
    /// 人手要求重新下载一条。
    ///
    /// **两件事都要做：清「已导入」的账，也清「下载失败」的账。**
    /// 2026-09-07 review：原来只清 imported，并且 `guard !keys.isEmpty` 直接返回——
    /// 而一条**从没成功下载过**的录音根本没有 imported 键，于是这个按钮
    /// 对它永远是空转（日志里只留一句「清单里没有它，跳过」）。
    /// 更要命的是即使放行了也没用：`pending()` 还会因为失败计数到阈值把它滤掉。
    /// 也就是说，最需要「重新下载」的那种条目，恰好是这个按钮唯一救不了的。
    func requestRedownload(_ base: String) {
        var manifest = SyncManifest.load(from: paths.manifest)
        let importedKeys = manifest.imported.keys.filter { $0.hasPrefix("\(base).|") || $0.hasPrefix("\(base)|") }
        let failureKeys = manifest.downloadFailures.keys.filter { $0.contains(base) }
        guard !importedKeys.isEmpty || !failureKeys.isEmpty else {
            // 空转也要留痕：一个点了没反应的按钮，不该连日志里都查不到。
            log.write("重下 \(base)：清单里既没有导入记录也没有失败计数，无事可做")
            lastSummary = "\(base) 本来就在待下载队列里"
            syncNow()
            return
        }
        for k in importedKeys { manifest.imported.removeValue(forKey: k) }
        for k in failureKeys { manifest.downloadFailures.removeValue(forKey: k) }
        persist(manifest)
        errors[base] = nil
        log.write("已把 \(base) 标记为待重下（清了 \(importedKeys.count) 条导入记录、"
                  + "\(failureKeys.count) 条失败计数），设备下次出现时会重新拉取")
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
    /// - Parameter listComplete: 这份 entries 是不是一份**可信的完整列表**
    ///   （收到了 2-18 结束帧）。`fileList()` 分不清「设备里没有文件」和
    ///   「设备压根没答话」——两种都返回空数组。而下面「列表里没有它 =
    ///   设备上已经删掉了」这条推断，只有在列表可信时才成立：
    ///   一次抖动的读列表会把用户排的整个删除队列**静默清空**，
    ///   连日志都没有，待删角标也跟着消失（2026-09-07 review）。
    func runPendingDeletes(client: BLEClient, entries: [FileEntry],
                           recordStatus: UInt8?, listComplete: Bool) async -> Int {
        guard !pendingDeviceDelete.isEmpty else { return 0 }
        guard recordStatus == 2 else {
            log.write("设备不在「未录音」状态，本轮不执行人工删除")
            return 0
        }
        guard listComplete else {
            log.write("文件列表这轮不完整，人工删除队列原样留着（\(pendingDeviceDelete.count) 条）")
            return 0
        }
        var done = 0
        for base in pendingDeviceDelete {
            guard let entry = entries.first(where: { $0.base == base }) else {
                // 列表可信、里面没有它 → 确实已经不在设备上了。留一句痕迹：
                // 用户排过的动作凭空消失，哪怕结果是对的也该看得见。
                pendingDeviceDelete.remove(base)
                log.write("\(base) 已不在设备上，从待删队列移除")
                continue
            }
            guard let r = try? await client.deleteOne(entry) else {
                // 用户明确要求删的东西没删成，不能一声不吭（原来是裸 continue）。
                log.write("删除 \(base) 时抛错，留在队列里下次再试")
                continue
            }
            if r.0 {
                done += 1
                pendingDeviceDelete.remove(base)
                var m = SyncManifest.load(from: paths.manifest)
                m.deleted[base] = Self.stamp(Date())
                persist(m)
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
                persist(m)
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
        persist(m)
        refreshLocalView()
    }

    func toggleStar(_ base: String) {
        var m = SyncManifest.load(from: paths.manifest)
        if let i = m.starred.firstIndex(of: base) { m.starred.remove(at: i) }
        else { m.starred.append(base) }
        persist(m)
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
