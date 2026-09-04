import LuyinbiCore
import SwiftUI

/// 本机录音搜索。
///
/// 要解决的是「上次讲到金 Spark 的是哪场？」——答案在自己导入过的那几十场录音里，
/// 不在整个知识库里。深脑网页的全局搜索是另一件事。
///
/// 全部命中来自本机索引，一次网络都不走：深脑自托管 Supabase 上带登录态的查询
/// 每次要 2 秒，边打字边搜的交互根本承受不起。索引怎么来的见 LocalSearch.swift。

// MARK: - 状态

/// 搜索状态。视图只读它，重建索引由外层（AppModel）在拿到深脑连接时驱动。
@MainActor
final class LocalSearchStore: ObservableObject {
    let engine: LocalSearch

    @Published var query = ""
    @Published private(set) var hits: [SearchHit] = []
    /// 上一次本地搜索耗时（毫秒）。放出来是为了让人相信「这是本机的」——
    /// 也方便以后索引变大时一眼看出退化。
    @Published private(set) var lastCostMs: Double = 0
    @Published private(set) var rebuilding = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var message: String?
    /// 索引里有多少条录音 / 多少句
    @Published private(set) var recordCount = 0
    @Published private(set) var lineCount = 0

    init(paths: SyncPaths = .default) {
        engine = LocalSearch(paths: paths)
        recordCount = engine.recordCount
        lineCount = engine.lineCount
    }

    func run(_ q: String) {
        let t0 = Date()
        hits = engine.search(q)
        lastCostMs = Date().timeIntervalSince(t0) * 1000
    }

    /// 增量重建：默认只补索引里还没有的录音，所以按一次几乎不花钱。
    /// force 用于「说话人改过名、标题分析出来了」这类需要刷新已有内容的场合。
    func rebuild(brain: DeepBrain, manifest: SyncManifest,
                 transcriptIds: [String: String] = [:], force: Bool = false) {
        guard !rebuilding else { return }
        rebuilding = true
        message = nil
        progress = (0, 0)
        Task { @MainActor in
            let report = await engine.rebuild(
                brain: brain, manifest: manifest,
                transcriptIds: transcriptIds, force: force,
                onProgress: { [weak self] done, total in self?.progress = (done, total) })
            recordCount = engine.recordCount
            lineCount = engine.lineCount
            message = report.summary
            rebuilding = false
            if !query.isEmpty { run(query) }
        }
    }

    /// 新导入一条录音时补这一条。转写还没出来会返回 false，外层过一会儿再来。
    @discardableResult
    func note(base: String, sessionId: String, transcriptId: String? = nil,
              brain: DeepBrain) async -> Bool {
        let ok = await engine.upsert(base: base, sessionId: sessionId,
                                     transcriptId: transcriptId, brain: brain)
        if ok {
            recordCount = engine.recordCount
            lineCount = engine.lineCount
            if !query.isEmpty { run(query) }
        }
        return ok
    }
}

// MARK: - 视图

struct SearchView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: LocalSearchStore
    /// 点一条命中：跳到这条录音，并播到这一秒。接线由外层负责。
    let onPick: (String, Double) -> Void
    /// 可选的「重建索引」动作。没接就不显示按钮，避免给一个按了没反应的入口。
    var onRebuild: (() -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            statusBar
            Divider()
            content
        }
        .background(DS.bg(scheme == .dark))
        // 防抖：本地搜索本身是毫秒级，但每敲一个字就重排一次列表，
        // 长列表下动画会追不上手速。120ms 足够把连打合成一次。
        // 用 .task(id:) 而不是自己管 Timer：切换 id 时旧任务自动取消，不会有竞态。
        .task(id: store.query) {
            let q = store.query
            if q.isEmpty { store.run(""); return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            store.run(q)
        }
    }

    // MARK: 搜索框

    private var searchBar: some View {
        let dark = scheme == .dark
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focused ? DS.focus : DS.ink300)
            TextField("搜这台机器导入过的录音", text: $store.query)
                .textFieldStyle(.plain)
                .font(DS.bodyFont(DS.T.body))
                .focused($focused)
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.muted)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                .fill(DS.surface(dark)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                .stroke(focused ? DS.focus.opacity(0.55) : DS.border(dark), lineWidth: 1))
        .padding(12)
        .onAppear { focused = true }
    }

    // MARK: 状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.rebuilding {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(store.progress.total > 0
                     ? "正在建索引 \(store.progress.done)/\(store.progress.total)"
                     : "正在建索引")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(.secondary)
            } else if let msg = store.message {
                Image(systemName: "checkmark.circle")
                    .imageScale(.small).foregroundStyle(DS.ok)
                Text(msg).font(DS.bodyFont(DS.T.meta)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(systemName: "internaldrive")
                    .imageScale(.small).foregroundStyle(DS.muted)
                Text("本机索引 \(store.recordCount) 条录音 · \(store.lineCount) 句")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(.secondary)
                if !store.hits.isEmpty {
                    Text(String(format: "命中 %d 处 · %.0f 毫秒",
                                store.hits.count, store.lastCostMs))
                        .font(DS.mono(10)).foregroundStyle(DS.muted)
                }
            }
            Spacer()
            if let onRebuild {
                Button(action: onRebuild) {
                    Label("更新索引", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(store.rebuilding)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: 结果

    @ViewBuilder
    private var content: some View {
        if store.recordCount == 0 {
            EmptyHint(icon: "tray",
                      title: "还没有本机索引",
                      detail: "索引建起来之后，搜自己导入过的录音就不用等网络了")
        } else if store.query.isEmpty {
            EmptyHint(icon: "text.magnifyingglass",
                      title: "搜转写里说过的话",
                      detail: "输入词句即可，中英文都行；点结果直接跳到那一秒")
        } else if store.hits.isEmpty {
            EmptyHint(icon: "questionmark.circle",
                      title: "没找到「\(store.query)」",
                      detail: "只搜本机索引里的 \(store.recordCount) 条录音；\n还没进索引的可以先更新索引")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.hits) { hit in
                        HitRow(hit: hit, onPick: onPick)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - 单条命中

private struct HitRow: View {
    @Environment(\.colorScheme) private var scheme
    let hit: SearchHit
    let onPick: (String, Double) -> Void

    @State private var hovering = false

    /// 深脑的标题是分析的产物，没分析过就没有；那时退回按文件名里的时间显示，
    /// 不能把 note20260828-205856 当标题给人看。
    private var titleText: String { hit.title ?? Fmt.dateTitle(hit.base) }

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .imageScale(.small)
                    .foregroundStyle(DS.focus)
                Text(titleText)
                    .font(DS.bodyFont(DS.T.title, .semibold))
                    .foregroundStyle(DS.title(dark))
                    .lineLimit(1)
                if hit.title != nil {
                    // 有深脑标题时，日期就不再是标题，单独补一格，否则看不出是哪天
                    Text(Fmt.dateTitle(hit.base))
                        .font(DS.bodyFont(DS.T.meta))
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "play.circle")
                    .imageScale(.medium)
                    .foregroundStyle(hovering ? DS.focusBright : DS.ink300)
            }

            Text(highlighted)
                .font(DS.bodyFont(DS.T.title))
                .foregroundStyle(DS.body(dark))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "person.wave.2")
                    .imageScale(.small)
                    .foregroundStyle(DS.muted)
                Text(hit.speaker.isEmpty ? "未标注" : hit.speaker)
                    .font(DS.bodyFont(DS.T.meta, .medium))
                    .foregroundStyle(hit.speaker.isEmpty ? DS.ink300 : DS.iris)
                Text(Fmt.clock(hit.startSeconds))
                    .font(DS.mono(10))
                    .foregroundStyle(DS.muted)
                if let wall = Fmt.wallClock(base: hit.base, offset: hit.startSeconds) {
                    Text("· \(wall)")
                        .font(DS.mono(10))
                        .foregroundStyle(DS.muted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                .fill(hovering ? DS.focusSoft.opacity(dark ? 0.10 : 1) : DS.surface(dark)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                .stroke(hovering ? DS.focus.opacity(0.4) : DS.border(dark), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onPick(hit.base, hit.startSeconds) }
        .help("跳到 \(titleText) 的 \(Fmt.clock(hit.startSeconds))")
    }

    /// 高亮。用 AttributedString 而不是拼 Text：
    /// Text.foregroundColor 在 macOS 14 起已废弃，包又要支持 macOS 13，
    /// 拼 Text 会带来一串废弃告警。AttributedString 两边都干净。
    private var highlighted: AttributedString {
        var out = AttributedString()
        for part in hit.parts {
            var piece = AttributedString(part.text)
            if part.isMatch {
                piece.foregroundColor = DS.focus
                piece.backgroundColor = DS.focus.opacity(0.14)
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            out.append(piece)
        }
        return out
    }
}
