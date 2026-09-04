import Foundation

/// 本机转写搜索。
///
/// 为什么必须在本机建索引，而不是每次去问深脑：
/// 实测深脑自托管 Supabase 上**任何带登录态的查询都要 2 秒**（裸连接 49 毫秒，
/// 所以不是网络，是服务端 RLS）。搜索是「边打字边出结果」的交互，
/// 一次 2 秒等于这个功能不存在。所以把「我这台机器导入过的录音」的逐句转写
/// 整份拉到本地存成一份 JSON，之后搜索一次网络都不走。
///
/// 索引只覆盖 manifest.uploaded 里的录音——那正是「我这台机器导入过的」，
/// 和深脑网页的全局搜索（搜整个知识库）刻意不是一回事。
///
/// 落盘位置：`<root>/out/search-index.json`。放 out/ 而不是 导入/：
/// 导入/ 目录是和 Python 版共享的真相（manifest + 音频），派生物不该混进去，
/// 索引丢了随时能重建，不是数据。

// MARK: - 索引数据

/// 转写里的一句话。JSON 键刻意用单字母：句子是索引的绝大部分体积，
/// 键名写全会让文件凭空大一半。
public struct IndexedLine: Codable, Sendable, Equatable {
    public let speaker: String
    public let text: String
    public let startMs: Int

    public init(speaker: String, text: String, startMs: Int) {
        self.speaker = speaker; self.text = text; self.startMs = startMs
    }

    private enum CodingKeys: String, CodingKey {
        case speaker = "s", text = "t", startMs = "ms"
    }
}

/// 一条录音在索引里的样子。
public struct IndexedRecording: Codable, Sendable, Equatable {
    /// 本机文件名主干，如 note20260828-205856。它是本机侧的主键，
    /// onPick 回调把它交回给界面去定位音频文件。
    public let base: String
    public let transcriptId: String
    /// 深脑生成的标题。是**分析**的产物，没跑过分析就是 nil——
    /// 这时候界面退回按文件名里的时间显示，别把 note2026... 当标题给人看。
    public let title: String?
    public let recordedAt: Date?
    public let lines: [IndexedLine]
    public let indexedAt: Date

    public init(base: String, transcriptId: String, title: String?,
                recordedAt: Date?, lines: [IndexedLine], indexedAt: Date = Date()) {
        self.base = base; self.transcriptId = transcriptId; self.title = title
        self.recordedAt = recordedAt; self.lines = lines; self.indexedAt = indexedAt
    }
}

/// 索引文件的顶层结构。带版本号：以后归一化规则一改，老索引整份作废重建，
/// 不能让新代码去搜按旧规则归一化过的东西。
struct SearchIndexFile: Codable {
    static let currentVersion = 1
    var version: Int = SearchIndexFile.currentVersion
    var updatedAt: Date = Date()
    var records: [IndexedRecording] = []
}

// MARK: - 命中

/// 命中片段的一段。界面把 isMatch 的那几段高亮，其余按正文显示。
/// 这里给「切好的段」而不是给 Range：Range<String.Index> 跨不了并发边界，
/// 而且界面还得自己再切一遍，容易切错。
public struct SnippetPart: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
    public let isMatch: Bool
}

/// 一条命中 = **具体哪一句**，不是「哪条录音」。
/// startMs 是这一句在录音里的起点，界面点一下就能跳到那一秒播放。
public struct SearchHit: Identifiable, Sendable, Equatable {
    public let id: String
    public let base: String
    public let transcriptId: String
    /// 深脑标题，可能没有；界面自己决定退回显示什么。
    public let title: String?
    public let recordedAt: Date?
    public let speaker: String
    /// 命中的整句原文
    public let text: String
    public let startMs: Int
    /// 带上下文的片段，已切成高亮段/普通段
    public let parts: [SnippetPart]

    public var startSeconds: Double { Double(startMs) / 1000 }
}

/// 重建报告。失败要逐条说明——「有几条没进索引」和「为什么」是两回事，
/// 只报个数会让人以为搜不到是搜索坏了。
public struct RebuildReport: Sendable {
    public var indexed: Int = 0
    public var skipped: Int = 0
    public var lines: Int = 0
    /// base -> 原因
    public var failed: [String: String] = [:]
    public var elapsed: TimeInterval = 0

    public var summary: String {
        var parts: [String] = []
        if indexed > 0 { parts.append("新建 \(indexed) 条") }
        if skipped > 0 { parts.append("已有 \(skipped) 条") }
        if !failed.isEmpty { parts.append("\(failed.count) 条没取到") }
        if parts.isEmpty { parts.append("没有可索引的录音") }
        return parts.joined(separator: "，") + String(format: "，用时 %.1f 秒", elapsed)
    }
}

// MARK: - 归一化

/// 归一化后的文本 + 回原文的位置映射。
///
/// 为什么要自己做而不是直接 `String.folding`：折叠是整串做的，个别字符会一变多
/// （半角片假名带浊点之类），一旦长度变了，命中位置就对不回原文，高亮会错位。
/// 所以逐字符折叠，折叠结果不是恰好一个字符就退回原字符，强行保住 1:1。
struct NormalizedText {
    /// 归一化后的字符序列
    let chars: [Character]
    /// chars[i] 来自原文的第几个字符
    let origin: [Int]

    /// 归一化做三件事，都是为了「用户心里觉得一样的东西要能搜到」：
    ///   1. 大小写：Spark / spark / SPARK
    ///   2. 全角半角：Ｓｐａｒｋ、２０２６、全角逗号
    ///   3. 去掉所有空白：中文转写里「金 Spark」和「金Spark」全看 ASR 心情，
    ///      用户不可能记得当时空格打在哪。去空白后两种都能搜到。
    ///
    /// 刻意**不做分词**：中文分词器会把「金 Spark」切碎，反而搜不到；
    /// 直接子串匹配在这个数据量下既准又快。
    static func make(_ s: String) -> NormalizedText {
        var chars: [Character] = []
        var origin: [Int] = []
        chars.reserveCapacity(s.count)
        origin.reserveCapacity(s.count)
        for (i, ch) in s.enumerated() {
            if ch.isWhitespace || ch.isNewline { continue }
            let folded = String(ch).folding(options: [.caseInsensitive, .widthInsensitive],
                                            locale: nil)
            if folded.count == 1, let c = folded.first {
                chars.append(c)
            } else {
                // 折叠会改变长度的极少数字符：宁可不折叠，也不能让映射错位
                chars.append(ch)
            }
            origin.append(i)
        }
        return NormalizedText(chars: chars, origin: origin)
    }
}

// MARK: - 索引本体

/// 本机索引。
///
/// 标 @MainActor 与 SyncEngine 一致：界面直接持有它，`search` 是同步调用
/// （本地扫描是毫秒级，没必要给每次按键加一次 actor 跳转）；
/// `rebuild` / `upsert` 是 async，网络等待期间主线程照样跑。
@MainActor
public final class LocalSearch {

    /// 一句话的检索体。归一化只在建索引/加载时做一次，
    /// 绝不能放在每次按键的路径上——那才是真正会卡的地方。
    private struct Prepared {
        let norm: NormalizedText
        let origChars: [Character]
    }

    public let indexURL: URL
    private var file = SearchIndexFile()
    /// 与 file.records 一一对应，下标同步
    private var prepared: [[Prepared]] = []

    public init(paths: SyncPaths) {
        self.indexURL = paths.root
            .appendingPathComponent("out")
            .appendingPathComponent("search-index.json")
        reload()
    }

    /// 给自测/自定义位置用
    public init(indexURL: URL) {
        self.indexURL = indexURL
        reload()
    }

    // MARK: 统计（界面上告诉用户索引里到底有什么）

    public var recordCount: Int { file.records.count }
    public var lineCount: Int { file.records.reduce(0) { $0 + $1.lines.count } }
    public var updatedAt: Date? { file.records.isEmpty ? nil : file.updatedAt }
    public var isEmpty: Bool { file.records.isEmpty }
    public var indexedBases: Set<String> { Set(file.records.map(\.base)) }
    public var byteSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.size] as? Int) ?? 0
    }

    // MARK: 读写磁盘

    public func reload() {
        guard let data = try? Data(contentsOf: indexURL) else {
            file = SearchIndexFile(); prepared = []; return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(SearchIndexFile.self, from: data),
              f.version == SearchIndexFile.currentVersion else {
            // 版本对不上就当没有：归一化规则变过，旧索引搜出来的位置是错的
            file = SearchIndexFile(); prepared = []; return
        }
        file = f
        prepared = f.records.map { Self.prepare($0) }
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        file.updatedAt = Date()
        let data = try enc.encode(file)
        // 先写临时文件再替换：索引可能几 MB，写一半被杀掉会留下半个 JSON，
        // 下次启动解不出来就等于索引没了。
        let tmp = indexURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: indexURL)
        try FileManager.default.moveItem(at: tmp, to: indexURL)
    }

    private static func prepare(_ r: IndexedRecording) -> [Prepared] {
        r.lines.map { Prepared(norm: NormalizedText.make($0.text), origChars: Array($0.text)) }
    }

    // MARK: - 搜索

    /// 纯本地子串搜索。9 条录音（约 2000 句）实测在 1 毫秒量级。
    ///
    /// 排序：按录音新到旧，录音内按时间先后。刻意不做相关度打分——
    /// 用户问的是「上次讲到 X 的是哪场」，最近的那场排最前就是他要的答案。
    public func search(_ query: String, limit: Int = 200) -> [SearchHit] {
        let q = NormalizedText.make(query)
        guard !q.chars.isEmpty else { return [] }

        var hits: [SearchHit] = []
        outer: for (ri, record) in file.records.enumerated() {
            guard ri < prepared.count else { break }
            let lines = prepared[ri]
            for (li, line) in record.lines.enumerated() {
                guard li < lines.count else { break }
                let p = lines[li]
                let ranges = Self.matches(haystack: p.norm.chars, needle: q.chars)
                guard !ranges.isEmpty else { continue }
                // 归一化下标 → 原文字符下标
                let origRanges = ranges.map { (p.norm.origin[$0.lowerBound],
                                               p.norm.origin[$0.upperBound - 1] + 1) }
                hits.append(SearchHit(
                    id: "\(record.base)#\(line.startMs)#\(li)",
                    base: record.base,
                    transcriptId: record.transcriptId,
                    title: record.title,
                    recordedAt: record.recordedAt,
                    speaker: line.speaker,
                    text: line.text,
                    startMs: line.startMs,
                    parts: Self.snippet(p.origChars, matches: origRanges)))
                if hits.count >= limit { break outer }
            }
        }
        return hits
    }

    /// 朴素子串扫描。数据量在这里（十万字量级）朴素就够，
    /// 上 KMP/后缀数组的收益还不如少一次 JSON 解析。
    private static func matches(haystack: [Character], needle: [Character]) -> [Range<Int>] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var out: [Range<Int>] = []
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            var k = 0
            while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
            if k == needle.count {
                out.append(i ..< (i + needle.count))
                i += needle.count          // 不重叠，免得 "aa" 搜 "aaa" 出两条几乎一样的命中
            } else {
                i += 1
            }
        }
        return out
    }

    /// 截一段带上下文的片段，并标出匹配位置。
    /// 窗口不居中而是偏左：命中词前面留一点、后面留多一点，
    /// 因为「他接着说了什么」比「他之前说了什么」更常是用户想看的。
    private static func snippet(_ chars: [Character], matches: [(Int, Int)],
                               before: Int = 20, after: Int = 60) -> [SnippetPart] {
        guard let first = matches.first, let lastM = matches.last else { return [] }
        let start = max(0, first.0 - before)
        let end = min(chars.count, max(lastM.1, first.1 + after))

        var parts: [SnippetPart] = []
        var id = 0
        func push(_ range: Range<Int>, _ isMatch: Bool) {
            guard !range.isEmpty else { return }
            parts.append(SnippetPart(id: id, text: String(chars[range]), isMatch: isMatch))
            id += 1
        }
        if start > 0 { parts.append(SnippetPart(id: -1, text: "…", isMatch: false)) }

        var cursor = start
        for (a, b) in matches {
            guard a >= cursor, a < end else { continue }
            push(cursor ..< a, false)
            push(a ..< min(b, end), true)
            cursor = min(b, end)
        }
        push(cursor ..< end, false)
        if end < chars.count { parts.append(SnippetPart(id: -2, text: "…", isMatch: false)) }
        return parts
    }

    // MARK: - 建索引

    /// 从深脑拉取并写盘。
    ///
    /// **并发拉取**是这个函数的重点：单条要两个往返（查会话拿 transcript_id、拉 segments），
    /// 每个往返 2 秒，串行 9 条就是 36 秒——用户不会等。
    /// 并发之后总耗时约等于「两轮 2 秒」，跟条数基本无关。
    ///
    /// - Parameters:
    ///   - transcriptIds: 调用方已经知道的 base → transcriptId（AppModel 轮询时本来就在攒）。
    ///     给了就省掉「查会话」那一轮，整个重建只剩一轮网络。
    ///   - force: 默认跳过已在索引里的录音。转写一旦 ready 就不再变，
    ///     所以增量重建几乎是零成本；只有改过说话人标签之类才需要 force。
    ///   - concurrency: 并发上限。不设上限的话几十条会同时打过去，
    ///     那台机器本来就是共享 CPU，容易把自己拖垮。
    @discardableResult
    public func rebuild(brain: DeepBrain,
                        manifest: SyncManifest,
                        transcriptIds: [String: String] = [:],
                        force: Bool = false,
                        concurrency: Int = 6,
                        onProgress: ((Int, Int) -> Void)? = nil) async -> RebuildReport {
        let t0 = Date()
        var report = RebuildReport()

        let have = indexedBases
        // 按文件名倒序：新的先进索引，用户最可能搜的是最近这几场
        let all = manifest.uploaded.sorted { $0.key > $1.key }
        let todo = all.filter { force || !have.contains($0.key) }
        report.skipped = all.count - todo.count

        guard !todo.isEmpty else {
            report.elapsed = Date().timeIntervalSince(t0)
            report.lines = lineCount
            onProgress?(0, 0)
            return report
        }

        var fetched: [IndexedRecording] = []
        var done = 0
        let total = todo.count
        onProgress?(0, total)

        await withTaskGroup(of: FetchOutcome.self) { group in
            var it = todo.makeIterator()
            var launched = 0
            while launched < concurrency, let job = it.next() {
                let tid = transcriptIds[job.key]
                group.addTask { await Self.fetch(base: job.key, sessionId: job.value,
                                                 transcriptId: tid, brain: brain) }
                launched += 1
            }
            while let outcome = await group.next() {
                done += 1
                onProgress?(done, total)
                switch outcome {
                case .ok(let rec): fetched.append(rec)
                case .fail(let base, let why): report.failed[base] = why
                }
                if let job = it.next() {
                    let tid = transcriptIds[job.key]
                    group.addTask { await Self.fetch(base: job.key, sessionId: job.value,
                                                     transcriptId: tid, brain: brain) }
                }
            }
        }

        for rec in fetched { applyUpsert(rec) }
        report.indexed = fetched.count
        report.lines = lineCount
        report.elapsed = Date().timeIntervalSince(t0)
        try? save()
        return report
    }

    /// 单条更新。新导入一条录音、或者刚改完说话人指认时调它——只补这一条，不动别的。
    /// 返回 false 表示深脑那边还没出转写（还在分析中），过一会儿再来。
    @discardableResult
    public func upsert(base: String, sessionId: String,
                       transcriptId: String? = nil,
                       brain: DeepBrain) async -> Bool {
        switch await Self.fetch(base: base, sessionId: sessionId,
                                transcriptId: transcriptId, brain: brain) {
        case .ok(let rec):
            applyUpsert(rec)
            try? save()
            return true
        case .fail:
            return false
        }
    }

    /// 把一条录音从索引里拿掉（比如深脑那边删了）。
    @discardableResult
    public func remove(base: String) -> Bool {
        guard let i = file.records.firstIndex(where: { $0.base == base }) else { return false }
        file.records.remove(at: i)
        if i < prepared.count { prepared.remove(at: i) }
        try? save()
        return true
    }

    /// 就地替换或插入，并维持「新到旧」的排序 —— 搜索结果的顺序直接来自这里。
    private func applyUpsert(_ rec: IndexedRecording) {
        if let i = file.records.firstIndex(where: { $0.base == rec.base }) {
            file.records[i] = rec
            if i < prepared.count { prepared[i] = Self.prepare(rec) }
        } else {
            file.records.append(rec)
            prepared.append(Self.prepare(rec))
        }
        // 排序必须两个数组一起做，否则 prepared 和 records 会错位，
        // 搜出来的句子会挂到别条录音上——而且看起来毫无破绽。
        let order = zip(file.records, prepared)
            .sorted { $0.0.base > $1.0.base }
        file.records = order.map(\.0)
        prepared = order.map(\.1)
    }

    private enum FetchOutcome: Sendable {
        case ok(IndexedRecording)
        case fail(String, String)
    }

    /// 拉一条。两轮网络：先确认 transcript_id，再拉 segments + 标题（这两个并行）。
    private static func fetch(base: String, sessionId: String,
                              transcriptId: String?, brain: DeepBrain) async -> FetchOutcome {
        var tid = transcriptId
        if tid == nil || tid?.isEmpty == true {
            do {
                let st = try await brain.sessionState(sessionId)
                tid = st.transcriptId
            } catch {
                return .fail(base, "查会话失败：\(error)")
            }
        }
        guard let tid, !tid.isEmpty else { return .fail(base, "深脑还没出转写") }

        do {
            async let segsTask = brain.segments(transcriptId: tid)
            async let titleTask = brain.transcriptTitle(tid)
            let segs = try await segsTask
            let title = try? await titleTask
            guard !segs.isEmpty else { return .fail(base, "转写是空的") }
            return .ok(IndexedRecording(
                base: base, transcriptId: tid, title: title,
                recordedAt: recordedAt(base: base),
                lines: segs.map { IndexedLine(speaker: $0.speaker, text: $0.text,
                                              startMs: $0.startMs) }))
        } catch {
            return .fail(base, "拉转写失败：\(error)")
        }
    }

    /// 从文件名解析录制时间：note20260828-205856 → 2026-08-28 20:58:56。
    /// Core 层不能用界面里的 Fmt，所以这里自己解析一遍；解析不出就 nil，不猜。
    static func recordedAt(base: String) -> Date? {
        guard let r = base.range(of: "[0-9]{8}-[0-9]{6}", options: .regularExpression) else {
            return nil
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(base[r]))
    }
}
