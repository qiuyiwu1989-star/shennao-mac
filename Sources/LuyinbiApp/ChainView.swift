import SwiftUI
import LuyinbiCore

/// 链路上一站的状态。设备 / 本地 / 深脑三段共用。
enum LinkState: Equatable {
    case done       // 东西已经在这一站了
    case active     // 正在往这一站搬
    case pending    // 还没到
    case failed     // 这一站出错了
    case skipped    // 主动不要了（例：同步完把设备上那份清掉了）

    var symbol: String {
        switch self {
        case .done:    return "checkmark.circle.fill"
        case .active:  return "arrow.down.circle.fill"
        case .pending: return "circle.dotted"
        case .failed:  return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle"
        }
    }

    /// 一律用系统语义色，跟随浅色/深色外观，不写死任何色值。
    var tint: Color {
        switch self {
        case .done:    return .green
        case .active:  return DS.focusBright
        case .pending: return .secondary
        case .failed:  return .red
        case .skipped: return .secondary
        }
    }

    var isDim: Bool { self == .pending || self == .skipped }
}

/// 把一条录音换算成三段链路状态 + 每段的一句说明。
/// 表格行画简版（只要 state），详情面板画全版（还要 note）。
struct ChainStatus {
    let device: LinkState
    let disk: LinkState
    let brain: LinkState
    let transcript: LinkState
    let analysis: LinkState
    let deviceNote: String
    let diskNote: String
    let brainNote: String
    let transcriptNote: String
    let analysisNote: String

    init(item: RecordingItem, activity: (label: String, fraction: Double?)?) {
        let downloading = activity?.label.hasPrefix("下载") ?? false
        let uploading = activity?.label.hasPrefix("推送") ?? false

        // 设备段
        if item.onDevice {
            device = .done
            deviceNote = Fmt.bytes(item.deviceSize)
        } else if item.onDisk {
            device = .skipped
            deviceNote = "设备上已不在（已清理）"
        } else {
            device = .pending
            deviceNote = "设备上没有"
        }

        // 本地段
        if item.onDisk {
            disk = .done
            diskNote = Fmt.bytes(item.localBytes)
        } else if downloading {
            disk = .active
            diskNote = activity?.label ?? "下载中"
        } else {
            disk = .pending
            diskNote = "尚未落盘"
        }

        // 深脑段
        if item.inBrain {
            brain = .done
            brainNote = "已就绪，转写完成"
        } else if item.brainStatus == "failed" || (item.lastError != nil && item.sessionId != nil) {
            brain = .failed
            brainNote = item.lastError ?? "推送失败"
        } else if uploading {
            brain = .active
            brainNote = activity?.label ?? "推送中"
        } else if item.sessionId != nil {
            brain = .active
            brainNote = Fmt.brainStatus(item.brainStatus)
        } else {
            brain = .pending
            brainNote = "尚未推送"
        }

        // 转写段。深脑收到不等于转写好了——这两段以前挤在「深脑」一格里，
        // 于是「推上去了但还没转写」和「转写完了」长得一样，
        // 而「卡住」十有八九就卡在这两段之间。
        if item.transcriptId != nil {
            transcript = .done
            transcriptNote = "转写就绪"
        } else if item.brainStatus == "failed" {
            transcript = .failed
            transcriptNote = item.lastError ?? "转写失败"
        } else if item.sessionId != nil {
            transcript = .active
            transcriptNote = "深脑正在转写"
        } else {
            transcript = .pending
            transcriptNote = "等推送"
        }

        // 分析段。有标题就是分析跑完了——深脑起标题是分析的产物，
        // 还是文件名就说明判断还没沉下去。
        if item.brainTitle != nil {
            analysis = .done
            analysisNote = "判断已沉进大脑"
        } else if item.transcriptId != nil {
            analysis = .active
            analysisNote = "分析进行中"
        } else {
            analysis = .pending
            analysisNote = "等转写"
        }
    }
}

/// 链路上的一格：小圆标 + 站名
struct LinkChip: View {
    let title: String
    let state: LinkState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .imageScale(.small)
                .foregroundStyle(state.tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(state.isDim ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(DS.ink300.opacity(state.isDim ? 0.3 : 0.55))
        )
        .accessibilityElement(children: .combine)
    }
}

/// 一条录音的整条链：[设备] → [本地] → [深脑] → [转写] → [分析]
///
/// 为什么值得占这块地方：「还有内容卡住吗」这个问题，以前只能靠 ssh 上服务器查数据库。
/// 一条录音可能停在五个不同的地方，而界面上它们长得一模一样——
/// 2026-08-30 那天问了三次，每次都要查半天才答得上来。
struct ChainView: View {
    let status: ChainStatus
    /// 展开时每一站带一句说明。列表行里不需要，工作台里需要。
    var verbose = false

    var body: some View {
        if verbose {
            VStack(alignment: .leading, spacing: 6) {
                row("设备", status.device, status.deviceNote)
                row("本地", status.disk, status.diskNote)
                row("深脑", status.brain, status.brainNote)
                row("转写", status.transcript, status.transcriptNote)
                row("分析", status.analysis, status.analysisNote)
            }
        } else {
            HStack(spacing: 4) {
                LinkChip(title: "设备", state: status.device)
                ChainArrow()
                LinkChip(title: "本地", state: status.disk)
                ChainArrow()
                LinkChip(title: "深脑", state: status.brain)
                ChainArrow()
                LinkChip(title: "转写", state: status.transcript)
                ChainArrow()
                LinkChip(title: "分析", state: status.analysis)
            }
            .fixedSize()
        }
    }

    private func row(_ title: String, _ st: LinkState, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: st.symbol).imageScale(.small)
                .foregroundStyle(st.tint).frame(width: 16)
            Text(title).font(DS.bodyFont(DS.T.meta, .medium))
                .frame(width: 34, alignment: .leading)
            Text(note).font(DS.bodyFont(DS.T.meta))
                .foregroundStyle(st.isDim ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(note)")
    }
}

private struct ChainArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
    }
}
