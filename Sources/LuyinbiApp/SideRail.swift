import SwiftUI
import LuyinbiCore

/// 左侧两个入口。
///
/// 之前一个窗口里挤着三件不相干的事：同步来的内容、录音笔的状态、以及要新录的音。
/// 它们被硬塞进同一套「列表 + 工作台」里——录音笔的电量和容量只好挤在顶栏，
/// 而顶栏本该放当前这条录音的动作。结果是每一处都在替另一处让位。
///
/// 拆开之后，每块只回答一个问题：
///   · 内容 —— 我攒下了什么、每一条走到哪一步了
///   · 设备 —— 录音笔现在什么状况
///
/// 「录音」那一块按 spec 012 砍掉了：CB08 是专用硬件、手机也能录，
/// Mac 坐在桌上当录音笔的场景不成立。
enum RailSection: String, CaseIterable, Identifiable {
    case library, device
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "内容"
        case .device:  return "设备"
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.stack"
        case .device:  return "dot.radiowaves.left.and.right"
        }
    }
}

struct SideRail: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var section: RailSection
    /// 录音笔在不在线。**同步期间一律算在线**——CB08 是「连上传十几秒就断、
    /// 然后再连」的节奏，按瞬时状态画这个点，同步时它会一直闪
    /// （2026-09-08 用户看到的正是这种自相矛盾：顶栏在下载，设备页写未连接）。
    let deviceConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RailSection.allCases) { s in
                Button { section = s } label: { label(s) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == s ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(Text(voiceOver(s)))
            }
        }
        .padding(8)
    }

    /// 单独拎出来：整条链写在 Button 的 label 里，Swift 的类型检查器会在
    /// 三元表达式 + 修饰符长链上超时（"unable to type-check in reasonable time"）。
    private func label(_ s: RailSection) -> some View {
        let on = section == s
        let fill: Color = on ? DS.focusSoft.opacity(scheme == .dark ? 0.18 : 1) : .clear
        let fg: Color = on ? DS.focus : DS.body(scheme == .dark)
        return HStack(spacing: 8) {
            Image(systemName: s.icon).font(.system(size: 13)).frame(width: 16)
            Text(s.title).font(DS.bodyFont(DS.T.title, on ? .semibold : .regular))
            Spacer(minLength: 4)
            badge(for: s)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.R.base).fill(fill))
        .foregroundStyle(fg)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func badge(for s: RailSection) -> some View {
        switch s {
        case .device:
            Circle()
                .fill(deviceConnected ? DS.ok : DS.glyph)
                .frame(width: 6, height: 6)
        default:
            EmptyView()
        }
    }

    /// 读屏要念出「为什么这里有个点」，光念「设备」等于没说。
    private func voiceOver(_ s: RailSection) -> String {
        switch s {
        case .library: return "内容"
        case .device:  return deviceConnected ? "设备，录音笔已连接" : "设备，录音笔未连接"
        }
    }
}

/// 设备页：录音笔现在什么状况，以及同步/清理的规矩是什么。
///
/// 这些信息原来散在顶栏一行小字和设置面板里。它们跟「内容」不是一类东西——
/// 内容是攒下来的结果，设备是此刻的硬件状态，混在一起谁也看不清。
struct DevicePage: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel

    private var dev: DeviceInfo { model.device }

    /// 点笔上某一条 → 跳到「内容」里那一条。
    /// 没有这个出口的话，设备页只能告诉你「已导入」，却不能带你去看。
    var onOpen: (String) -> Void = { _ in }

    @State private var draftName = ""
    @State private var renaming = false
    @State private var renameNote: String?

    /// 设备里还没导进来的条数。这是设备页真正要回答的问题。
    ///
    /// **不含设备自己报 0 字节的条目。** 2026-09-09：录音笔上有一条 8 月 29 号的
    /// 空录音，设备在列表里就报着 time=0 size=0。它永远导不进来（没内容可导），
    /// 于是这里永远显示「等着导入 1 条」——用户看到的是「连上又断、
    /// 老有一条卡着」，而链路完全正常。
    /// 一个永远不会变的「待办」不是待办，是噪音。
    private var pendingImport: Int {
        model.items.filter { ($0.deviceSize ?? 0) > 0 && $0.localBytes == nil }.count
    }

    /// 设备上的空文件条数。单独说，因为它既不是「等着导入」也不是「失败」——
    /// 是录音笔上本来就没内容的一条，用户唯一能做的是把它删掉。
    private var emptyOnDevice: Int {
        model.items.filter { $0.deviceSize == 0 && $0.localBytes == nil }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let m = model.pendingBindMismatch { bindMismatchCard(m) }
                header
                grid
                identity
                onDevice
                rules
                archive
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 设备-账号绑定不一致（spec 019）——放在这一页最上面，不能被当成
    /// 普通的运维提示划过去。这是 2026-09-03 那次事故之后补的闸：
    /// 同步已经被引擎拦下了，这张卡片是唯一能把它放行的地方。
    @ViewBuilder
    private func bindMismatchCard(_ m: BindMismatch) -> some View {
        BindMismatchCard(mismatch: m, scheme: scheme,
            onConfirm: { name in await model.actions.resolveBindMismatch(name) },
            onCancel: { model.actions.dismissBindMismatch() })
    }

    // MARK: - 这支笔叫什么

    /// **型号名认不出是哪一支。** 所有 CB08 都报「CB08」，
    /// 而 2026-09-11 实测本机已经见过三支笔——它们在深脑里共用了同一行记录，
    /// 因为默认名是「型号 + 这台 Mac 的名字」拼的，两半都不认笔。
    /// 现在默认名带上本机标识所以至少分得开，但分得开不等于认得出：
    /// 「客厅那支 / 随身那支」这种名字只有你能起。
    @ViewBuilder
    private var identity: some View {
        if dev.bindingName != nil || dev.peripheralId != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("这支笔").font(DS.bodyFont(DS.T.body, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
                Text("深脑里按这个名字记账。型号名所有 CB08 都一样，认不出是哪一支。")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("给它起个名字", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { commitRename() }
                    Button("改名") { commitRename() }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(renaming || draftName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || draftName == dev.bindingName)
                    if renaming { ProgressView().controlSize(.small) }
                }
                if let note = renameNote {
                    Text(note).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(DS.surface(scheme == .dark))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { if draftName.isEmpty { draftName = dev.bindingName ?? "" } }
            .onChange(of: dev.bindingName) { n in draftName = n ?? "" }
        }
    }

    private func commitRename() {
        let want = draftName
        guard !renaming, !want.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        renaming = true; renameNote = nil
        Task {
            let err = await model.actions.renameDevice(want)
            renaming = false
            renameNote = err
        }
    }

    // MARK: - 笔上有什么

    /// 笔上的文件清单。
    ///
    /// 2026-09-11 用户问「点进设备能不能看里面有哪些文件」——数据其实一直都在，
    /// 每一轮同步都会把完整列表读回来，只是界面只给了一个数字。
    ///
    /// **必须标明这是上次连接时的快照。** 笔不在的时候这份清单就是旧的，
    /// 不写读取时间就又变成「界面说着一个它并不掌握的当下状态」——
    /// 跟「未连接」那一次是同一类错。
    @ViewBuilder
    private var onDevice: some View {
        let files = model.items.filter { $0.deviceSize != nil }
            .sorted { $0.base > $1.base }
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("笔上的文件").font(DS.bodyFont(DS.T.body, .semibold))
                        .foregroundStyle(DS.title(scheme == .dark))
                    Text("\(files.count) 条").font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                    Spacer()
                    Text(snapshotAge).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

                ForEach(files) { f in
                    Divider().opacity(0.5)
                    let openable = f.localBytes != nil
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.brainTitle ?? f.base).font(DS.bodyFont(DS.T.meta))
                                .foregroundStyle(DS.title(scheme == .dark)).lineLimit(1)
                            Text(deviceLine(f)).font(DS.bodyFont(DS.T.meta))
                                .foregroundStyle(DS.muted)
                        }
                        Spacer(minLength: 8)
                        StatusPill(text: deviceState(f).0, tone: deviceState(f).1)
                        // 已经导进来的才有地方可去。
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.muted)
                            .opacity(openable ? 1 : 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { if openable { onOpen(f.base) } }
                    .help(openable ? "在「内容」里打开这一条" : "还没导进来")
                }
            }
            .background(DS.surface(scheme == .dark))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var snapshotAge: String {
        guard let t = model.lastRun else { return "还没读过" }
        let sec = Int(Date().timeIntervalSince(t))
        if working { return "正在读" }
        if sec < 90 { return "刚读的" }
        if sec < 3600 { return "\(sec / 60) 分钟前读的" }
        return "\(sec / 3600) 小时前读的"
    }

    private func deviceLine(_ f: RecordingItem) -> String {
        var parts: [String] = []
        if f.durationSec > 0 { parts.append(Fmt.duration(f.durationSec)) }
        if let b = f.deviceSize, b > 0 { parts.append(String(format: "%.1f MB", Double(b) / 1_048_576)) }
        return parts.isEmpty ? "空文件" : parts.joined(separator: "　")
    }

    /// 每一条在笔上的状态。**空文件单独说**——它永远导不进来，
    /// 混进「等着导入」会让人以为同步坏了（2026-09-11 修）。
    private func deviceState(_ f: RecordingItem) -> (String, StatusPill.Tone) {
        if f.deviceSize == 0 { return ("空录音", .warn) }
        if f.localBytes != nil { return ("已导入", .ok) }
        return ("等着导入", .idle)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: working || dev.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                .font(.system(size: 20))
                .foregroundStyle(working || dev.connected ? DS.focus : DS.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name).font(DS.bodyFont(DS.T.head, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
                Text(connectionLine)
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if dev.connected, dev.recordStatus == 1 {
                StatusPill(text: "正在录音", tone: .warn)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            // **这三格跟标题行、图标用同一个判据（present），不能用瞬时的 connected。**
            //
            // 2026-09-10 用户连拍两张截图问「这是连着还是断了」：同一秒的下载
            // 百分比一模一样，电量却一张是「—」、一张是 84%。原因就是这里写的是
            // `dev.connected ? 真值 : "—"`——而一轮同步里 connected 每十几秒
            // 翻一次（连上→传→被设备断开→再连），于是这两格一直在闪。
            // 固件当时反而稳定，因为它两个分支取的是同一个值，正好把 bug 藏住了。
            //
            // 原来那句「断开之后是上次同步的读数，不是现状」本身没错，但它说的是
            // **设备真的不在了**；同步中途那十几秒的空档不属于这种情况。
            stat("电量", hardware(dev.battery == nil ? nil : battery))
            stat("容量", hardware(capacityValue))
            stat("固件", hardware(dev.firmware))
            stat("等着导入", pendingImport == 0 ? "都导完了" : "\(pendingImport) 条")
            if emptyOnDevice > 0 {
                stat("设备上的空录音", "\(emptyOnDevice) 条")
            }
        }
    }

    /// 「此刻连着没有」这个瞬时值，不能直接当成给人看的状态。
    ///
    /// CB08 的实际工作方式是**连上→传十几秒→被设备断开→再连**，一轮一轮来
    /// （2026-09-08 实测：一个 4MB 的文件是分十几次连接搬回来的）。
    /// 于是任意一个瞬间去看，多半正好在两次连接之间——界面就写着「未连接」，
    /// 而顶栏同时显示「下载 21%」。用户看到的是两句互相矛盾的话，
    /// 而真相是一切正常。
    ///
    /// 所以这里按**正在做的事**说话，而不是按那一瞬间的 BLE 状态。
    /// 正在跟录音笔打交道（哪怕此刻恰好断在两次连接之间）。
    private var working: Bool {
        switch model.phase {
        case .downloading, .listing, .connecting, .cleaning: return true
        default: return false
        }
    }

    private var connectionLine: String {
        switch model.phase {
        case .downloading(_, let pct):
            return "正在同步 \(pct)%——录音笔每传十几秒会断开一次再自动连上，这是它的正常节奏"
        case .listing, .connecting:
            return "正在读取录音笔"
        case .cleaning:
            return "正在清理录音笔"
        default:
            return dev.connected ? "已连接" : "未连接——录音笔开机后会自动广播，这里就会亮"
        }
    }

    private var battery: String {
        guard let b = dev.battery else { return "—" }
        return b == 110 ? "充电中" : "\(b)%"
    }

    /// 还没读到这几项时给的话。它们只在「这一轮没东西要下」时才读——
    /// 正在搬文件的时候，那十几秒的窗口全都留给传输。
    private var idleHint: String { model.isBusy ? "同步中，稍后读" : "—" }

    /// 剩余空间，**用百分比说**。
    ///
    /// 2026-09-11：这里原来写的是 `remain / 1024 / 1024` 加个 M，
    /// 于是显示成「剩 28M / 共 29M」——而笔上单个文件就有 20.6MB，
    /// 并且那个数还意味着「三十来条录音只占了 1M」。两个数字自己打架。
    ///
    /// 根因是**这两个数的单位不是字节**：厂商文档标 8KB 一格，早期实测觉得
    /// 更接近 64B，协议层因此明确拒绝替设备换算。界面却擅自当字节用了。
    ///
    /// 百分比不需要知道单位就永远成立，而且「还剩多少」本来就是这一格
    /// 要回答的问题。等日志里的标定攒够、单位定死了，再把绝对值加回来——
    /// **在那之前，宁可少说一个数，也不摆一个假的。**
    private var capacityValue: String? {
        guard let remain = dev.capacityRemain, let total = dev.capacityTotal, total > 0 else { return nil }
        return "剩 \(Int((Double(remain) / Double(total) * 100).rounded()))%"
    }

    /// 一格硬件读数该显示什么。
    ///
    /// 三种状态，必须分清楚，否则一个「—」要替三件事背锅：
    /// - 设备在（连着，或正在这一轮里跟它打交道）且读到了 → 摆数字，
    ///   **中途断开的那十几秒也照样摆**，它十秒前才读的，不算过期；
    /// - 设备在但还没读到 → 说清楚在等什么（忙的时候本来就不读，窗口留给传输）；
    /// - 设备真的不在 → 「—」。这时候上次的读数确实不能代表现状。
    private func hardware(_ value: String?) -> String {
        guard working || dev.connected else { return "—" }
        return value ?? idleHint
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
            Text(value).font(DS.bodyFont(DS.T.body, .medium))
                .foregroundStyle(DS.title(scheme == .dark))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.R.md)
            .fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md)
            .stroke(DS.border(scheme == .dark), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }

    /// 归档体检。之前只有菜单栏能进，主窗口够不到——而它回答的正是
    /// 「我攒下来的东西还在不在」，这是设备页最该回答的问题之一。
    private var archive: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本机归档").font(DS.bodyFont(DS.T.title, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
                Spacer()
                Button("体检一次") { model.panel = .audit }
                    .buttonStyle(DSSecondaryButtonStyle())
            }
            if let r = model.auditReport {
                Text(r.problems == 0 ? "\(r.total) 条留档全部完好"
                                     : "\(r.total) 条里 \(r.problems) 条有问题")
                    .font(DS.bodyFont(DS.T.meta))
                    .foregroundStyle(r.problems == 0 ? DS.ok : DS.warn)
                // 这一项正是今天那个 bug 的探针：裸包在、清单没记账。
                if !r.unlistedRawPackets.isEmpty {
                    Text("另有 \(r.unlistedRawPackets.count) 条裸包在磁盘上但清单没记账")
                        .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.warn)
                }
            } else {
                Text("检查每条录音的本地留档还在不在、能不能解出音频。iCloud 没下载完的和真丢了的会分开报。")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.md).fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.border(scheme == .dark), lineWidth: 1))
    }

    /// 删除规则必须写在人看得见的地方。它动的是设备上的原件，删了就没了。
    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("同步与清理").font(DS.bodyFont(DS.T.title, .semibold))
                .foregroundStyle(DS.title(scheme == .dark))
            // 六道闸的实际口径写在 Cleanup.swift 里；这里只说人关心的那几条。
            Text(model.cleanupEnabled
                 ? "同步成功、且已进深脑满 \(model.coolingDays) 天的，才会从录音笔上删。不足 5 分钟的不推给深脑。"
                 : "只导入，不删录音笔上的原件。不足 5 分钟的不推给深脑。")
                .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(get: { model.cleanupEnabled },
                                 set: { model.actions.setCleanup($0) })) {
                Text("同步后清理录音笔").font(DS.bodyFont(DS.T.meta))
            }
            .toggleStyle(.switch).controlSize(.mini).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.md)
            .fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md)
            .stroke(DS.border(scheme == .dark), lineWidth: 1))
    }
}

/// 账号不匹配确认卡（spec 019）。绑定确认 / 不匹配警告共用同一张卡，
/// 因为在 Mac 上唯一会走到需要人手确认这一步的，就是不匹配——首次绑定
/// 不需要打断人（见 Monitor.ensureDeviceBinding 的注释：没绑过就没有
/// "这次跟上次不一致"的风险，直接自动绑给当前账号）。
private struct BindMismatchCard: View {
    let mismatch: BindMismatch
    let scheme: ColorScheme
    let onConfirm: (String) async -> Bool
    let onCancel: () -> Void

    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.warn)
                Text("「\(mismatch.deviceName)」绑定过别的账号")
                    .font(DS.bodyFont(DS.T.title, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
            }
            Text("这支笔上次同步到「\(mismatch.previousEmail)」，现在登录的是「\(mismatch.currentEmail)」。"
                + "同步已经拦下——继续会把接下来的内容放进后者，不会动前面已经同步过的内容。")
                .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("给这支笔起个新名字", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                Button(busy ? "确认中…" : "继续") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { error = "给这支笔起个名字，比如「我的录音笔」"; return }
                    busy = true; error = nil
                    Task {
                        let ok = await onConfirm(n)
                        busy = false
                        if !ok { error = "「\(n)」这个名字已经被绑过了，换一个" }
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(busy)
                Button("取消", action: onCancel).disabled(busy)
            }
            if let error {
                Text(error).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.warn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.md).fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.warn, lineWidth: 1.5))
    }
}
