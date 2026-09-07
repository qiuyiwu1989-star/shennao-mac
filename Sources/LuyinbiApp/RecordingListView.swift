import LuyinbiCore
import SwiftUI

/// 左侧录音列表。
///
/// 待办直接标在条目上（"待认人 3" / "转写失败"），不另开一个待办区块——
/// 工作台形态下列表本来就在眼前，再开一块是重复。
struct RecordingListView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel

    /// 分开数：待认人和失败是两种性质，混成一个数字看不出轻重。
    private var counts: (speakers: Int, failed: Int, stuck: Int) {
        var s = 0, f = 0, k = 0
        for item in model.items {
            switch Triage.classify(item, busyBase: model.busyBase) {
            case .needsSpeaker: s += 1
            case .failed:       f += 1
            case .stuck:        k += 1
            default:            break
            }
        }
        return (s, f, k)
    }

    var body: some View {
        VStack(spacing: 0) {
            let c = counts
            if c.speakers + c.failed + c.stuck > 0 {
                HStack(spacing: 8) {
                    if c.speakers > 0 {
                        Label("待认人 \(c.speakers)", systemImage: "person.2.wave.2")
                            .font(DS.bodyFont(DS.T.meta, .medium)).foregroundStyle(DS.iris)
                    }
                    if c.failed > 0 {
                        Label("失败 \(c.failed)", systemImage: "exclamationmark.triangle")
                            .font(DS.bodyFont(DS.T.meta, .medium)).foregroundStyle(DS.bad)
                    }
                    if c.stuck > 0 {
                        Label("卡住 \(c.stuck)", systemImage: "arrow.triangle.2.circlepath")
                            .font(DS.bodyFont(DS.T.meta, .medium)).foregroundStyle(DS.warn)
                    }
                    Spacer()
                }
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(DS.ink200.opacity(scheme == .dark ? 0.12 : 0.45))
            }

            if model.items.isEmpty {
                EmptyHint(icon: "waveform", title: "还没有录音",
                          detail: "把录音笔开机放在旁边，它一广播就会自动导入")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                row(item).id(item.id)
                                Divider()
                            }
                        }
                    }
                    // 上下键换录音，并把选中的滚进视野。列表有几十条，
                    // 光有焦点环而不跟随滚动，等于按了键却看不见结果。
                    .focusable()
                    .onMoveCommand { dir in
                        guard let next = neighbour(dir) else { return }
                        model.selection = next
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(next, anchor: .center) }
                    }
                }
            }
        }
    }

    /// 一条录音。照妙记的取舍重排：
    ///
    ///   · **缩略块当锚点** —— 一列文字里最先被眼睛抓住的是形状，不是字。
    ///   · **标题当主角** —— 14pt 半粗；时长、时间退到 13pt 灰字的第二行。
    ///     之前标题和时长一样是 11–12pt，谁也不比谁显眼，等于没有层级。
    ///   · **状态只在要人动手时才出现** —— 「已入深脑」这种"一切正常"的话
    ///     每行都挂着，就成了噪声；真正要处理的那两条反而淹没在里面。
    private func row(_ item: RecordingItem) -> some View {
        let kind = Triage.classify(item, busyBase: model.busyBase)
        let selected = model.selection == item.id
        let act = Triage.actionable.contains(kind)
        return HStack(spacing: 10) {
            tile(kind, selected: selected)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if item.starred {
                        Image(systemName: "star.fill").font(.system(size: 10))
                            .foregroundStyle(DS.warn)
                    }
                    Text(item.brainTitle ?? Fmt.dateTitle(item.base))
                        .font(DS.bodyFont(DS.T.title, .semibold))
                        .foregroundStyle(DS.title(scheme == .dark))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Fmt.duration(item.durationSec))
                        .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                    if item.brainTitle != nil {
                        // 标题占了第一行，日期就退到这里来——两个都要，但不平起平坐
                        Text(Fmt.dateTitle(item.base))
                            .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
                            .lineLimit(1)
                    }
                    if act {
                        Text(statusText(item, kind))
                            .font(DS.bodyFont(DS.T.micro, .medium))
                            .foregroundStyle(kind.tone)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(kind.tone.opacity(0.12)))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(rowBackground(selected))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(rowVoiceOver(item)))
        .onTapGesture { model.selection = item.id }
    }

    /// 左边那个块。妙记用的是视频缩略图；我们没有画面，就用波形/状态图标，
    /// 作用一样——给眼睛一个落点，也顺带把"这条什么情况"编码进形状里。
    private func tile(_ kind: Triage.Kind, selected: Bool) -> some View {
        let act = Triage.actionable.contains(kind)
        return RoundedRectangle(cornerRadius: DS.R.base)
            .fill(act ? kind.tone.opacity(0.12)
                      : DS.focusSoft.opacity(scheme == .dark ? 0.14 : 1))
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: act ? kind.icon : "waveform")
                    .font(.system(size: 15))
                    .foregroundStyle(act ? kind.tone : DS.focus)
            )
    }

    private func rowBackground(_ selected: Bool) -> some View {
        ZStack(alignment: .leading) {
            selected ? DS.focusSoft.opacity(scheme == .dark ? 0.16 : 1) : Color.clear
            if selected { Rectangle().fill(DS.focusBright).frame(width: 3) }
        }
    }

    /// 读屏要念的一整句。分散在两行里的日期/时长/状态，念出来必须是连贯的一句话，
    /// 否则听到的是「8月28日 22:41:52」「20:51」「正在处理」三段互不相干的碎片。
    private func rowVoiceOver(_ item: RecordingItem) -> String {
        let kind = Triage.classify(item, busyBase: model.busyBase)
        let name = item.brainTitle ?? Fmt.dateTitle(item.base)
        var parts = [name, "时长 \(Fmt.duration(item.durationSec))", statusText(item, kind)]
        if item.starred { parts.insert("已标星", at: 1) }
        return parts.joined(separator: "，")
    }

    /// 上/下一条。列表已按显示顺序排好，直接取相邻项。
    private func neighbour(_ dir: MoveCommandDirection) -> String? {
        let ids = model.items.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let cur = model.selection, let i = ids.firstIndex(of: cur) else { return ids.first }
        switch dir {
        case .up:   return i > 0 ? ids[i - 1] : ids.first
        case .down: return i < ids.count - 1 ? ids[i + 1] : ids.last
        default:    return nil
        }
    }

    private func statusText(_ item: RecordingItem, _ kind: Triage.Kind) -> String {
        switch kind {
        case .needsSpeaker: return "待认人 \(item.unconfirmedSpeakers)"
        case .failed:       return "转写失败"
        case .stuck:        return "推送卡住"
        case .working:      return "正在处理"
        case .queued:       return "排队等推送"
        case .skipped:      return "太短未推"
        case .pendingDel:   return "等着删除"
        case .liveOnDevice: return "正在录"
        case .onDeviceOnly: return "在录音笔上"
        case .done:         return "已入深脑"
        }
    }
}
