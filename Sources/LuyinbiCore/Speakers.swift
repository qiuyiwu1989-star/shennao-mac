import Foundation

/// 说话人指认。
///
/// 背景：ASR 只给「说话人1/2/3」，转写原文里就是这么写的，用户看到的洞察里也就带着这些编号。
/// 深脑的 `speakers` 表早就留好了位置（label / inferred_identity / confirmed / user_profile_id）。
///
/// **写入不能直连 PostgREST**：录音链路产生的转写/说话人受 canonical 守卫保护
/// （迁移 0063），认证用户只读，直写返回 403 / 42501。曾经这里写着「RLS 是 for all，
/// Mac 端可以直接读写，不需要给深脑加接口」——那是错的，实机一写就 403。
/// 所以指认走深脑的 `PATCH /api/recordings/{sessionId}/speakers`（原生 Bearer 通道，
/// 服务端用 service client 落库，并顺手把人升进确定库）。
/// 读仍然直连 PostgREST——守卫只挡写。
///
/// 不是所有转写都来自录音链路：手工导入的转写没有 recording_session，
/// 也就没有守卫，那种情况仍走直连写入（见 assignSpeaker 的兜底分支）。
///
/// **不在这里新建人物实体**：深脑有实体层和人名归并逻辑，从外面塞人容易造出同一个人的多个身份。
/// 这里只支持「选一个已有的人」或「先写个名字」。
public struct SpeakerRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String              // 原始标签，如「说话人1」
    public var inferredIdentity: String?  // 指认到的名字
    public var confirmed: Bool
    public var userProfileId: String?
}

public struct PersonProfile: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
}

/// 某个说话人在这段录音里最有代表性的一句话，用来「听一句就知道是谁」。
public struct TranscriptSegment: Identifiable, Sendable, Equatable {
    public let id: String
    public let speaker: String
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public var startSeconds: Double { Double(startMs) / 1000 }
    public var durationMs: Int { max(0, endMs - startMs) }

    public init(id: String, speaker: String, text: String, startMs: Int, endMs: Int) { self.id = id; self.speaker = speaker; self.text = text; self.startMs = startMs; self.endMs = endMs }
}

/// 说话时长占比。一眼看出谁是主讲、谁只是附和——
/// 这个数深脑网页现在都没有，而它对认人特别有用：占比最高的那位多半是你最熟的人。
public struct SpeakerShare: Identifiable, Sendable, Equatable {
    public var id: String { label }
    public let label: String
    public let seconds: Double
    public let fraction: Double
}

public enum SpeakerStats {
    /// 从 segments 直接算，不需要深脑增加任何能力。
    public static func shares(_ segments: [TranscriptSegment]) -> [SpeakerShare] {
        var total: [String: Int] = [:]
        for s in segments where !s.speaker.isEmpty {
            total[s.speaker, default: 0] += s.durationMs
        }
        let sum = Double(total.values.reduce(0, +))
        guard sum > 0 else { return [] }
        return total.map { SpeakerShare(label: $0.key, seconds: Double($0.value) / 1000,
                                        fraction: Double($0.value) / sum) }
            .sorted { $0.fraction > $1.fraction }
    }
}

public struct SpeakerSample: Sendable, Equatable {
    public let label: String
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public var startSeconds: Double { Double(startMs) / 1000 }

    public init(label: String, text: String, startMs: Int, endMs: Int) { self.label = label; self.text = text; self.startMs = startMs; self.endMs = endMs }
}

public extension DeepBrain {

    func speakers(transcriptId: String) async throws -> [SpeakerRow] {
        let q = "speakers?transcript_id=eq.\(transcriptId)&select=id,label,inferred_identity,confirmed,user_profile_id&order=label"
        let rows = try await restGet(q)
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let label = r["label"] as? String else { return nil }
            return SpeakerRow(id: id, label: label,
                              inferredIdentity: r["inferred_identity"] as? String,
                              confirmed: (r["confirmed"] as? Bool) ?? false,
                              userProfileId: r["user_profile_id"] as? String)
        }
    }

    func personProfiles(limit: Int = 100) async throws -> [PersonProfile] {
        let rows = try await restGet("user_profiles?select=id,display_name&order=display_name&limit=\(limit)")
        return rows.compactMap { r in
            guard let id = r["id"] as? String,
                  let name = r["display_name"] as? String, !name.isEmpty else { return nil }
            return PersonProfile(id: id, displayName: name)
        }
    }

    /// 深脑给这条录音起的标题。
    ///
    /// 注意它是**分析的产物**（`generateTitleAndTags` 在 run-analysis 里），不是转写的产物——
    /// 没跑过分析的还是原始文件名。所以拿到的可能仍是 note20260828-170044，
    /// 这时界面上就退回显示日期时间，别把文件名当标题给人看。
    func transcriptTitle(_ transcriptId: String) async throws -> String? {
        let rows = try await restGet("transcripts?id=eq.\(transcriptId)&select=title")
        guard let t = rows.first?["title"] as? String, !t.isEmpty else { return nil }
        // 还是文件名的话等于没有标题
        return t.hasPrefix("note2") ? nil : t
    }

    /// 深脑里的项目。上传时可以直接归到某个项目下，省得事后在网页里再挪一遍。
    func projects() async throws -> [(id: String, name: String)] {
        let rows = try await restGet("projects?select=id,name&order=updated_at.desc&limit=50")
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let n = r["name"] as? String else { return nil }
            return (id, n)
        }
    }

    /// 批量取标题。列表一屏几十条，逐条查等于几十个来回；
    /// 而且原来只在「点开某条」时才查，于是列表里永远是一串时间戳——
    /// 「8月28日 22:41:52」认不出是哪场会，标题才认得出。
    ///
    /// 注意 PostgREST 的 1000 行默认上限：这里按 200 一批切，
    /// 既不会撞上限，URL 也不会长到 414。
    func transcriptTitles(_ transcriptIds: [String]) async throws -> [String: String] {
        var out: [String: String] = [:]
        for chunk in stride(from: 0, to: transcriptIds.count, by: 200).map({
            Array(transcriptIds[$0..<min($0 + 200, transcriptIds.count)])
        }) {
            let rows = try await restGet(
                "transcripts?id=in.(\(chunk.joined(separator: ",")))&select=id,title")
            for r in rows {
                guard let id = r["id"] as? String,
                      let t = r["title"] as? String, !t.isEmpty,
                      !t.hasPrefix("note2") else { continue }   // 还是文件名等于没标题
                out[id] = t
            }
        }
        return out
    }

    /// 逐句转写。工作台左栏用它做「点句子跳到那一秒」。
    func segments(transcriptId: String) async throws -> [TranscriptSegment] {
        let rows = try await restGet("transcripts?id=eq.\(transcriptId)&select=segments")
        guard let segs = rows.first?["segments"] as? [[String: Any]] else { return [] }
        return segs.compactMap { s in
            guard let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return TranscriptSegment(
                id: (s["id"] as? String) ?? UUID().uuidString,
                speaker: (s["speaker"] as? String) ?? "",
                text: text,
                startMs: intValue(s["start_ms"]) ?? 0,
                endMs: intValue(s["end_ms"]) ?? 0)
        }.sorted { $0.startMs < $1.startMs }
    }

    /// 每个说话人挑一句最长的话当样本——最长的那句信息量最大，最容易听出是谁。
    func speakerSamples(transcriptId: String) async throws -> [String: SpeakerSample] {
        let rows = try await restGet("transcripts?id=eq.\(transcriptId)&select=segments")
        guard let segs = rows.first?["segments"] as? [[String: Any]] else { return [:] }
        var best: [String: SpeakerSample] = [:]
        for s in segs {
            guard let label = s["speaker"] as? String,
                  let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let start = intValue(s["start_ms"]) ?? 0
            let end = intValue(s["end_ms"]) ?? start
            if let cur = best[label], cur.text.count >= text.count { continue }
            best[label] = SpeakerSample(label: label, text: text, startMs: start, endMs: end)
        }
        return best
    }

    /// 一次性查多篇转写里「还没指认」的说话人数量。
    ///
    /// 必须批量：待办区要对每条已转写的录音判断"要不要认人"，
    /// 一条一条问就是 N 次往返，几十条录音时界面会卡住。
    func unconfirmedSpeakerCounts(transcriptIds: [String]) async throws -> [String: Int] {
        guard !transcriptIds.isEmpty else { return [:] }
        let list = transcriptIds.joined(separator: ",")
        let rows = try await restGet(
            "speakers?transcript_id=in.(\(list))&confirmed=is.false&select=transcript_id")
        var out: [String: Int] = [:]
        for r in rows {
            guard let tid = r["transcript_id"] as? String else { continue }
            out[tid, default: 0] += 1
        }
        return out
    }

    /// 直接写 speakers 表会不会被守卫挡住。
    ///
    /// 深脑对「录音链路产生的转写」设了 canonical 守卫（0063 迁移）：
    /// 认证用户只能读，写入必须走 service-role 或 RPC。这是保护录音原始数据的正确设计。
    ///
    /// 而且**即使能写通也是错的**：深脑正确的改名路径还要把原子主语、决策归属一起重挂，
    /// 并把这个人升进「确定库」；正文永远保留「说话人N」锚点、真名是渲染时投影上去的——
    /// 这样改名才可逆。只改一个字段等于只改了标签，后面的洞察还是挂在旧名下。
    static let canonicalGuardCode = "42501"

    /// 写回指认结果。confirmed 一律置 true——是人手点的，不是推断的。
    /// transcript_id -> recording_session_id。没有对应会话说明这条转写不是录音链路来的。
    func recordingSessionId(forTranscript tid: String) async throws -> String? {
        if let hit = sessionIdCache[tid] { return hit }
        let rows = try await restGet("recording_sessions?final_transcript_id=eq.\(tid)&select=id&limit=1")
        guard let sid = rows.first?["id"] as? String else { return nil }
        sessionIdCache[tid] = sid
        return sid
    }

    /// 指认一个说话人。
    ///
    /// 录音链路来的转写走深脑接口（守卫只让服务端写）；其他转写没有守卫，直连写入。
    func assignSpeaker(transcriptId: String, row: SpeakerRow,
                       identity: String, profileId: String?) async throws {
        let name = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        guard let sid = try await recordingSessionId(forTranscript: transcriptId) else {
            try await assignSpeakerDirect(rowId: row.id, identity: name, profileId: profileId)
            return
        }

        var one: [String: Any] = ["label": row.label, "name": name]
        if let profileId { one["profileId"] = profileId }
        let (st, data) = try await request(
            "PATCH", "\(config.apiBase)/api/recordings/\(sid)/speakers",
            headers: try authHeaders, json: ["assignments": [one]])
        let body = String(decoding: data, as: UTF8.self)

        if st == 409, body.contains("已经分析过") { throw DeepBrainError.alreadyAnalyzed }

        // 线上不一定有这个接口：深脑是滚动发布的，客户端可能比服务端新，
        // 也可能撞上一次把接口带走的发布。这时退回直连写——非录音链路的转写照样能写，
        // 录音链路的会撞守卫拿到 403，走已有的「去网页指认」提示，而不是一个 404。
        if st == 404, !body.contains("SESSION_NOT_FOUND") {
            try await assignSpeakerDirect(rowId: row.id, identity: name, profileId: profileId)
            return
        }
        guard st < 400 else { throw DeepBrainError.http("写入说话人身份", st, body) }

        // 接口是「按 label 匹配」的：标签对不上会静默算作 missing，
        // 不检查的话界面会显示已认完，而库里一个字没改。
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (obj?["updated"] as? Int ?? 0) == 0 {
            throw DeepBrainError.badResponse("深脑没找到标签「\(row.label)」，这条没写进去")
        }
    }

    /// 直连 PostgREST 写入。只用于**不受 canonical 守卫**的转写（非录音链路）。
    func assignSpeakerDirect(rowId: String, identity: String?, profileId: String?) async throws {
        var payload: [String: Any] = ["confirmed": true]
        payload["inferred_identity"] = identity ?? NSNull()
        payload["user_profile_id"] = profileId ?? NSNull()
        let (st, data) = try await request(
            "PATCH", "\(configSupabaseURL)/rest/v1/speakers?id=eq.\(rowId)",
            headers: try restHeaders.merging(["Prefer": "return=minimal"]) { _, b in b },
            json: payload)
        guard st < 400 else {
            let body = String(decoding: data, as: UTF8.self)
            if body.contains(Self.canonicalGuardCode) || body.contains("service-role write only") {
                throw DeepBrainError.canonicalReadOnly
            }
            throw DeepBrainError.http("写入说话人身份", st, body)
        }
    }

    // MARK: - 内部
    private func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private func restGet(_ query: String) async throws -> [[String: Any]] {
        // 走 authed：token 过期时自动续一次再重试。
        // 不走的话，开着 App 超过一小时就会看到 401 JWT expired。
        let (st, data) = try await authed("GET", "\(configSupabaseURL)/rest/v1/\(query)",
                                          headers: { try self.restHeaders })
        guard st < 400 else {
            throw DeepBrainError.http("查询 \(query.prefix(24))", st, String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
}
