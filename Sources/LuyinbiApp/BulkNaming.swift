import LuyinbiCore
import SwiftUI

/// 批量指认说话人。
///
/// 为什么单独做一个界面：工作台一次只服务一条录音，可待认人的录音常常是**一批**——
/// 早上开了三个会、一天录了六段，逐条点进去、每条等两秒、再从一百个人里翻名字，
/// 人就不认了，于是所有洞察里永远写着「说话人1」。
///
/// 这个界面的核心判断是：**同一批录音多半是同一群人**。
/// 所以它不是把工作台复制六遍，而是把「刚用过的人」一直摆在手边——
/// 认完第一条里的柯苗苗，后面五条里她就是一颗一点即中的胶囊，
/// 而不是又一次「打开菜单 → 翻一百个人 → 找到她」。
///
/// 性能上只有一条硬约束：深脑自托管 Supabase 上**带登录态的任意查询要 2 秒**
/// （不是网络，是服务端 RLS）。串行拉 6 条就是 24 秒，界面等于废掉。
/// 所以这里：人物列表全局只取一次、每条录音的 speakers/segments 全部并发、取回来一律缓存。

// MARK: - 最近用过的人

/// 最近指认过的人。
///
/// 它比「深脑全部人物」重要得多：全部人物是一百个人的字典，最近用过的是这场会的花名册。
/// 有 profileId 的走档案关联，纯手打的名字没有 id——两种都要能复用，
/// 所以这里不复用 PersonProfile（它一定有 id），而是自己一个小结构。
struct RecentPerson: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let profileId: String?
    /// 手打的名字没有 id，用名字兜底；同名同人在这里当成一个，符合直觉。
    var id: String { profileId ?? "name:\(name)" }
}

// MARK: - 一条录音在批量界面里的全部数据

struct BulkNamingGroup: Identifiable, Sendable {
    var item: RecordingItem
    var rows: [SpeakerRow]
    /// label -> 占比，用 SpeakerStats.shares 从 segments 算出来的
    var shares: [String: SpeakerShare]
    /// label -> 最长的一句原话，用来「听一句就知道是谁」
    var samples: [String: SpeakerSample]
    var loaded: Bool
    var error: String?

    var id: String { item.base }
    var unconfirmedCount: Int { rows.filter { !$0.confirmed }.count }
    var confirmedCount: Int { rows.filter { $0.confirmed }.count }
    var done: Bool { loaded && unconfirmedCount == 0 }
}

/// 并发取数的返回件。必须是 Sendable 才能穿过 TaskGroup，
/// 所以错误在子任务里就转成字符串，不把 Error 往外抬。
private struct BulkFetch: Sendable {
    let base: String
    let rows: [SpeakerRow]
    let segments: [TranscriptSegment]
    let error: String?
}

// MARK: - Store

@MainActor
final class BulkNamingStore: ObservableObject {

    @Published private(set) var groups: [BulkNamingGroup] = []
    @Published private(set) var people: [PersonProfile] = []
    /// 排在最前的候选人。第一个是最近用过的那个。
    @Published private(set) var recents: [RecentPerson] = []
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    /// 正在写回的行（rowId）。逐行显示转圈，而不是整个界面锁住。
    @Published private(set) var writing: Set<String> = []
    /// 行级失败信息。失败必须钉在那一行上——
    /// 攒到最后统一提交、统一报错，用户根本不知道哪几条成了、哪几条没成。
    @Published private(set) var rowErrors: [String: String] = [:]
    /// 命中 canonical 守卫：录音链路来的转写客户端改不了，整批都一样。
    /// 标一次就够——别让人一条条点、一条条撞同一堵墙。
    @Published private(set) var blockedByGuard = false

    /// 人物列表全局只取一次：它几乎不变，却是所有请求里最慢的一个。
    private static var cachedPeople: [PersonProfile] = []
    /// 每条转写的数据缓存，key 是 transcriptId。
    /// 关掉批量面板再打开、或和工作台来回切，都不该重新等 2 秒。
    private static var cachedGroups: [String: BulkNamingGroup] = [:]
    private static let recentsKey = "bulkNaming.recentPeople"

    /// 当前已加载的是哪一批（transcriptId 排序拼串）。同一批不重复拉。
    private var loadedKey: String?

    // MARK: 进度

    /// 还剩几条录音没认完
    var remainingRecordings: Int { groups.filter { !$0.done }.count }
    /// 还剩几个人没指认
    var remainingSpeakers: Int { groups.reduce(0) { $0 + $1.unconfirmedCount } }
    var totalSpeakers: Int { groups.reduce(0) { $0 + $1.rows.count } }
    var doneSpeakers: Int { totalSpeakers - remainingSpeakers }
    var progress: Double {
        totalSpeakers > 0 ? Double(doneSpeakers) / Double(totalSpeakers) : 0
    }

    // MARK: 加载

    /// 一次把这一批全部拉回来。
    ///
    /// 没有 transcriptId 的录音直接跳过——它还没转写，压根没有说话人可认，
    /// 摆在这里只会让人以为是自己漏点了。
    func load(items: [RecordingItem], brain: DeepBrain) {
        let usable = items.filter { $0.transcriptId != nil }
        let key = usable.compactMap(\.transcriptId).sorted().joined(separator: ",")
        guard loadedKey != key else { return }
        loadedKey = key
        loadError = nil

        if recents.isEmpty { recents = Self.loadRecents() }
        if !Self.cachedPeople.isEmpty { people = Self.cachedPeople }

        // 有缓存的先摆上去，一帧都不等；只有真没有的才去网络上取。
        var shown: [BulkNamingGroup] = []
        var pending: [RecordingItem] = []
        for it in usable {
            guard let tid = it.transcriptId else { continue }
            if var c = Self.cachedGroups[tid] {
                c.item = it                       // 状态可能变了，数据部分留用
                shown.append(c)
            } else {
                shown.append(BulkNamingGroup(item: it, rows: [], shares: [:],
                                             samples: [:], loaded: false))
                pending.append(it)
            }
        }
        groups = shown
        seedRecentsFromGroups()

        let needPeople = Self.cachedPeople.isEmpty
        guard !pending.isEmpty || needPeople else { return }
        loading = true

        Task {
            // 人物列表和各条录音的取数**同时**发出：它们互不依赖，
            // 串起来就是又多等一个 2 秒。
            async let peopleTask: [PersonProfile]? =
                needPeople ? (try? await brain.personProfiles()) : nil
            let fetched = pending.isEmpty ? []
                : await Self.fetchAll(pending, brain: brain)
            if let ppl = await peopleTask, !ppl.isEmpty {
                Self.cachedPeople = ppl
                people = ppl
            }
            apply(fetched)
            loading = false
            let failed = fetched.filter { $0.error != nil }.count
            if failed > 0, failed == fetched.count {
                loadError = fetched.first?.error
            }
        }
    }

    /// 重新拉一次（比如某条读失败了想重试）。
    func reload(items: [RecordingItem], brain: DeepBrain) {
        for it in items { if let tid = it.transcriptId { Self.cachedGroups[tid] = nil } }
        loadedKey = nil
        load(items: items, brain: brain)
    }

    /// 并发取全部录音的 speakers + segments。
    ///
    /// 每条录音两个查询（各 2 秒），条内用 async let 并起来，条间用 TaskGroup 并起来——
    /// 6 条录音 12 个查询，总耗时仍然是 2 秒出头，而不是 24 秒。
    private nonisolated static func fetchAll(_ items: [RecordingItem],
                                             brain: DeepBrain) async -> [BulkFetch] {
        // DeepBrain 是个普通 class，跨子任务传递只是并发读同一个 HTTP 客户端；
        // 这里没有任何写共享状态的路径，所以显式标注放行。
        nonisolated(unsafe) let client = brain
        return await withTaskGroup(of: BulkFetch.self) { group in
            for it in items {
                guard let tid = it.transcriptId else { continue }
                let base = it.base
                group.addTask {
                    do {
                        async let r = client.speakers(transcriptId: tid)
                        async let s = client.segments(transcriptId: tid)
                        return BulkFetch(base: base, rows: try await r,
                                         segments: try await s, error: nil)
                    } catch {
                        return BulkFetch(base: base, rows: [], segments: [],
                                         error: "读取失败：\(error)")
                    }
                }
            }
            var out: [BulkFetch] = []
            for await one in group { out.append(one) }
            return out
        }
    }

    private func apply(_ fetched: [BulkFetch]) {
        for f in fetched {
            guard let idx = groups.firstIndex(where: { $0.item.base == f.base }) else { continue }
            var g = groups[idx]
            g.error = f.error
            g.loaded = f.error == nil
            if f.error == nil {
                let shares = SpeakerStats.shares(f.segments)
                g.shares = Dictionary(shares.map { ($0.label, $0) }) { a, _ in a }
                // 样本直接从 segments 里挑最长的一句，不再为它单发一个请求。
                var best: [String: SpeakerSample] = [:]
                for x in f.segments where !x.speaker.isEmpty {
                    if let cur = best[x.speaker], cur.text.count >= x.text.count { continue }
                    best[x.speaker] = SpeakerSample(label: x.speaker, text: x.text,
                                                    startMs: x.startMs, endMs: x.endMs)
                }
                g.samples = best
                g.rows = Self.ordered(f.rows, shares: g.shares)
                if let tid = g.item.transcriptId { Self.cachedGroups[tid] = g }
            }
            groups[idx] = g
        }
        seedRecentsFromGroups()
    }

    /// 未指认的排前面（这才是要干的活），组内按说话占比从多到少——
    /// 占比最高的那位通常也是你最熟、最容易一眼认出的人。
    private static func ordered(_ rows: [SpeakerRow],
                                shares: [String: SpeakerShare]) -> [SpeakerRow] {
        rows.sorted { a, b in
            if a.confirmed != b.confirmed { return !a.confirmed }
            let fa = shares[a.label]?.fraction ?? 0
            let fb = shares[b.label]?.fraction ?? 0
            if fa != fb { return fa > fb }
            return a.label < b.label
        }
    }

    // MARK: 写回

    /// 逐条写回，写一条界面上就变一条。
    ///
    /// 不做「攒起来最后一起提交」：这一批可能有二十次写入，中途断网只失败其中三条，
    /// 而用户对着一个「提交失败」的提示完全不知道哪三条没成——
    /// 那时唯一的办法是全部重认一遍，比没有批量还糟。
    func assign(groupId: String, row: SpeakerRow, name: String,
                profileId: String?, brain: DeepBrain) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !writing.contains(row.id) else { return }
        // 指认按会话寻址，会话靠 transcriptId 找；没有它这条根本还没转写。
        guard let tid = groups.first(where: { $0.id == groupId })?.item.transcriptId else { return }
        writing.insert(row.id)
        rowErrors.removeValue(forKey: row.id)
        Task {
            do {
                try await brain.assignSpeaker(transcriptId: tid, row: row,
                                              identity: clean, profileId: profileId)
                markAssigned(groupId: groupId, rowId: row.id,
                             name: clean, profileId: profileId)
                promote(RecentPerson(name: clean, profileId: profileId))
            } catch DeepBrainError.canonicalReadOnly {
                // 整批都会撞同一堵墙，标一次就够——别让人一条条点、一条条失败。
                blockedByGuard = true
            } catch DeepBrainError.alreadyAnalyzed {
                // 已分析过的改名要连洞察归属一起重挂，只能去网页——同样是整条录音级别的墙。
                blockedByGuard = true
            } catch {
                rowErrors[row.id] = "写入失败：\(error)"
            }
            writing.remove(row.id)
        }
    }

    /// 只改状态、**不重排**。
    /// 重排会让刚点完的那一行从光标底下跑掉，下一次点击就点到别人身上了。
    private func markAssigned(groupId: String, rowId: String,
                              name: String, profileId: String?) {
        guard let gi = groups.firstIndex(where: { $0.id == groupId }),
              let ri = groups[gi].rows.firstIndex(where: { $0.id == rowId }) else { return }
        groups[gi].rows[ri].inferredIdentity = name
        groups[gi].rows[ri].userProfileId = profileId
        groups[gi].rows[ri].confirmed = true
        // 缓存要跟着改，否则关掉再打开又变回「说话人1」
        if let tid = groups[gi].item.transcriptId { Self.cachedGroups[tid] = groups[gi] }
    }

    // MARK: 最近用过的人

    /// 用过一次就顶到最前。这是整个功能省时间的地方：
    /// 第二条录音打开时，第一条里那几位已经在最前面等着了。
    private func promote(_ p: RecentPerson) {
        recents.removeAll { $0.id == p.id }
        recents.insert(p, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        Self.saveRecents(recents)
    }

    /// 这一批录音里**已经**认过的人，也算「最近用过」。
    ///
    /// 这样第一条录音打开的那一刻胶囊排就不是空的（往往先前已经认过一两条了），
    /// 不用等用户先手动认一个才开始省力。放在已有 recents 后面，不抢真正的最近。
    private func seedRecentsFromGroups() {
        var merged = recents
        for g in groups {
            for r in g.rows {
                guard r.confirmed, let n = r.inferredIdentity, !n.isEmpty else { continue }
                let p = RecentPerson(name: n, profileId: r.userProfileId)
                if !merged.contains(where: { $0.id == p.id }) { merged.append(p) }
            }
        }
        if merged.count > 12 { merged = Array(merged.prefix(12)) }
        if merged != recents { recents = merged }
    }

    /// 跨会话记住。今天下午认的那几位，明天早上开同一个周会还是他们。
    private static func loadRecents() -> [RecentPerson] {
        guard let d = UserDefaults.standard.data(forKey: recentsKey),
              let v = try? JSONDecoder().decode([RecentPerson].self, from: d) else { return [] }
        return v
    }

    private static func saveRecents(_ v: [RecentPerson]) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(d, forKey: recentsKey)
    }
}

// MARK: - 界面

/// 批量指认说话人的主界面。
struct BulkNamingView: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var store = BulkNamingStore()

    /// 待认人的录音（没有 transcriptId 的会被自动忽略）
    let items: [RecordingItem]
    let brain: DeepBrain
    @ObservedObject var audio: AudioPreview
    /// 本地音频所在目录，用 base + ".ogg" 拼出文件路径（和工作台一致）
    let audioFolder: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(DS.bg(scheme == .dark))
        .onAppear { store.load(items: items, brain: brain) }
    }

    // MARK: 顶栏：说清楚还剩多少，以及怎么退出

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.focusBright)

            VStack(alignment: .leading, spacing: 1) {
                Text("批量指认说话人")
                    .font(DS.heading(15, .bold)).dsHeading()
                    .foregroundStyle(DS.title(scheme == .dark))
                Text("同一批录音多半是同一群人，认过的会一直排在最前")
                    .font(DS.bodyFont(DS.T.meta))
                    .foregroundStyle(DS.body(scheme == .dark))
            }

            Spacer(minLength: 12)

            if store.loading { ProgressView().controlSize(.small) }

            // 总进度：既给「还剩几条几人」的数字，也给一根条——
            // 数字回答"还有多少"，条回答"我走了多远"，批量任务两个都要。
            VStack(alignment: .trailing, spacing: 3) {
                Text(store.remainingSpeakers == 0
                     ? "全部认完"
                     : "还剩 \(store.remainingRecordings) 条 · \(store.remainingSpeakers) 人")
                    .font(DS.bodyFont(DS.T.meta, .semibold))
                    .foregroundStyle(store.remainingSpeakers == 0
                                     ? DS.ok : DS.title(scheme == .dark))
                    .monospacedDigit()
                ProgressView(value: store.progress)
                    .progressViewStyle(.linear)
                    .tint(store.remainingSpeakers == 0 ? DS.ok : DS.focusBright)
                    .frame(width: 132)
            }

            Button { onClose() } label: {
                Label("完成", systemImage: "checkmark")
            }
            .buttonStyle(DSPrimaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if store.groups.isEmpty {
            EmptyHint(icon: store.loading ? "hourglass" : "checkmark.seal",
                      title: store.loading ? "正在读取这一批" : "没有待指认的录音",
                      detail: store.loading
                        ? "几条录音同时在取，不是一条一条排队"
                        : "转写好之后，需要认人的录音会出现在这里")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let e = store.loadError {
                        Text(e).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.bad)
                    }
                    ForEach(store.groups) { g in
                        BulkGroupCard(group: g,
                                      store: store,
                                      brain: brain,
                                      audio: audio,
                                      audioURL: audioFolder
                                        .appendingPathComponent("\(g.item.base).ogg"))
                    }
                    Text("指认后深脑再跑分析，用的就是真名而不是「说话人1」。")
                        .font(DS.bodyFont(DS.T.micro))
                        .foregroundStyle(DS.body(scheme == .dark))
                        .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }
}

// MARK: - 一条录音

private struct BulkGroupCard: View {
    @Environment(\.colorScheme) private var scheme
    let group: BulkNamingGroup
    @ObservedObject var store: BulkNamingStore
    let brain: DeepBrain
    @ObservedObject var audio: AudioPreview
    let audioURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow

            if let e = group.error {
                Text(e).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.bad)
            } else if !group.loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在读取说话人")
                        .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                }
            } else if group.rows.isEmpty {
                Text("这条转写里没有说话人记录。")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
            } else {
                ForEach(group.rows) { row in
                    BulkSpeakerCard(row: row,
                                    share: group.shares[row.label],
                                    sample: group.samples[row.label],
                                    recents: store.recents,
                                    people: store.people,
                                    // 同一条录音里已经被用掉的名字，点之前给个提醒。
                                    // 不禁用：切段录音里同一个人确实可能对应两个标签。
                                    usedHere: Set(group.rows
                                        .filter { $0.id != row.id }
                                        .compactMap { $0.confirmed ? $0.inferredIdentity : nil }),
                                    writing: store.writing.contains(row.id),
                                    error: store.rowErrors[row.id],
                                    onPlay: { secs in
                                        audio.toggle(base: group.item.base,
                                                     url: audioURL, startAt: secs)
                                    },
                                    onAssign: { name, pid in
                                        store.assign(groupId: group.id, row: row, name: name,
                                                     profileId: pid, brain: brain)
                                    })
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous)
            .fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous)
            .stroke(group.done ? DS.ok.opacity(0.35) : DS.border(scheme == .dark),
                    lineWidth: 1))
        // 认完的那条整体压暗一档，视线自然落到还没干完的上面
        .opacity(group.done ? 0.72 : 1)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: group.done ? "checkmark.circle.fill" : "waveform")
                .font(.system(size: 12))
                .foregroundStyle(group.done ? DS.ok : DS.iris)
            // 深脑分析后才有标题，这里一律显示日期时间——
            // 绝不把 note20260828-205856 这种文件名当标题给人看。
            Text(group.item.brainTitle ?? Fmt.dateTitle(group.item.base))
                .font(DS.bodyFont(DS.T.body, .semibold))
                .foregroundStyle(DS.title(scheme == .dark))
                .lineLimit(1)
            Text(Fmt.clock(Double(group.item.durationSec)))
                .font(DS.mono(10)).foregroundStyle(DS.muted)
            Spacer(minLength: 6)
            if group.loaded, !group.rows.isEmpty {
                StatusPill(text: group.done
                           ? "已认完"
                           : "\(group.confirmedCount)/\(group.rows.count) 已认",
                           tone: group.done ? .ok : .warn)
            }
        }
    }
}

// MARK: - 一个说话人

/// 一个待指认的说话人：占比 + 一句原话 + 试听 + 一排「最近用过」胶囊。
///
/// 为什么快捷方式做成**每个说话人一排胶囊**，而不是「整条沿用上一条的人」按钮：
/// diarization 的「说话人1/2/3」编号在录音之间没有任何稳定含义——
/// 这条里的说话人1，在下一条里完全可能是另一个人。
/// 一键整组映射看着最省事，实际是在批量制造张冠李戴，
/// 而错误的指认比没有指认更难被发现（它看起来像已经干完了）。
/// 所以这里只把**候选人**带过来，最后一下点击仍然由人做：
/// 省掉的是「翻一百个人」，不是「判断这是谁」。
private struct BulkSpeakerCard: View {
    @Environment(\.colorScheme) private var scheme
    let row: SpeakerRow
    let share: SpeakerShare?
    let sample: SpeakerSample?
    let recents: [RecentPerson]
    let people: [PersonProfile]
    let usedHere: Set<String>
    let writing: Bool
    let error: String?
    let onPlay: (Double) -> Void
    let onAssign: (String, String?) -> Void

    @State private var typed = ""
    /// 已指认的默认折叠成一行；点「改」才展开重认。
    @State private var editing = false

    private var named: Bool { !(row.inferredIdentity ?? "").isEmpty }
    private var showPicker: Bool { !row.confirmed || editing }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            identityRow
            if showPicker {
                if let s = share { shareBar(s) }
                if let s = sample { quoteButton(s) }
                pillRow
                fallbackRow
            }
            if let error {
                Text(error).font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.bad)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
            .fill(scheme == .dark ? DS.ink800.opacity(0.45) : DS.ink50))
    }

    // 标签 → 名字
    private var identityRow: some View {
        HStack(spacing: 6) {
            Text(String((row.inferredIdentity ?? row.label).prefix(1)))
                .font(DS.bodyFont(DS.T.meta, .semibold))
                .foregroundStyle(named ? DS.focus : DS.warn)
                .frame(width: 20, height: 20)
                .background(Circle().fill((named ? DS.focusSoft : DS.irisSoft)
                    .opacity(scheme == .dark ? 0.18 : 1)))

            Text(row.label)
                .font(DS.bodyFont(DS.T.title, .semibold))
                .foregroundStyle(named ? DS.body(scheme == .dark)
                                       : DS.title(scheme == .dark))

            if named {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9)).foregroundStyle(DS.muted)
                Text(row.inferredIdentity ?? "")
                    .font(DS.bodyFont(DS.T.title, .semibold)).foregroundStyle(DS.focus)
                    .lineLimit(1)
            }
            if row.confirmed { StatusPill(text: "已确认", tone: .ok) }

            Spacer(minLength: 4)

            if let s = share {
                Text("\(Int((s.fraction * 100).rounded()))%")
                    .font(DS.mono(10)).foregroundStyle(DS.muted).monospacedDigit()
            }
            if writing { ProgressView().controlSize(.small) }
            if row.confirmed && !writing {
                Button(editing ? "收起" : "改") { editing.toggle() }
                    .buttonStyle(.plain)
                    .font(DS.bodyFont(DS.T.meta))
                    .foregroundStyle(DS.focus)
            }
        }
    }

    private func shareBar(_ s: SpeakerShare) -> some View {
        GeometryReader { g in
            Capsule().fill(named ? DS.focusBright : DS.warn)
                .frame(width: max(3, g.size.width * s.fraction), height: 4)
        }
        .frame(height: 4)
    }

    /// 一句最长的原话 + 跳到那一秒试听。听一句就知道是谁，
    /// 比在十几分钟转写里自己找快一个数量级。
    private func quoteButton(_ s: SpeakerSample) -> some View {
        Button { onPlay(s.startSeconds) } label: {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "play.circle").font(.system(size: 12))
                Text(s.text).font(DS.bodyFont(DS.T.meta)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(Fmt.clock(s.startSeconds))
                    .font(DS.mono(10)).foregroundStyle(DS.muted)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.body(scheme == .dark))
    }

    /// 最近用过的人：一点即中。整个功能省时间的地方就在这一行。
    @ViewBuilder
    private var pillRow: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("最近用过")
                    .font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.muted)
                HStack(spacing: 5) {
                    // 只放前 5 个：再多就又变成一片要"找"的东西，
                    // 而胶囊的全部价值在于不用找。剩下的走下面的菜单。
                    ForEach(recents.prefix(5)) { p in
                        PersonPill(name: p.name,
                                   used: usedHere.contains(p.name),
                                   disabled: writing) {
                            onAssign(p.name, p.profileId)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 按输入筛出来的人。空输入时给「最近用过」，不给一百个人的字典。
    ///
    /// 原来这里是把 `people` 整个摊成一个菜单：一百多号人按字母排下来，
    /// 从「AI团队技术负责人」滚到「仁超」——而真正要认的往往是上一场刚认过的那几个。
    /// 认人是**回忆**，不是检索：先给最近的花名册，记不起来再打字找。
    private var candidates: [(name: String, profileId: String?)] {
        let q = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return recents.prefix(8).map { ($0.name, $0.profileId) }
        }
        // 前缀匹配排在包含匹配前面：打「丁」应该先看到「丁总」，不是「张丁一」
        let hit = people.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
        let pre = hit.filter { $0.displayName.lowercased().hasPrefix(q.lowercased()) }
        let rest = hit.filter { !$0.displayName.lowercased().hasPrefix(q.lowercased()) }
        return (pre + rest).prefix(8).map { ($0.displayName, $0.id) }
    }

    /// 兜底：先给最近的人，打字再从全部人物里筛。
    private var fallbackRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
            Menu {
                if candidates.isEmpty {
                    Text(typed.isEmpty ? "还没有用过的人物" : "没有匹配的人物")
                } else {
                    ForEach(candidates, id: \.name) { c in
                        Button(c.name) { onAssign(c.name, c.profileId) }
                    }
                }
            } label: {
                Label(typed.isEmpty ? "最近用过" : "匹配 \(candidates.count)",
                      systemImage: "person.crop.circle")
                    .font(DS.bodyFont(DS.T.meta))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 108)
            .disabled(writing || (people.isEmpty && recents.isEmpty))
            .help(typed.isEmpty ? "最近认过的人" : "从全部人物里筛出来的")

            TextField("搜人，或直接写名字", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(DS.bodyFont(DS.T.meta))
                .disabled(writing)
                .onSubmit {
                    onAssign(typed, nil)
                    typed = ""
                    editing = false
                }
            }
            // 打字时把匹配结果直接摊在下面，不用先点开菜单再滚——
            // 少一次点击，也让人立刻看见"有没有这个人"。
            if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !candidates.isEmpty {
                HStack(spacing: 5) {
                    ForEach(candidates.prefix(4), id: \.name) { c in
                        PersonPill(name: c.name, used: usedHere.contains(c.name),
                                   disabled: writing) { onAssign(c.name, c.profileId) }
                    }
                    if candidates.count > 4 {
                        Text("+\(candidates.count - 4)")
                            .font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.muted)
                    }
                }
            }
        }
    }
}

/// 一颗可点的人名胶囊。形状沿用设计系统的 pill 签名。
private struct PersonPill: View {
    @Environment(\.colorScheme) private var scheme
    let name: String
    /// 这条录音里已经有另一个标签指给他了。不拦，只提示。
    let used: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(name).font(DS.bodyFont(DS.T.meta, .medium)).lineLimit(1)
                if used {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                }
            }
            .foregroundStyle(used ? DS.warn : DS.focus)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill((used ? DS.warn : DS.focusBright)
                .opacity(scheme == .dark ? 0.18 : 0.10)))
            .overlay(Capsule().stroke((used ? DS.warn : DS.focusBright).opacity(0.35),
                                      lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(used ? "这条录音里已经有一个标签指给了\(name)" : "指认为 \(name)")
    }
}
