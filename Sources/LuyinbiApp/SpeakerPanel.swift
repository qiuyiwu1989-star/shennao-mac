import LuyinbiCore
import SwiftUI

/// 说话人指认面板。
///
/// 为什么值得做：ASR 只给「说话人1/2/3」，转写原文和后续洞察里就一直带着这些编号。
/// 深脑的 speakers 表早就留好了位置，只是没有入口去填。
/// 关键设计是每个说话人配一句最长的原话 + 一键跳到那一秒试听——
/// 让人**听一句就知道是谁**，而不是去读一段十几分钟的转写自己找。
/// 一条转写的全部工作台数据。缓存起来，切回来时不再等网络。
private struct Cached {
    var rows: [SpeakerRow]
    var segments: [TranscriptSegment]
    var shares: [SpeakerShare]
    var samples: [String: SpeakerSample]
    var title: String?
}

@MainActor
final class SpeakerStore: ObservableObject {
    /// 实测：深脑自托管 Supabase 上，**带登录态的任意查询都要 2 秒**
    /// （裸连接只要 49 毫秒，所以不是网络，是服务端 RLS）。
    /// 三个请求并行也要 2 秒起步，来回切换录音就是每次干等两秒。
    /// 2 秒的往返只能靠不往返来解决——所以这里全量缓存。
    private var cache: [String: Cached] = [:]
    /// 人物列表全局只取一次：它几乎不变，却是三个请求里最慢的那个（2.8 秒）。
    private static var cachedPeople: [PersonProfile] = []
    @Published var rows: [SpeakerRow] = []
    @Published var samples: [String: SpeakerSample] = [:]
    @Published var people: [PersonProfile] = []
    @Published var segments: [TranscriptSegment] = []
    @Published var shares: [SpeakerShare] = []
    @Published var waveform: [Float] = []
    /// 深脑生成的标题（没分析过就是 nil）
    @Published var title: String?
    /// 这条转写是录音链路来的权威数据，客户端改不了说话人。
    /// 识别到之后要换成「去深脑指认」，而不是让人对着 403 反复点。
    @Published var readOnly = false
    /// 标题取回来时通知外面（列表也要用）
    var onTitleLoaded: ((String, String) -> Void)?
    /// 当前这条转写对应的录音 base，回填标题时要用
    var currentBase: String?
    @Published var loading = false
    @Published var message: String?
    /// 当前数据属于哪条转写。视图必须拿它和自己的 item 对一遍才敢显示——
    /// 否则会出现「选中 A、显示 B 的转写」，而且看起来毫无破绽。
    @Published private(set) var loadedFor: String?
    /// 最后一次发起的请求。异步响应回来晚了不能覆盖新的。
    private var inflight: String?

    /// 一次把工作台要的东西全取回来。分开取会让界面分三次抖动。
    func load(transcriptId: String, brain: DeepBrain, force: Bool = false) {
        inflight = transcriptId
        message = nil

        // 有缓存就立刻显示，一帧都不等。后台再去刷新一次，
        // 内容变了（比如刚指认完说话人）会自动更新。
        if let c = cache[transcriptId] {
            rows = c.rows; segments = c.segments; shares = c.shares; samples = c.samples
            title = c.title
            loadedFor = transcriptId
            loading = false
            if !force { return }
        } else {
            loadedFor = nil
            loading = true
            segments = []; shares = []; rows = []; samples = [:]; title = nil; readOnly = false
        }

        if !Self.cachedPeople.isEmpty { people = Self.cachedPeople }

        Task {
            do {
                async let r = brain.speakers(transcriptId: transcriptId)
                async let g = brain.segments(transcriptId: transcriptId)
                let rws = try await r
                let segs = try await g
                guard inflight == transcriptId else { return }
                rows = rws
                segments = segs
                shares = SpeakerStats.shares(segs)
                // 样本从 segments 里挑最长的一句，不再单独请求一次
                var best: [String: SpeakerSample] = [:]
                for x in segs where !x.speaker.isEmpty {
                    if let cur = best[x.speaker], cur.text.count >= x.text.count { continue }
                    best[x.speaker] = SpeakerSample(label: x.speaker, text: x.text,
                                                    startMs: x.startMs, endMs: x.endMs)
                }
                samples = best
                // 中途切走了就丢弃这次结果，别覆盖新选中的那条
                guard inflight == transcriptId else { return }
                let tt = try? await brain.transcriptTitle(transcriptId)
                guard inflight == transcriptId else { return }
                title = tt
                if let tt, let b = currentBase { onTitleLoaded?(b, tt) }
                cache[transcriptId] = Cached(rows: rws, segments: segs,
                                             shares: shares, samples: best, title: tt)
                loadedFor = transcriptId
                // 人物列表全局只取一次
                if Self.cachedPeople.isEmpty,
                   let ppl = try? await brain.personProfiles() {
                    Self.cachedPeople = ppl
                    people = ppl
                }
            } catch {
                guard inflight == transcriptId else { return }
                message = "读取转写失败：\(error)"
            }
            if inflight == transcriptId { loading = false }
        }
    }

    /// 波形**只从缓存读，绝不当场算**。
    ///
    /// 原来这里调的是 `Waveform.load`——缓存不中就当场解码整条音频。
    /// 而 Waveform.swift 自己的注释写着「耗时大头是 Opus 解码，12 分钟约 3.3 秒」，
    /// 那么一条 1.5 小时的录音就是二十多秒满载 CPU——**而用户只是点了一下列表**。
    /// 优先级还给的是 .userInitiated，等于跟界面抢资源。
    ///
    /// 波形是装饰：它不影响播放、不影响转写、不影响任何判断。
    /// 装饰绝不该跟正事抢 CPU。缓存没有就先空着，等真的按了播放再算（见 ensureWaveform）。
    func loadWaveform(base: String, audio: URL, root: URL) {
        waveform = []
        let cached = Waveform.cached(base: base, root: root) ?? []
        if !cached.isEmpty { waveform = cached }
    }

    /// 真的要看波形时才算。**最低优先级**，算完写缓存，下次直接命中。
    func ensureWaveform(base: String, audio: URL, root: URL) {
        guard waveform.isEmpty else { return }
        Task.detached(priority: .background) {
            let w = Waveform.load(base: base, audio: audio, root: root) ?? []
            await MainActor.run { self.waveform = w }
        }
    }

    func assign(_ row: SpeakerRow, name: String, profileId: String?, brain: DeepBrain) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // loadedFor 就是当前这条转写；它同时是身份闸——面板还没加载完就没有可指认的对象。
        guard !clean.isEmpty, let tid = loadedFor else { return }
        Task {
            do {
                try await brain.assignSpeaker(transcriptId: tid, row: row,
                                              identity: clean, profileId: profileId)
                if let i = rows.firstIndex(where: { $0.id == row.id }) {
                    rows[i].inferredIdentity = clean
                    rows[i].userProfileId = profileId
                    rows[i].confirmed = true
                    // 缓存也要跟着改，否则切走再回来又变回「说话人1」
                    if let tid = loadedFor { cache[tid]?.rows = rows }
                }
                message = "已指认 \(row.label) → \(clean)"
            } catch DeepBrainError.canonicalReadOnly {
                readOnly = true
                message = nil
            } catch DeepBrainError.alreadyAnalyzed {
                // 同样是「这条得去网页改」，复用同一块提示，别再多一种说法
                readOnly = true
                message = nil
            } catch {
                message = "写入失败：\(error)"
            }
        }
    }
}

struct SpeakerPanel: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: SpeakerStore
    @ObservedObject var audio: AudioPreview
    let item: RecordingItem
    let audioURL: URL
    let brain: DeepBrain

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.wave.2").foregroundStyle(DS.iris)
                Text("说话人").font(DS.heading(12, .semibold)).dsHeading()
                    .foregroundStyle(DS.title(scheme == .dark))
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }

            if store.rows.isEmpty && !store.loading {
                Text("这条转写里没有说话人记录。")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
            }

            ForEach(store.rows) { row in
                SpeakerRowView(row: row, sample: store.samples[row.label],
                               people: store.people, audio: audio,
                               base: item.base, audioURL: audioURL,
                               onAssign: { name, pid in
                                   store.assign(row, name: name, profileId: pid, brain: brain)
                               })
            }

            if let m = store.message {
                Text(m).font(DS.bodyFont(DS.T.meta))
                    .foregroundStyle(m.contains("失败") ? DS.bad : DS.ok)
            }

            Text("指认后深脑再跑分析，用的就是真名而不是「说话人1」。")
                .font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.body(scheme == .dark))
        }
    }
}

private struct SpeakerRowView: View {
    @Environment(\.colorScheme) private var scheme
    let row: SpeakerRow
    let sample: SpeakerSample?
    let people: [PersonProfile]
    @ObservedObject var audio: AudioPreview
    let base: String
    let audioURL: URL
    let onAssign: (String, String?) -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.label).font(DS.bodyFont(DS.T.title, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
                if let who = row.inferredIdentity, !who.isEmpty {
                    Image(systemName: "arrow.right").font(.system(size: 9))
                        .foregroundStyle(DS.muted)
                    Text(who).font(DS.bodyFont(DS.T.title, .semibold)).foregroundStyle(DS.focus)
                    if row.confirmed { StatusPill(text: "已确认", tone: .ok) }
                }
                Spacer()
            }

            if let s = sample {
                // 听一句就知道是谁——直接跳到这个人开口的那一秒
                Button {
                    audio.toggle(base: base, url: audioURL, startAt: s.startSeconds)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "play.circle").font(.system(size: 12))
                        Text(s.text).font(DS.bodyFont(DS.T.meta)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.body(scheme == .dark))
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(people) { p in
                        Button(p.displayName) { onAssign(p.displayName, p.id) }
                    }
                } label: {
                    Label("从深脑人物里选", systemImage: "person.crop.circle")
                        .font(DS.bodyFont(DS.T.meta))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 150)

                TextField("或直接写名字", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.bodyFont(DS.T.meta))
                    .onSubmit { onAssign(typed, nil); typed = "" }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
            .fill(scheme == .dark ? DS.ink800.opacity(0.5) : DS.ink50))
    }
}
