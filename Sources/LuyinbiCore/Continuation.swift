import Foundation

/// 录音的真实起始时刻，以及「被设备切开的同一场会议」的识别与拼接。
///
/// 两件事都源自同一个事实：**录音笔有 3 小时上限**，到点自动断开、隔 1 秒开下一条。
/// 于是一场三个半小时的会在深脑里变成两场互不相干的会——说话人各认一遍、
/// 洞察各出一份、承诺分散在两处。而深脑那边记的时间还不是录音时间，
/// 是上传时间（`recording_sessions.started_at` 是 `default now()`，
/// 建会话接口压根不收 startedAt）。
public enum Continuation {

    /// 录音笔的单文件上限。实测这条 3 小时录音是 10801 秒。
    ///
    /// 用「≥ 10700」而不是「== 10801」：固件版本之间可能差几秒，
    /// 卡死一个精确值会让判据在别的设备上静默失效。
    public static let deviceCapSeconds = 10_700.0

    /// 两段之间允许的最大空档。实测那次是 **1 秒**。
    ///
    /// 卡得很死是有原因的：判宽了会把两场真正独立的会议粘成一条，
    /// 那比切成两条糟得多——切开还能人工看出来，粘错了正文就串了。
    public static let maxGapSeconds = 5.0

    /// 从文件名解析真实录音起始时刻。`note20260829-170356` → 2026-08-29 17:03:56。
    ///
    /// 设备的 RTC 掉电会重置到 2026-01-02 这类假日期，所以调用方要自己判断
    /// 拿到的时间合不合理（Cleanup 里那条 EARLIEST_PLAUSIBLE 就是干这个的）。
    public static func startedAt(base: String) -> Date? {
        guard let m = base.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current          // 设备写的是本地时间
        return f.date(from: String(base[m]))
    }

    /// 后一条是不是前一条**被设备切断后的续接**。
    ///
    /// 两个条件必须同时成立：
    ///   1. 前一条几乎顶满设备上限——只有撞上限才会产生这种无缝续接；
    ///      人手停了再开，时长不会正好是 3 小时。
    ///   2. 空档极短。
    ///
    /// 少任何一条都不合。只看空档的话，「录完一段马上补录一句」会被误合；
    /// 只看时长的话，「录满三小时，晚上又开一场」也会被误合。
    public static func isContinuation(prevBase: String, prevSeconds: Double,
                                      nextBase: String) -> Bool {
        guard prevSeconds >= deviceCapSeconds else { return false }
        guard let a = startedAt(base: prevBase), let b = startedAt(base: nextBase) else { return false }
        let gap = b.timeIntervalSince(a.addingTimeInterval(prevSeconds))
        return gap >= 0 && gap <= maxGapSeconds
    }

    /// 把按时间排好的录音分组：同一场被切开的归成一组，其余各自一组。
    ///
    /// 输入必须**按起始时刻升序**。返回的每一组至少一个元素，顺序与输入一致。
    public static func groupContinuations(_ items: [(base: String, seconds: Double)]) -> [[String]] {
        var out: [[String]] = []
        for it in items {
            if let last = out.last?.last,
               let lastSecs = items.first(where: { $0.base == last })?.seconds,
               isContinuation(prevBase: last, prevSeconds: lastSecs, nextBase: it.base) {
                out[out.count - 1].append(it.base)
            } else {
                out.append([it.base])
            }
        }
        return out
    }

    /// 拼接裸 opus 包。
    ///
    /// 设备吐的是定长 40 字节的 opus 帧（20 ms 一包），首尾相接就是合法的下一段，
    /// **不需要重编码**——所以拼接零损耗、也不会引入编码代差。
    ///
    /// 任何一段长度除不尽 40 就拒绝：那说明它本身是截断的，
    /// 拼上去会让整条时间线从那一点起全部错位，而且错得很难看出来。
    public static func concatRawPackets(_ parts: [[UInt8]]) -> [UInt8]? {
        guard !parts.isEmpty else { return nil }
        for p in parts where p.isEmpty || p.count % 40 != 0 { return nil }
        return parts.flatMap { $0 }
    }
}

// MARK: - 录音时刻的现场证据

/// 「这条录音真正开始于什么时候」的现场证据。
///
/// **为什么需要它。** 录音时刻现在完全取自文件名，而文件名是笔用自己的
/// RTC 写的。2026-09-11 实测：一条今天下午录的会议被命名成
/// `note20260217-085152`，带着错了 206 天的日期进了深脑的 started_at
/// ——深脑整套按证据时间轴立，这种错比没有日期更伤。
///
/// 而破案靠的东西，客户端当时就握在手里：同步日志里
/// 「15:08 那次列表没在录 / 15:18 那次正在录」。
/// **真实开始必然夹在这两个时刻之间**，跟笔的时钟准不准完全无关。
/// 这个结构就是把这份证据留下来，别再扔掉。
public struct LiveWitness: Codable, Equatable, Sendable {
    /// 最后一次确认设备**没在录**的时刻。真实开始必然晚于它。
    public var notRecordingAt: Date?
    /// 第一次看到设备**正在录这一条**的时刻。真实开始必然早于它。
    public var firstSeenLiveAt: Date
    public init(notRecordingAt: Date?, firstSeenLiveAt: Date) {
        self.notRecordingAt = notRecordingAt; self.firstSeenLiveAt = firstSeenLiveAt
    }
}

extension Continuation {
    /// 送给深脑的录音时刻：优先信文件名，信不过就用现场证据夹出来的窗口中点。
    ///
    /// 窗口下界取两者中**更晚**的那个：
    ///   · 最后一次确认「没在录」——它之后才可能开始；
    ///   · 第一次看到「正在录」减去总时长——再早就录不完这么长。
    /// 上界就是第一次看到「正在录」的时刻。
    ///
    /// 文件名落在窗口里（留一点容差）就照用——笔的时钟准的时候本该如此，
    /// 而且文件名比窗口中点精确。落在窗口外很远，就是笔的时钟不对，改用中点。
    ///
    /// - Returns: `corrected` 为 true 表示文件名被判定不可信、这里换了值。
    ///   调用方要把这件事写进日志——**静默改掉一个时间戳比用错的更糟**。
    public static func trueStart(base: String, witness: LiveWitness?, durationSec: Double,
                                 tolerance: TimeInterval = 1800)
    -> (at: Date?, corrected: Bool) {
        let fromName = startedAt(base: base)
        guard let w = witness else { return (fromName, false) }
        let hi = w.firstSeenLiveAt
        let byDuration = hi.addingTimeInterval(-max(0, durationSec))
        let lo = max(w.notRecordingAt ?? byDuration, byDuration)
        guard lo <= hi else { return (fromName, false) }      // 证据自相矛盾就不动
        if let n = fromName,
           n >= lo.addingTimeInterval(-tolerance), n <= hi.addingTimeInterval(tolerance) {
            return (n, false)
        }
        return (Date(timeIntervalSince1970:
                     (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2), true)
    }
}
