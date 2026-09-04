import SwiftUI
import LuyinbiCore

/// 左侧三个入口。
///
/// 之前一个窗口里挤着三件不相干的事：同步来的内容、录音笔的状态、以及要新录的音。
/// 它们被硬塞进同一套「列表 + 工作台」里——录音笔的电量和容量只好挤在顶栏，
/// 而顶栏本该放当前这条录音的动作。结果是每一处都在替另一处让位。
///
/// 拆成三块之后，每块只回答一个问题：
///   · 内容 —— 我攒下了什么
///   · 设备 —— 录音笔现在什么状况
///   · 录音 —— 现在开录
enum RailSection: String, CaseIterable, Identifiable {
    case library, device, record
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "内容"
        case .device:  return "设备"
        case .record:  return "录音"
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.stack"
        case .device:  return "dot.radiowaves.left.and.right"
        case .record:  return "mic"
        }
    }
}

struct SideRail: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var section: RailSection
    /// 待认人条数。有事要做才亮，没事不打扰。
    let pending: Int
    /// 设备连着没有。红点比一行字更早被看见。
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
        case .library where pending > 0:
            Text("\(pending)")
                .font(DS.bodyFont(DS.T.micro, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(DS.focus))
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
        case .library: return pending > 0 ? "内容，\(pending) 条待认人" : "内容"
        case .device:  return deviceConnected ? "设备，录音笔已连接" : "设备，录音笔未连接"
        case .record:  return "录音"
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

    /// 设备里还没导进来的条数。这是设备页真正要回答的问题。
    private var pendingImport: Int {
        model.items.filter { $0.deviceSize != nil && $0.localBytes == nil }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let m = model.pendingBindMismatch { bindMismatchCard(m) }
                header
                grid
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: dev.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                .font(.system(size: 20))
                .foregroundStyle(dev.connected ? DS.focus : DS.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name).font(DS.bodyFont(DS.T.head, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))
                Text(dev.connected ? "已连接" : "未连接——录音笔开机后会自动广播，这里就会亮")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
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
            // 断开之后电量是上次同步的读数，不是现状——所以断开时不摆数字。
            stat("电量", dev.connected ? battery : "—")
            stat("容量", capacity)
            stat("固件", dev.connected ? (dev.firmware ?? "—") : "—")
            stat("等着导入", pendingImport == 0 ? "都导完了" : "\(pendingImport) 条")
        }
    }

    private var battery: String {
        guard let b = dev.battery else { return "—" }
        return b == 110 ? "充电中" : "\(b)%"
    }

    private var capacity: String {
        guard dev.connected, let remain = dev.capacityRemain, let total = dev.capacityTotal,
              total > 0 else { return "—" }
        return "剩 \(remain / 1024 / 1024)M / 共 \(total / 1024 / 1024)M"
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
