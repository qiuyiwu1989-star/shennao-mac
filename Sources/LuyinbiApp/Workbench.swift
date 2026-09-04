import LuyinbiCore
import SwiftUI

/// 双层波形：上面是当前视窗的细节，下面一条是整段概览带播放头。
///
/// 为什么要两层：一小时的录音压进一条 160 根柱子的波形里，每根柱子代表 22 秒——
/// 那已经不是波形，是一条噪声带，看不出任何结构。苹果的语音备忘录就是这么解决的。
/// 单条波形。
///
/// 这里原来是「细节视窗 + 概览条」两条：长录音把当前 5 分钟放大在上面，
/// 整段缩略摆在下面，还画一个视窗框。想法是能看清细节，实际是——
/// 两条形状不同的灰波并排，谁也不知道哪条才是"这段录音"，那个视窗框
/// 又长得像个输入框。播放器的波形是拿来**定位**的，不是拿来看波形的：
/// 一条覆盖整段、点哪跳哪，才对得上"我在整段的什么位置"。
///
/// 放大留给需要它的地方（逐句转写本来就能点句子跳秒），不占播放条。
struct DualWaveformView: View {
    @Environment(\.colorScheme) private var scheme
    let peaks: [Float]
    let progress: Double
    let durationSec: Int
    let onSeek: (Double) -> Void

    var body: some View {
        WaveformView(peaks: peaks, progress: progress, onSeek: onSeek)
            .frame(height: 34)
            .accessibilityElement()
            .accessibilityLabel("播放进度条")
            .accessibilityValue(Fmt.clock(progress * Double(durationSec)))
            .accessibilityAdjustableAction { dir in
                let step = 5.0 / max(1, Double(durationSec))
                onSeek(min(1, max(0, progress + (dir == .increment ? step : -step))))
            }
    }
}

struct WaveformView: View {
    @Environment(\.colorScheme) private var scheme
    let peaks: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { i, v in
                    let played = Double(i) / Double(max(1, peaks.count)) <= progress
                    Capsule()
                        .fill(played ? DS.focusBright : DS.ink300.opacity(0.45))
                        .frame(width: 2, height: max(3, CGFloat(v) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture { p in onSeek(min(1, max(0, p.x / geo.size.width))) }
        }
    }
}

/// 录音工作台：播放器 + 波形在上，逐句转写与说话人在下。
///
/// 这里只放「需要音频本身」的东西。总结、要点、导图、标签都在深脑网页——
/// 它们只需要文本，网页做得更好，两边各做一遍是白费。
struct WorkbenchView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel
    @ObservedObject var store: SpeakerStore
    @ObservedObject var audio: AudioPreview
    let item: RecordingItem

    private var audioURL: URL { model.importFolder.appendingPathComponent("\(item.base).ogg") }

    /// 已播秒数。用播放器的真实位置，不是拿进度比例乘时长——那会和实际差半秒。
    private var playedSeconds: Double {
        audio.playingBase == item.base ? audio.currentSeconds : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            chainBar
            playerBar
            Divider()
            HStack(spacing: 0) {
                transcriptColumn
                // 没有转写就没有说话人可认。留着这一栏只会显示「正在读取…」
                // 或者一片空白，还把本来就空的正文挤窄 218pt——
                // 空栏不是「暂时没内容」，是这条录音**根本还不到那一步**。
                if item.transcriptId != nil {
                    Divider()
                    speakerColumn.frame(width: 248)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: item.id) { _ in reload() }
        // transcriptId 会在文件名不变的情况下出现（轮询查回来的那一刻）。
        // 只盯 item.id 的话，那条录音的转写永远不会被加载，
        // 面板就一直显示上一条的内容——看起来毫无破绽。
        .onChange(of: item.transcriptId) { _ in reload() }
    }

    private func reload() {
        audio.stop()
        // 标题取回来之后要回填到列表项上，否则左边列表还是显示文件名
        store.currentBase = item.base
        store.onTitleLoaded = { [weak model] base, title in
            model?.applyBrainTitle(base: base, title: title)
        }
        store.loadWaveform(base: item.base, audio: audioURL, root: model.projectRoot)
        if let tid = item.transcriptId, let brain = model.brain {
            store.load(transcriptId: tid, brain: brain, force: true)
        }
    }

    /// 标题优先用深脑生成的（分析之后才有）；没有就显示日期时间。
    /// 绝不把 note20260828-205856 当标题给人看——那不是标题，是文件名。
    /// 单条录音的动作。
    ///
    /// 这些能力一直都在（AppActions 里的 repush / redownload / revealLocal /
    /// deleteFromDevice），只是旧的详情面板被新界面取代时，入口跟着没了——
    /// 代码还在，人点不到。「强推」和「从设备重下」正是卡住时唯一能自救的两个动作。
    ///
    /// 收进「…」菜单而不是摆一排按钮：它们都是**例外情况**才用的，
    /// 常态下摆在那儿只会和播放、收藏抢注意力。
    private var actionMenu: some View {
        Menu {
            Button("还是推给深脑") { model.actions.repush(item) }
                .disabled(!item.onDisk)
            Button("从设备重新下载") { model.actions.redownload(item) }
                .disabled(item.deviceSize == nil)
            Divider()
            Button("在访达中显示") { model.actions.revealLocal(item) }
                .disabled(!item.onDisk)
            if item.transcriptId != nil {
                Button("在深脑里打开") { model.actions.openBrainSession(item) }
            }
            Divider()
            // 删设备原件不可逆，单独放在最后并标红
            Button(role: .destructive) { model.actions.deleteFromDevice(item) } label: {
                Text("从设备删除")
            }
            .disabled(item.deviceSize == nil)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 26)
        .help("这条录音的其他动作")
    }

    /// 上传前定名字与项目。
    ///
    /// 这是唯一能定的时机——`POST /api/recordings` 收 title 和 projectId，
    /// 建会话那一刻之后就只能靠分析自己起标题了。也正是有用的时刻：
    /// 刚开完会还记得这是什么，比事后对着一列时间戳猜要强。
    private var planMenu: some View {
        Menu {
            Section("名字") {
                // 菜单里放输入框不合适，用几个常见前缀 + 「用文件名」兜底
                Button(item.plannedTitle == nil ? "✓ 用文件名" : "用文件名") {
                    model.actions.setPlan(item, nil, item.plannedProjectId)
                }
            }
            if !model.projects.isEmpty {
                Section("归到项目") {
                    Button(item.plannedProjectId == nil ? "✓ 不归项目" : "不归项目") {
                        model.actions.setPlan(item, item.plannedTitle, nil)
                    }
                    ForEach(model.projects, id: \.id) { p in
                        Button(item.plannedProjectId == p.id ? "✓ \(p.name)" : p.name) {
                            model.actions.setPlan(item, item.plannedTitle, p.id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: item.plannedProjectId != nil || item.plannedTitle != nil
                  ? "tag.fill" : "tag")
                .font(.system(size: 12))
                .foregroundStyle(item.plannedProjectId != nil || item.plannedTitle != nil
                                 ? DS.focus : DS.muted)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 26)
        .help("上传前定名字与项目——推上去之后就改不了了")
    }

    /// 这条录音走到哪一站了。
    ///
    /// 只在**还没走完**时显示：走完了这一条就是噪声，五个绿勾天天挂在那儿
    /// 反而让真正卡住的那条不显眼。这跟列表里「状态只在要人动手时才出现」是同一条规矩。
    @ViewBuilder
    private var chainBar: some View {
        let st = ChainStatus(item: item, activity: nil)
        if st.analysis != .done {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                ChainView(status: st)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .background(DS.sunkenBg(scheme == .dark))
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text(store.title ?? Fmt.dateTitle(item.base))
                .font(DS.heading(14, .semibold)).dsHeading()
                .foregroundStyle(DS.title(scheme == .dark))
                .lineLimit(1)
            if store.title == nil, item.inBrain {
                Text("分析之后深脑会自动起标题")
                    .font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.muted)
            }
            Spacer()
            Button { model.actions.toggleStar(item) } label: {
                Image(systemName: item.starred ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(item.starred ? DS.warn : DS.ink300)
            }
            .buttonStyle(.plain)
            .help(item.starred ? "取消收藏" : "收藏")

            // 上传前才给命名入口：推上去之后转写受 canonical 守卫保护，
            // 摆个改不动的输入框比不摆更糟。
            if !item.inBrain { planMenu }
            actionMenu

            Text(Fmt.dateTitle(item.base))
                .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }

    // MARK: 播放器
    private var playerBar: some View {
        HStack(spacing: 8) {
            Button { audio.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 15))
            }
            .buttonStyle(.plain).foregroundStyle(DS.body(scheme == .dark))
            .disabled(audio.playingBase != item.base)

            Button {
                audio.toggle(base: item.base, url: audioURL)
            } label: {
                Image(systemName: audio.playingBase == item.base ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.focusBright))
            }
            .buttonStyle(.plain)
            .disabled(!item.onDisk)

            Button { audio.skip(15) } label: {
                Image(systemName: "goforward.15").font(.system(size: 15))
            }
            .buttonStyle(.plain).foregroundStyle(DS.body(scheme == .dark))
            .disabled(audio.playingBase != item.base)

            // 显示真实时钟时间，不是"第几分钟"。
            // 会议里「那个决定是几点说的」比「第 22 分钟」有用得多——这是苹果语音备忘录的做法。
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.clock(playedSeconds))
                    .font(DS.mono(12)).foregroundStyle(DS.title(scheme == .dark))
                if let wall = Fmt.wallClock(base: item.base, offset: playedSeconds) {
                    Text(wall).font(DS.mono(9)).foregroundStyle(DS.muted)
                }
            }
            .frame(width: 52, alignment: .leading)

            if store.waveform.isEmpty {
                // 波形是装饰：不影响播放、不影响转写、不影响任何判断。
                // 所以不自动算——一条 1.5 小时的录音要解码全程，二十多秒满载 CPU，
                // 而用户只是点了一下列表。
                //
                // 给一条能点的静默占位，并说清楚点了会发生什么。
                Button {
                    store.ensureWaveform(base: item.base, audio: audioURL, root: model.projectRoot)
                } label: {
                    Text("显示波形（要解码一遍，长录音需要几秒）")
                        .font(DS.bodyFont(DS.T.meta))
                        .foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
            } else {
                DualWaveformView(peaks: store.waveform,
                                 progress: audio.playingBase == item.base ? audio.progress : 0,
                                 durationSec: item.durationSec) { p in
                    audio.toggle(base: item.base, url: audioURL,
                                 startAt: p * Double(item.durationSec))
                }
            }

            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.clock(Double(item.durationSec)))
                    .font(DS.mono(11)).foregroundStyle(DS.body(scheme == .dark))
                if let wall = Fmt.wallClock(base: item.base, offset: Double(item.durationSec)) {
                    Text(wall).font(DS.mono(9)).foregroundStyle(DS.muted)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: 逐句转写
    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("转写").font(DS.bodyFont(DS.T.title, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
                Text("点句子跳到那一秒").font(DS.bodyFont(DS.T.meta))
                    .foregroundStyle(DS.body(scheme == .dark))
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

            if store.loadedFor != item.transcriptId {
                // 数据还没对上号就什么都不显示，宁可空着也不能显示别人的转写。
                //
                // 但「空着」和「一句话飘在一千像素的正中间」是两回事：
                // 后者看起来像界面坏了。没转写是有原因的，把原因和下一步写出来。
                if item.transcriptId == nil {
                    EmptyHint(icon: "text.bubble", title: "还没有转写",
                              detail: emptyReason)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取转写")
                            .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("正在读取转写")
                }
            } else if store.segments.isEmpty && !store.loading {
                EmptyHint(icon: "text.bubble", title: "还没有转写",
                          detail: item.inBrain ? "深脑还在处理" : "推给深脑之后才有转写")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(store.segments) { seg in
                                segmentRow(seg).id(seg.id)
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 12)
                    }
                    // 播到哪儿就滚到哪儿。不然听到一半还得自己找位置，
                    // 「点句子跳到那一秒」这个交互就只有一半。
                    .onChange(of: currentSegmentID) { id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 当前句的 id，用于滚动跟随
    private var currentSegmentID: String? {
        guard audio.playingBase == item.base else { return nil }
        return store.segments.first { isPlaying($0) }?.id
    }

    /// 当前正在播的是哪一句。高亮它，眼睛才跟得上耳朵。
    private func isPlaying(_ seg: TranscriptSegment) -> Bool {
        guard audio.playingBase == item.base else { return false }
        let t = playedSeconds
        return t >= seg.startSeconds && t < Double(seg.endMs) / 1000
    }

    private func segmentRow(_ seg: TranscriptSegment) -> some View {
        let name = store.rows.first { $0.label == seg.speaker }?.inferredIdentity
        let tone = SpeakerPalette.color(for: seg.speaker)
        let active = isPlaying(seg)
        return HStack(alignment: .top, spacing: 8) {
            // 色点：扫一眼就知道谁在说，不用逐字读名字。
            // 这比把名字染成橙色（「未指认」）有用得多——
            // 未指认是「你要做的事」，该出现在待办区，不该染满整篇转写。
            Circle().fill(tone).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name ?? seg.speaker)
                        .font(DS.bodyFont(DS.T.meta, .medium))
                        .foregroundStyle(name == nil ? DS.body(scheme == .dark) : tone)
                    Text(Fmt.clock(seg.startSeconds))
                        .font(DS.mono(10)).foregroundStyle(DS.muted)
                }
                Text(seg.text).font(DS.bodyFont(12.5))
                    .foregroundStyle(DS.title(scheme == .dark))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.R.sm, style: .continuous)
            .fill(active ? tone.opacity(scheme == .dark ? 0.16 : 0.09) : .clear))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            audio.toggle(base: item.base, url: audioURL, startAt: seg.startSeconds)
        }
    }

    /// 「还没有转写」背后其实有四种不同处境，笼统一句话等于没说。
    private var emptyReason: String {
        if !item.inBrain { return "这条还没推给深脑，同步之后深脑才会转写" }
        if item.brainStatus == "failed" { return item.lastError ?? "深脑转写失败了，可以在深脑里重试" }
        return "深脑正在转写，好了会自动出现在这里"
    }

    // MARK: 说话人
    private var speakerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("说话人").font(DS.bodyFont(DS.T.title, .semibold))
                        .foregroundStyle(DS.title(scheme == .dark))
                    Text("\(store.rows.count)").font(DS.bodyFont(DS.T.meta))
                        .foregroundStyle(DS.muted)
                }

                if store.loadedFor != item.transcriptId {
                    Text("正在读取…")
                        .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                } else if store.rows.isEmpty && !store.loading {
                    Text("转写好之后这里会列出说话人。")
                        .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                }

                ForEach(store.loadedFor == item.transcriptId ? store.rows : []) { row in
                    SpeakerShareRow(row: row,
                                    share: store.shares.first { $0.label == row.label },
                                    sample: store.samples[row.label],
                                    people: store.people,
                                    onPlay: { secs in
                                        audio.toggle(base: item.base, url: audioURL, startAt: secs)
                                    },
                                    onAssign: { name, pid in
                                        if let brain = model.brain {
                                            store.assign(row, name: name, profileId: pid, brain: brain)
                                        }
                                    })
                }

                if store.readOnly {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这条录音的说话人要在深脑网页里指认。")
                            .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("录音链路的数据是权威数据，深脑只允许服务端改——改名同时要重挂洞察归属、升级人物库，客户端改不全。")
                            .font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.actions.openBrainSession(item) } label: {
                            Label("去深脑指认", systemImage: "arrow.up.forward")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(DSPrimaryButtonStyle())
                    }
                } else if let m = store.message {
                    Text(m).font(DS.bodyFont(DS.T.meta))
                        .foregroundStyle(m.contains("失败") ? DS.bad : DS.ok)
                }
            }
            .padding(14)
        }
    }
}

/// 一个说话人：占比条 + 一句原话 + 指认。
/// 没指认的用警告色顶到最前——刚导进来时全都是「说话人1/2/3」，那才是默认状态。
private struct SpeakerShareRow: View {
    @Environment(\.colorScheme) private var scheme
    let row: SpeakerRow
    let share: SpeakerShare?
    let sample: SpeakerSample?
    let people: [PersonProfile]
    let onPlay: (Double) -> Void
    let onAssign: (String, String?) -> Void

    @State private var typed = ""
    /// 输入控件默认收起。
    ///
    /// 三个说话人各摆一套「从人物里选 + 手写名字」，就是六个输入控件同时占着屏幕，
    /// 而你一次只认一个人。收起来之后这一栏从「一堵表单墙」变成「三行名单」。
    @State private var expanded = false

    private var named: Bool { !(row.inferredIdentity ?? "").isEmpty }
    private var tone: Color { SpeakerPalette.color(for: row.label) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Text(SpeakerPalette.initial(for: row.label, name: row.inferredIdentity))
                        .font(DS.bodyFont(DS.T.micro, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(tone))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.inferredIdentity ?? row.label)
                            .font(DS.bodyFont(DS.T.title, named ? .semibold : .regular))
                            .foregroundStyle(DS.title(scheme == .dark))
                            .lineLimit(1)
                        if !named {
                            Text("未指认").font(DS.bodyFont(DS.T.micro))
                                .foregroundStyle(DS.warn)
                        }
                    }
                    Spacer(minLength: 4)
                    if let s = share {
                        Text("\(Int((s.fraction * 100).rounded()))%")
                            .font(DS.mono(10)).foregroundStyle(DS.muted)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(DS.muted)
                }
            }
            .buttonStyle(.plain)

            if let s = share {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.glyph.opacity(scheme == .dark ? 0.18 : 0.7))
                        Capsule().fill(tone)
                            .frame(width: max(3, g.size.width * s.fraction))
                    }
                }
                .frame(height: 3)
            }

            if expanded {
                if let sample {
                    Button { onPlay(sample.startSeconds) } label: {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "play.circle").font(.system(size: 11))
                            Text(sample.text).font(DS.bodyFont(DS.T.meta)).lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.body(scheme == .dark))
                }

                Menu {
                    ForEach(people) { p in
                        Button(p.displayName) { onAssign(p.displayName, p.id); expanded = false }
                    }
                } label: {
                    Label("从深脑人物里选", systemImage: "person.crop.circle")
                        .font(DS.bodyFont(DS.T.meta))
                }
                .menuStyle(.borderlessButton)

                TextField("或直接写名字", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.bodyFont(DS.T.meta))
                    .onSubmit { onAssign(typed, nil); typed = ""; expanded = false }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
            .fill(scheme == .dark ? DS.ink800.opacity(0.45) : DS.ink50))
        .onAppear { expanded = !named }   // 没认的默认展开一个，认完自动收起
    }
}
