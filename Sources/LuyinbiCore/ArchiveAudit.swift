import AVFoundation
import Foundation

/// 本地归档体检。
///
/// **为什么必须有这个东西**：深脑 30 天后会清掉原始音频（`/api/cron/cleanup-audio`，隐私承诺）。
/// 也就是说一条录音过了 30 天，本机 `导入/原始包/<base>.opus` 就是它在世上唯一的一份。
/// 而这份归档躺在 iCloud 里——同步抽风、误删、磁盘坏块、"优化存储"把文件驱逐上云，
/// 全都**不会有任何告警**：等你想听的时候打开，才发现没了。清理判据（Cleanup）只在删设备文件
/// 那一刻看一眼留档，删完之后就再也没人回头看过。这个模块就是那个回头看的人。
///
/// 三条设计原则：
///
/// 1. **判据保守**。这份报告是人决定「要不要从深脑重下 / 要不要从设备重导」的依据，
///    误报"损坏"会让人去做没必要的重导，漏报才是真危险——所以拿不准一律 `.needsReview`，
///    绝不武断判 `.damaged`。
/// 2. **「未下载」和「丢失」必须分开**。iCloud 优化存储会把文件驱逐成占位，
///    这时候文件在云上好好的，处置办法是"点一下下载"；而"丢失"是要重导重下的。
///    把前者报成后者，人会白白去动设备甚至覆盖掉好数据。
/// 3. **裸包是本体，ogg 是派生物**。ogg 坏了、丢了、解不开，只要裸包字节完整就能就地重封装，
///    这类问题的说明里必须写清「不用重导」——否则人会为一个 5 秒就能修的问题去重跑全链路。
///
/// 只读，不修任何东西。
public enum ArchiveAudit {

    /// 时长容差。与 Cleanup 保持同一个数：清单里的秒数是设备报的整秒，
    /// 裸包是 20ms 粒度，解码器还会吃掉 pre-skip，差一两秒属于正常。
    public static let durationToleranceSec: Double = 2

    // MARK: - 结论

    public enum Status: String, Sendable, CaseIterable {
        /// 两份留档都在、字节对得上、ogg 能解码、时长吻合
        case ok
        /// 在 iCloud 上但本机没有实体。**不是丢失**：处置办法是下载，不是重导
        case notDownloaded
        /// 本机和云上都没有这个文件
        case missing
        /// 裸包字节数与清单记录不符
        case sizeMismatch
        /// 明确坏了：0 字节、魔数不对、长度不是 40 的整数倍
        case damaged
        /// 拿不准，要人看一眼。解不开、时长对不上、属性读不到都归这里
        case needsReview

        public var label: String {
            switch self {
            case .ok: return "完好"
            case .notDownloaded: return "未下载"
            case .missing: return "缺失"
            case .sizeMismatch: return "字节数不符"
            case .damaged: return "损坏"
            case .needsReview: return "需要人看一眼"
            }
        }

        /// 只有 ok 算健康。未下载虽然不等于丢失，但"此刻本机没有这份归档"本身就是风险，
        /// 不能混进健康数里让人安心。
        public var isHealthy: Bool { self == .ok }
    }

    /// 一条录音的体检结果。
    public struct Item: Sendable, Equatable {
        public let base: String
        /// 清单键里第三段：设备报的字节数
        public let expectedBytes: Int
        /// 清单键里第二段：设备报的秒数
        public let expectedSeconds: Int
        public let status: Status
        /// 一句中文，直接给人看的
        public let detail: String
        public let rawBytes: Int?
        public let oggBytes: Int?
        public let decodedSeconds: Double?
        /// 裸包在本机、字节数对得上、且是 40 的整数倍。
        /// 为真时任何 ogg 侧的问题都能就地重封装修好，不需要重导设备也不需要从深脑重下。
        public let rawIntact: Bool
    }

    /// 整体汇总。
    public struct Report: Sendable {
        public let items: [Item]
        /// 磁盘上有裸包、清单里却没有记录的。不算故障，但值得人看一眼：
        /// 要么是清单丢了条目，要么是手工放进来的文件。
        public let unlistedRawPackets: [String]

        public var total: Int { items.count }
        public var healthy: Int { items.filter { $0.status.isHealthy }.count }
        public var problems: Int { total - healthy }

        /// 按 Status.allCases 的顺序给出非零计数，输出稳定可 diff。
        public var counts: [(status: Status, count: Int)] {
            Status.allCases.compactMap { s in
                let n = items.filter { $0.status == s }.count
                return n > 0 ? (s, n) : nil
            }
        }

        public var summary: String {
            if total == 0 { return "清单里没有任何录音，无可体检" }
            let detail = counts.map { "\($0.status.label) \($0.count)" }.joined(separator: "，")
            return "共 \(total) 条：\(detail)"
        }

        /// 有没有需要人处置的。接界面/通知时用这个当判据。
        public var hasProblems: Bool { problems > 0 || !unlistedRawPackets.isEmpty }
    }

    // MARK: - 入口

    public static func run(paths: SyncPaths) -> Report {
        run(dest: paths.dest, rawDir: paths.rawPackets,
            manifest: SyncManifest.load(from: paths.manifest))
    }

    public static func run(dest: URL, rawDir: URL, manifest: SyncManifest) -> Report {
        var items: [Item] = []
        var listedBases = Set<String>()

        for (key, entry) in manifest.imported {
            guard let parsed = parseKey(key) else {
                // 键的格式不认识就别猜。猜错了会把一条好录音报成坏的，或者反过来。
                items.append(Item(base: key, expectedBytes: entry.bytes, expectedSeconds: 0,
                                  status: .needsReview,
                                  detail: "清单里这条的键格式不认识（\(key)），没法体检",
                                  rawBytes: nil, oggBytes: nil, decodedSeconds: nil,
                                  rawIntact: false))
                continue
            }
            listedBases.insert(parsed.base)
            items.append(audit(base: parsed.base,
                               expectedBytes: parsed.bytes,
                               expectedSeconds: parsed.seconds,
                               oggName: entry.file.isEmpty ? "\(parsed.base).ogg" : entry.file,
                               recordedBytes: entry.bytes,
                               dest: dest, rawDir: rawDir))
        }

        // 文件名就是时间戳，倒序即最新在前——与界面其它列表一致
        items.sort { $0.base > $1.base }

        let unlisted = (try? FileManager.default.contentsOfDirectory(atPath: rawDir.path))?
            .filter { $0.hasSuffix(".opus") }
            .map { SyncPlanner.normalizedBase($0) }
            .filter { !listedBases.contains($0) }
            .sorted() ?? []

        return Report(items: items, unlistedRawPackets: unlisted)
    }

    /// 单条体检。抽出来是为了自测能一条一条造情况。
    public static func audit(base: String, expectedBytes: Int, expectedSeconds: Int,
                             oggName: String? = nil, recordedBytes: Int? = nil,
                             dest: URL, rawDir: URL) -> Item {
        let rawURL = rawDir.appendingPathComponent("\(base).opus")
        let oggURL = dest.appendingPathComponent(oggName ?? "\(base).ogg")
        let rawProbe = probe(rawURL)
        let oggProbe = probe(oggURL)

        func item(_ status: Status, _ detail: String,
                  raw: Int? = nil, ogg: Int? = nil, decoded: Double? = nil,
                  rawIntact: Bool = false) -> Item {
            Item(base: base, expectedBytes: expectedBytes, expectedSeconds: expectedSeconds,
                 status: status, detail: detail, rawBytes: raw, oggBytes: ogg,
                 decodedSeconds: decoded, rawIntact: rawIntact)
        }

        // ── 0. 清单自己先得自洽 ────────────────────────────────
        // 键里的字节数和条目里的 bytes 是同一件事写了两遍。两边不一样时不知道该信谁，
        // 拿一个错的期望值去比对只会造出假的"字节数不符"。
        if let recorded = recordedBytes, recorded != expectedBytes {
            return item(.needsReview,
                        "清单自身对不上：键里记 \(expectedBytes) 字节、条目里写 \(recorded) 字节，"
                        + "先弄清哪个是真的再体检")
        }

        // ── 1. 裸包：这是唯一的一份本体 ────────────────────────
        switch rawProbe {
        case .notDownloaded:
            let extra = oggProbe.isNotDownloaded ? "（ogg 也在云上）" : ""
            return item(.notDownloaded,
                        "裸包被 iCloud「优化存储」挪到云上、本机没有实体\(extra)——"
                        + "文件本身还在，下载回来即可，不用重导设备")

        case .unreadable(let why):
            return item(.needsReview, "裸包读不到（\(why)），可能是权限或磁盘问题，需要人看一眼")

        case .absent:
            switch oggProbe {
            case .absent:
                return item(.missing,
                            "裸包和 ogg 在本机都没有（清单记 \(expectedBytes) 字节 / "
                            + "\(expectedSeconds) 秒）——深脑 30 天后会清原始音频，"
                            + "这条可能已经彻底没了，尽快去深脑确认")
            case .notDownloaded:
                return item(.notDownloaded,
                            "裸包不在本机，ogg 是 iCloud 占位——先把 ogg 下载回来再判断裸包是不是真丢了")
            case .present(let n):
                return item(.missing,
                            "裸包缺失，只剩封装好的 ogg（\(n) 字节）：还能播，"
                            + "但设备原始码流没有了，重封装这条路断了")
            case .unreadable(let why):
                return item(.needsReview, "裸包不在本机，ogg 也读不到（\(why)），需要人看一眼")
            }

        case .present(let rawSize):
            // ── 2. 字节数必须与清单一致 ────────────────────────
            guard rawSize == expectedBytes else {
                let diff = rawSize - expectedBytes
                let sign = diff > 0 ? "多" : "少"
                return item(.sizeMismatch,
                            "裸包 \(rawSize) 字节，清单记 \(expectedBytes) 字节，"
                            + "\(sign)了 \(abs(diff)) 字节——传输没传完或文件被动过",
                            raw: rawSize, ogg: oggProbe.bytes)
            }

            // ── 3. 长度必须是 40 的整数倍 ──────────────────────
            // 设备吐的是 40 字节定长 opus 包。除不尽 = 尾巴上挂着半个包 = 被截断或损坏。
            guard rawSize % OggWrap.packetLen == 0 else {
                let extra = rawSize % OggWrap.packetLen
                return item(.damaged,
                            "裸包 \(rawSize) 字节不是 40 的整数倍（尾部多出 \(extra) 字节），"
                            + "设备吐的是 40B 定长包，说明文件被截断或损坏",
                            raw: rawSize, ogg: oggProbe.bytes)
            }

            let rawSeconds = OggWrap.durationSeconds(rawLength: rawSize)

            // ── 4. 裸包算出的时长要对得上清单 ──────────────────
            // 字节数已经和清单一致了，这里再对不上，说明清单里的秒数和字节数本身矛盾，
            // 不是文件的问题——所以是 needsReview 不是 damaged。
            if abs(rawSeconds - Double(expectedSeconds)) > durationToleranceSec {
                return item(.needsReview,
                            "裸包 \(rawSize) 字节算出 \(fmt(rawSeconds))s，清单却记 \(expectedSeconds)s，"
                            + "清单和文件对不上，需要人看一眼",
                            raw: rawSize, ogg: oggProbe.bytes, rawIntact: true)
            }

            // 到这里裸包是完好的：后面所有问题都能靠重封装解决。
            let repairable = "裸包完好，重新封装即可，不用重导"

            // ── 5. ogg 在不在、是不是真的 ──────────────────────
            switch oggProbe {
            case .notDownloaded:
                return item(.notDownloaded,
                            "裸包完好，但 ogg 被 iCloud 挪到云上、本机没有实体——"
                            + "下载回来即可，实在懒得等也可以直接从裸包重封装",
                            raw: rawSize, rawIntact: true)
            case .unreadable(let why):
                return item(.needsReview, "ogg 读不到（\(why)）；\(repairable)",
                            raw: rawSize, rawIntact: true)
            case .absent:
                return item(.needsReview, "ogg 不在本机；\(repairable)",
                            raw: rawSize, rawIntact: true)
            case .present(let oggSize):
                guard oggSize > 0 else {
                    return item(.damaged, "ogg 是 0 字节（封装中途崩过，这种情况真实发生过）；\(repairable)",
                                raw: rawSize, ogg: 0, rawIntact: true)
                }
                guard magicIsOggS(oggURL) else {
                    return item(.damaged, "ogg 首四字节不是 OggS，这不是一个 Ogg 文件；\(repairable)",
                                raw: rawSize, ogg: oggSize, rawIntact: true)
                }

                // ── 6. ogg 能不能解码 ──────────────────────────
                // 只开文件读头和总帧数，不解全曲：一小时的录音整解要几秒，体检不值这个钱。
                guard let decoded = decodeSeconds(oggURL) else {
                    return item(.needsReview,
                                "ogg 头是对的但解码器打不开，可能是封装出了问题；\(repairable)",
                                raw: rawSize, ogg: oggSize, rawIntact: true)
                }

                // ── 7. 解出来的时长要对得上 ────────────────────
                // 能解开但时长差很多：多半是封装时被截断。仍然只报"需要人看一眼"——
                // 解码器对残缺流的行为不完全可预期，武断判损坏会让人白跑一趟。
                if abs(decoded - Double(expectedSeconds)) > durationToleranceSec {
                    return item(.needsReview,
                                "ogg 解出 \(fmt(decoded))s，清单记 \(expectedSeconds)s，"
                                + "差 \(fmt(abs(decoded - Double(expectedSeconds))))s 超过容差；\(repairable)",
                                raw: rawSize, ogg: oggSize, decoded: decoded, rawIntact: true)
                }

                return item(.ok,
                            "完好（裸包 \(rawSize)B ≈ \(fmt(rawSeconds))s，ogg 可解码 \(fmt(decoded))s）",
                            raw: rawSize, ogg: oggSize, decoded: decoded, rawIntact: true)
            }
        }
    }

    // MARK: - 清单键

    /// `note20260102-105203.|28|57240` → (base, 28 秒, 57240 字节)。
    /// 键的第一段是 20B 截断名、**结尾那个点是真的**，所以 base 要走 normalizedBase 去点，
    /// 与 SyncPlanner 保持同一份口径。
    public static func parseKey(_ key: String) -> (base: String, seconds: Int, bytes: Int)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let seconds = Int(parts[1]), let bytes = Int(parts[2]),
              seconds >= 0, bytes >= 0 else { return nil }
        let base = SyncPlanner.normalizedBase(String(parts[0]))
        guard !base.isEmpty else { return nil }
        return (base, seconds, bytes)
    }

    // MARK: - 文件探针

    enum Probe {
        case present(Int)
        /// iCloud 上有、本机没有实体
        case notDownloaded
        case absent
        /// 存在但属性读不出来（权限 / IO 错误）——不知道好坏，交给人
        case unreadable(String)

        var bytes: Int? { if case .present(let n) = self { return n }; return nil }
        var isNotDownloaded: Bool { if case .notDownloaded = self { return true }; return false }
    }

    /// 判断一个文件此刻在不在本机。
    ///
    /// iCloud 有两种"文件不在本机"的表现形式，两种都得认：
    ///   * 新式（FileProvider）：真名还在，`ubiquitousItemDownloadingStatus == .notDownloaded`；
    ///   * 老式：真名在 POSIX 层直接消失，同目录下留一个 `.<name>.icloud` 占位。
    /// 只用 `fileExists` 的话，前一种会被当成"存在但字节数不对"，后一种会被当成"丢失"——
    /// 两个都是危险的误报。
    static func probe(_ url: URL) -> Probe {
        let fm = FileManager.default
        if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                     .fileSizeKey]) {
            if v.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
            if let size = v.fileSize { return .present(size) }
        }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { return .notDownloaded }
        guard fm.fileExists(atPath: url.path) else { return .absent }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return .unreadable("属性读不到") }
        return .present(size)
    }

    /// 首四字节是不是 OggS。存在但 0 字节的 ogg 真实发生过，光看"文件在不在"会漏掉。
    static func magicIsOggS(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4) else { return false }
        return magic == Data("OggS".utf8)
    }

    /// 用 AVAudioFile 读时长。**只开文件、只读元数据**，不把音频解出来——
    /// 一小时的录音整解要几秒钟，体检要能几百毫秒跑完全库才有人愿意让它定时跑。
    static func decodeSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
