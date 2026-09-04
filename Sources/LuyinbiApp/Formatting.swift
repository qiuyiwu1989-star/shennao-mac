import Foundation

/// 界面用的格式化工具。
/// 只负责「怎么显示」，不参与任何业务判断——判断一律留在引擎里。
enum Fmt {

    /// 秒 → 「1:02:03」/「12:34」
    static func duration(_ sec: Int) -> String {
        guard sec > 0 else { return "—" }
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// 字节 → 「7.2 MB」
    static func bytes(_ n: Int?) -> String {
        guard let n, n > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(n))
    }

    /// UInt32 版本（设备侧的 size / 容量都是 UInt32）
    static func bytes(_ n: UInt32?) -> String { bytes(n.map { Int($0) }) }

    /// 时间 → 「今天 20:58」/「昨天 20:58」/「8月27日 20:58」
    static func time(_ d: Date?) -> String {
        guard let d else { return "从未" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) {
            f.dateFormat = "'今天' HH:mm"
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "'昨天' HH:mm"
        } else {
            f.dateFormat = "M'月'd'日' HH:mm"
        }
        return f.string(from: d)
    }

    /// 从文件名解析录制时间，例：note20260828-205856 → 2026-08-28 20:58:56
    /// 解析不出就返回 nil，界面上退回显示文件名，不猜。
    static func recordedAt(base: String) -> Date? {
        guard let r = base.range(of: "[0-9]{8}-[0-9]{6}", options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(base[r]))
    }

    /// 录音标题：能解析出时间就显示可读时间，否则原样显示文件名。
    static func title(base: String) -> String {
        guard let d = recordedAt(base: base) else { return base }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M'月'd'日' HH:mm:ss"
        return f.string(from: d)
    }

    /// 深脑侧状态码 → 中文
    static func brainStatus(_ s: String?) -> String {
        switch s {
        case nil:            return "未推送"
        case "ready":        return "已就绪"
        case "failed":       return "失败"
        case "finalizing":   return "收尾中"
        case "processing":   return "分析中"
        case "uploading":    return "上传中"
        case "recording":    return "录制中"
        default:             return s ?? "—"
        }
    }

    /// 设备整机录音状态：1 录音中 / 2 未录音 / 3 暂停
    /// 增益：设备回的是 1/2/3，直接显示数字用户看不懂
    /// 播放器用的 m:ss / h:mm:ss
    /// note20260828-205856 -> 8月28日 20:58
    static func dateTitle(_ base: String) -> String {
        guard let m = base.range(of: #"(\d{8})-(\d{6})"#, options: .regularExpression) else { return base }
        let d = String(base[m])
        let mm = d.dropFirst(4).prefix(2), dd = d.dropFirst(6).prefix(2)
        let hh = d.dropFirst(9).prefix(2), mi = d.dropFirst(11).prefix(2)
        let ss = d.dropFirst(13).prefix(2)
        // 秒必须留着：同一分钟里录两段（比如试录一下再正式录）在列表里会长得一模一样，
        // 你根本分不清点的是哪一条。
        return "\(Int(mm) ?? 0)月\(Int(dd) ?? 0)日 \(hh):\(mi):\(ss)"
    }

    /// 录音起点 + 偏移 = 真实时钟时间。文件名里就带着起始时刻。
    static func wallClock(base: String, offset: Double) -> String? {
        guard let m = base.range(of: #"(\d{8})-(\d{6})"#, options: .regularExpression) else { return nil }
        let d = String(base[m])
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let start = f.date(from: d) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "HH:mm"
        return out.string(from: start.addingTimeInterval(offset))
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, s%3600/60, s%60)
                         : String(format: "%d:%02d", s/60, s%60)
    }

    static func gain(_ v: UInt8?) -> String {
        switch v {
        case 1: return "低"
        case 2: return "中"
        case 3: return "高"
        case .some(let x): return "\(x)"
        case .none: return "—"
        }
    }

    static func recordStatus(_ v: UInt8?) -> String {
        switch v {
        case 1: return "录音中"
        case 2: return "未录音"
        case 3: return "已暂停"
        default: return "未知"
        }
    }
}
