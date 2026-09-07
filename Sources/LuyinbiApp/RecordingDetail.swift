import AppKit
import LuyinbiCore
import SwiftUI

/// 一条录音的详情——**台账，不是阅读器**（spec 012）。
///
/// 它取代了原来的 Workbench（波形 + 逐句转写 + 说话人指认，577 行）。
/// 判据是 spec 012 定的那条：Mac 端唯一做得比别处好的事，是它插着电、
/// 开着蓝牙、就摆在录音笔旁边；「读内容」网页早就做了，原生复刻只会长期落后。
/// 所以这里只回答一个问题：**这条录音走到哪一步了，卡住的话卡在哪。**
///
/// 里面那条链路（设备→本地→深脑→转写→分析）用的是 `ChainView(verbose: true)`——
/// 那份带逐段说明的渲染早就写好了，但唯一的调用点没传 verbose，
/// 所以在 2026-09-07 的 review 之前它是**不可达代码**：五个阶段的原因文案
/// 全都算好了，一个字也没显示出来。用户看到列表里「推送卡住」，
/// 点进来还是五个图标，没有任何一句话说明为什么。现在它是这一页的主体。
struct RecordingDetailView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel
    let item: RecordingItem

    private var status: ChainStatus {
        ChainStatus(item: item, activity: model.activity(for: item))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                chain
                if item.skippedShortSeconds != nil { shortNote }
                actions
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.brainTitle ?? Fmt.title(base: item.base))
                .font(DS.bodyFont(DS.T.head, .semibold))
                .foregroundStyle(DS.title(scheme == .dark))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Fmt.duration(item.durationSec))　\(Fmt.dateTitle(item.base))")
                .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var chain: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("走到哪了").font(DS.bodyFont(DS.T.title, .semibold))
                .foregroundStyle(DS.title(scheme == .dark))
            ChainView(status: status, verbose: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.md).fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.border(scheme == .dark), lineWidth: 1))
    }

    /// 「太短所以没推」不是故障，是省钱的默认规则——必须和「卡住」区分开，
    /// 而且要就地给出手动推的出口。`pushNow` 早就接好了却一个调用点都没有，
    /// 于是 Triage 里那句「需要的话可以手动推给深脑」是句空话（2026-09-07 review）。
    private var shortNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("只有 \(Fmt.duration(Int(item.skippedShortSeconds ?? 0)))，短于门槛，只落盘没推深脑")
                .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                .fixedSize(horizontal: false, vertical: true)
            Button("还是推给深脑") { model.actions.pushNow(item) }
                .buttonStyle(DSSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.R.md).fill(DS.surface(scheme == .dark)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.border(scheme == .dark), lineWidth: 1))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.actions.openBrainSession(item)
            } label: {
                Label(item.transcriptId != nil ? "在深脑打开" : "打开深脑",
                      systemImage: "arrow.up.forward")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .help(item.transcriptId != nil
                  ? "去深脑看这条的转写、说话人和洞察"
                  : "这条还没转写完，先去深脑首页")

            if item.onDisk {
                Button("在访达里显示") { model.actions.revealLocal(item) }
                    .buttonStyle(DSSecondaryButtonStyle())
            }

            // 下载连续失败到阈值之后，引擎就不再自动重试了（否则一条结构性
            // 坏掉的条目会永远占用每一轮的连接时间——实测一条 9 天试了 97 次）。
            // 但「不再自动」必须配一个「手动能再来」，否则那条录音对引擎
            // 就是永久不可见了。这个按钮同时清导入记录和失败计数。
            if item.onDevice {
                Button("重新下载") { model.actions.redownload(item) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .help("清掉这条的下载记录与失败计数，下次连上录音笔重新拉一遍")
            }

            // 转写失败的才给重推。永久失败（比如 INVALID_ASR_TIMELINE）重推一百次
            // 结果都一样，那种不给按钮——给了等于骗人白等（BrainFailure.retryable）。
            if item.brainStatus == "failed", BrainFailure.retryable(item.brainErrorCode) {
                Button("重新推送") { model.actions.repush(item) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .help("换一个幂等键重新建会话推一遍")
            }

            Button(item.starred ? "取消收藏" : "收藏") { model.actions.toggleStar(item) }
                .buttonStyle(DSSecondaryButtonStyle())

            Spacer()

            // 从设备删除**必须先讲清后果**：deleteImpact 就是为这个建的，
            // 而原来 Workbench 里那个入口直接就删了、零确认（2026-09-07 review）。
            // 深脑 30 天后清原始音频，这一击可能销毁最后一份副本。
            if item.onDevice {
                Button("从设备删除") { confirmDeviceDelete() }
                    .buttonStyle(DSSecondaryButtonStyle())
            }
        }
    }

    private func confirmDeviceDelete() {
        let a = NSAlert()
        a.messageText = "从录音笔上删掉这条？"
        a.informativeText = model.actions.deleteImpact(item)
        a.alertStyle = .warning
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { model.actions.deleteFromDevice(item) }
    }
}
