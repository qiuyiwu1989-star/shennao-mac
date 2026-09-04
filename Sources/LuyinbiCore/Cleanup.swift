import Foundation

/// 设备端清理：只删「确认已进深脑」的录音，其余一律不动。
///
/// 从已验证的 Python 实现移植（importer/cleanup.py），判据必须逐条一致——
/// CleanupSelfTest 里保留了同样的 20 条断言。
///
/// 删除不可逆，所以判据宁可严。一条录音要被删，必须同时满足下面全部条件；
/// 任何一条拿不准（包括查询失败、超时、解析不出来），一律判为「不删」。
///
///   A. 深脑已 ready ——不是"上传成功"，是 status=="ready" 且有 final_transcript_id
///   B. 本地有双份留档——原始包/<base>.opus 和 <base>.ogg 都在
///   C. 字节完整 ——本地裸包字节数 == 设备列表 size，且能被 40 整除
///   D. 时长吻合 ——裸包算出的时长与列表 time 相差不超过 2 秒
///   E. 过了冷静期——从文件名解析的录制时间距今 >= coolingDays 天
///   F. 设备不在录音——整机状态必须是「未录音」，且不是设备当前文件
///
/// 另外两条硬规矩：
///   * 只用 2-8 逐个删，每删一个重拉列表确认消失；永不使用 2-9 删除全部
///     （所以 Proto.FileCmd 里故意不定义 delAll）。
///   * 深脑 30 天后会清掉原始音频（隐私承诺），所以长期归档实际靠本机「导入/原始包」。
///     这就是条件 B 不能省的原因。
public enum Cleanup {
    /// 时长允许的误差。设备列表里的 time 是整秒，裸包算出来的是 20ms 粒度，
    /// 两边取整方式不同，差 1~2 秒属于正常。再大就说明拿到的不是同一条录音。
    public static let durationToleranceSec: Double = 2

    public struct Decision: Equatable {
        public let name: String
        public let delete: Bool
        public let reason: String

        public init(_ name: String, _ delete: Bool, _ reason: String) {
            self.name = name; self.delete = delete; self.reason = reason
        }
    }

    // MARK: - 文件名里的录制时间

    /// note<YYYYMMDD>-<HHMMSS>。解析不出来就是 nil——nil 一律走「不删」。
    ///
    /// 用本地时区解析，配的 now 也必须是本地时钟：Python 版用的是 naive datetime
    /// （strptime + datetime.now() 都不带时区），换成 UTC 解析会整整错 8 小时，
    /// 冷静期就会提前一夜到期。
    /// 文件名时间戳的可信区间。设备掉电后 RTC 会归零，生成 note20000101-xxxxxx 这类名字，
    /// 被算成「录于 9000 多天前」，冷静期就形同虚设、一同步完就可删。
    /// 这是唯一一条能真正导致误删的洞，所以在这里堵死：超出区间一律判不可信。
    public static let earliestPlausible = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01

    public static func recordedAt(_ name: String) -> Date? {
        guard let m = nameTimeRegex.firstMatch(
            in: name, range: NSRange(name.startIndex..., in: name)),
            let dateRange = Range(m.range(at: 1), in: name),
            let timeRange = Range(m.range(at: 2), in: name) else { return nil }
        return stampFormatter.date(from: String(name[dateRange]) + String(name[timeRange]))
    }

    private static let nameTimeRegex = try! NSRegularExpression(pattern: "([0-9]{8})-([0-9]{6})")

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")   // 不跟随用户的日历/数字系统
        f.timeZone = TimeZone.current
        f.isLenient = false
        return f
    }()

    // MARK: - 显式擦除模式（B/C/D + F，不看深脑、不看冷静期）

    /// 显式擦除模式的判据：只看「本地留档是否完整」，不看深脑、不看冷静期。
    ///
    /// 用于「清空设备便于测试」这种明确诉求。**只能被显式调用，
    /// 永远不会被自动同步流程触发。** 本地留档不完整的照样不删。
    public static func judgeWipe(_ entry: FileEntry, dest: URL, rawDir: URL) -> Decision {
        let base = entry.base
        let (bad, rawSize) = localArchiveCheck(base, entry, dest: dest, rawDir: rawDir)
        if let bad { return bad }
        let sec = String(format: "%.1f", OggWrap.durationSeconds(rawLength: rawSize))
        return Decision(base, true, "本地留档完整（\(rawSize)B / \(sec)s）")
    }

    public static func planWipe(_ entries: [FileEntry], dest: URL, rawDir: URL,
                                recordStatus: Int?, deviceCurrent: String?) -> [Decision] {
        if let veto = deviceVeto(entries, recordStatus: recordStatus, suffix: "，不删任何文件") {
            return veto
        }
        return entries.map { e in
            isDeviceCurrent(e, deviceCurrent) ? Decision(e.base, false, "是设备当前文件")
                                              : judgeWipe(e, dest: dest, rawDir: rawDir)
        }
    }

    // MARK: - 自动模式

    /// 查一条会话在深脑的状态。抽成闭包是为了让判据能离线自测——
    /// Python 版靠 mock 打桩，Swift 这边靠注入。
    /// 返回 nil = 查得到但没有这条会话；抛异常 = 查询本身失败。两者都判「不删」。
    public typealias SessionLookup = (String) async throws -> DeepBrain.SessionState?

    /// 一轮清理。持有查询缓存：同一个 sessionId 一轮里只查一次。
    ///
    /// 做成实例而不是一堆静态函数，就是为了让缓存的生命周期＝一轮，
    /// 不会跨轮把「上一轮还在 finalizing」的旧状态当成这一轮的依据。
    public final class Planner {
        private enum Probe {
            case found(DeepBrain.SessionState)
            case missing                       // 查通了，但深脑说没有这条会话
        }

        private let lookup: SessionLookup
        private var cache: [String: Probe] = [:]

        public init(lookup: @escaping SessionLookup) { self.lookup = lookup }

        /// 返回逐条判定。整机在录音时直接全部否决。
        public func plan(_ entries: [FileEntry], uploaded: [String: String],
                         dest: URL, rawDir: URL, coolingDays: Int, now: Date,
                         recordStatus: Int?, deviceCurrent: String?) async -> [Decision] {
            if let veto = deviceVeto(entries, recordStatus: recordStatus, suffix: "，本轮不删任何文件") {
                return veto
            }
            var out: [Decision] = []
            out.reserveCapacity(entries.count)
            for e in entries {
                out.append(await judge(e, uploaded: uploaded, dest: dest, rawDir: rawDir,
                                       coolingDays: coolingDays, now: now,
                                       deviceCurrent: deviceCurrent))
            }
            return out
        }

        public func judge(_ entry: FileEntry, uploaded: [String: String],
                          dest: URL, rawDir: URL, coolingDays: Int, now: Date,
                          deviceCurrent: String?) async -> Decision {
            let base = entry.base

            // F-1 设备当前文件：正在录或刚录完的那条，绝不碰
            if isDeviceCurrent(entry, deviceCurrent) {
                return Decision(base, false, "是设备当前文件")
            }

            // A 深脑已 ready
            guard let sessionId = uploaded[base], !sessionId.isEmpty else {
                return Decision(base, false, "没同步过深脑")
            }
            let probe: Probe
            if let hit = cache[sessionId] {
                probe = hit
            } else {
                do {
                    // 查询失败故意不进缓存：网络抖一下不该把整轮剩下的同会话条目一起判死。
                    if let state = try await lookup(sessionId) {
                        probe = .found(state)
                    } else {
                        probe = .missing
                    }
                    cache[sessionId] = probe
                } catch {
                    return Decision(base, false, "查深脑失败：\(brief(error))")
                }
            }
            guard case .found(let state) = probe else {
                return Decision(base, false, "深脑状态是 未知，不是 ready")
            }
            guard state.status == "ready" else {
                let shown = state.status.isEmpty ? "未知" : state.status
                return Decision(base, false, "深脑状态是 \(shown)，不是 ready")
            }
            guard let tid = state.transcriptId, !tid.isEmpty else {
                return Decision(base, false, "深脑没有转写结果")
            }

            // B/C/D 本地留档、字节、时长
            if let bad = localArchiveCheck(base, entry, dest: dest, rawDir: rawDir).0 { return bad }

            // E 冷静期
            guard let made = recordedAt(base) else {
                return Decision(base, false, "文件名里解析不出录制时间")
            }
            // 时间戳必须落在可信区间。设备掉电 RTC 归零会造出 note20000101-xxxxxx，
            // 算出来「录于 9000 多天前」，冷静期直接被绕过。未来时间同样不可信。
            guard made >= earliestPlausible, made <= now.addingTimeInterval(86400) else {
                return Decision(base, false, "文件名时间戳不可信（设备 RTC 可能没对时），不删")
            }
            let age = now.timeIntervalSince(made)
            let threshold = Double(coolingDays) * 86400
            if age < threshold {
                let left = threshold - age
                let days = Int(left / 86400)
                let hours = Int(left.truncatingRemainder(dividingBy: 86400) / 3600)
                return Decision(base, false, "还在冷静期（还差 \(days) 天 \(hours) 小时）")
            }
            return Decision(base, true,
                            "已入深脑并转写完成，本地留档完整，录于 \(Int(age / 86400)) 天前")
        }

        /// 异常文案跟 Python 版 str(exc)[:40] 对齐：截到 40 字，
        /// 不让一坨 HTML 报错体把理由列撑爆。DeepBrainError 自带 description，
        /// 走 String(describing:) 就能拿到人话；不用 localizedDescription，
        /// 那个对 Swift 原生 error 只会回「The operation couldn't be completed.」。
        private func brief(_ error: Error) -> String {
            String(String(describing: error).prefix(40))
        }
    }

    // MARK: - 共用的闸

    /// F-2 整机状态。2=未录音；nil/1/3 都算不安全，整轮全部否决。
    private static func deviceVeto(_ entries: [FileEntry], recordStatus: Int?,
                                   suffix: String) -> [Decision]? {
        guard recordStatus != 2 else { return nil }
        let label: String
        switch recordStatus {
        case 1: label = "录音中"
        case 3: label = "已暂停"
        case nil: label = "状态未知"
        case let other?: label = "状态 \(other)"
        }
        return entries.map { Decision($0.base, false, "设备\(label)\(suffix)") }
    }

    /// 设备当前文件名带完整扩展名，列表里的 base 是 20B 截断名，所以用包含判断。
    private static func isDeviceCurrent(_ entry: FileEntry, _ deviceCurrent: String?) -> Bool {
        guard let cur = deviceCurrent, !cur.isEmpty else { return false }
        let base = entry.base
        return !base.isEmpty && cur.contains(base)
    }

    /// B + C + D 三闸。第一个返回值是否决理由（nil 表示全过），第二个是本地裸包字节数。
    /// 自动模式和擦除模式共用同一份实现——同一个不变量只允许有一处判定，
    /// 两份拷贝迟早会在一边被改松。
    private static func localArchiveCheck(_ base: String, _ entry: FileEntry,
                                          dest: URL, rawDir: URL) -> (Decision?, Int) {
        let rawPath = rawDir.appendingPathComponent("\(base).opus")
        let oggPath = dest.appendingPathComponent("\(base).ogg")
        let fm = FileManager.default
        // 两份都要在：深脑 30 天后清原始音频，长期归档只剩本机这一份裸包。
        guard fm.fileExists(atPath: oggPath.path),
              let attrs = try? fm.attributesOfItem(atPath: rawPath.path),
              let size = attrs[.size] as? Int else {
            return (Decision(base, false, "本地留档不全"), 0)
        }
        // ogg 光存在不算数：封装中途崩掉会留下 0 字节文件，那时「双份留档」是假的。
        guard let oggHandle = try? FileHandle(forReadingFrom: oggPath),
              let magic = try? oggHandle.read(upToCount: 4), magic == Data("OggS".utf8) else {
            return (Decision(base, false, "ogg 留档损坏（不是 OggS 开头）"), 0)
        }
        try? oggHandle.close()
        guard size == Int(entry.size) else {
            return (Decision(base, false, "字节数对不上（本地 \(size) / 设备 \(entry.size)）"), size)
        }
        guard size % OggWrap.packetLen == 0 else {
            return (Decision(base, false, "裸包长度不是 40 的整数倍"), size)
        }
        let localSec = OggWrap.durationSeconds(rawLength: size)
        guard abs(localSec - Double(entry.time)) <= durationToleranceSec else {
            let shown = String(format: "%.1f", localSec)
            return (Decision(base, false, "时长对不上（本地 \(shown)s / 设备 \(entry.time)s）"), size)
        }
        return (nil, size)
    }
}

extension DeepBrain.SessionState {
    /// DeepBrain.SessionState 没写显式 init，逐成员 init 默认只有 internal 可见度，
    /// 跨模块（CleanupSelfTest）根本造不出来。补一个 public 工厂，让判据能离线打桩。
    public static func make(status: String, transcriptId: String? = nil,
                            errorCode: String? = nil) -> DeepBrain.SessionState {
        DeepBrain.SessionState(status: status, transcriptId: transcriptId, errorCode: errorCode)
    }
}
