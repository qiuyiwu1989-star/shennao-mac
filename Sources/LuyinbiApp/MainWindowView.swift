import AppKit
import LuyinbiCore
import SwiftUI

/// 主窗口：顶部动作条 + 左侧录音清单 + 右侧台账详情。
///
/// spec 012：这个 App 只做一件事——把录音从笔里弄进深脑。
/// **浏览、播放、认人、搜索一律不做**，网页已经做了，原生复刻只会长期落后于它。
/// 所以右侧是台账（走到哪一步、卡住的话卡在哪），不是阅读器。
struct MainWindowView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel


    /// **不回退到 items.first。** 原来「没选中就显示最新一条」会造成
    /// 右侧有内容、左侧无高亮；而且导入新录音时 item.id 变化会触发 reload、
    /// 打断正在播放的那条（2026-09-07 review）。没选就是没选。
    private var selected: RecordingItem? {
        model.items.first { $0.id == model.selection }
    }

    @State private var section: RailSection = .library

    /// 内容区：录音清单 + 工作台。设备和录音各自独占整块右侧。
    private var librarySplit: some View {
        HStack(spacing: 0) {
            // 字号提了一档，208pt 装不下「标题 + 时长 + 日期 + 状态」了。
            // 妙记的清单本来就宽——列表是主角，工作台是它的展开。
            RecordingListView(model: model)
                .frame(width: 292)
            Divider()
            if let panel = model.panel {
                panelView(panel)
            } else if let item = selected {
                RecordingDetailView(model: model, item: item)
            } else {
                EmptyHint(icon: "waveform", title: "还没有录音",
                          detail: "把录音笔开机放在旁边，它一广播就会自动导入")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceBar
            // 「为什么卡住」必须和「卡住了」摆在一起。
            // 2026-09-07：登录失效那次，每条录音都显示「推送卡住」，而原因
            // （连不上深脑）只写在同步日志里——症状铺满屏幕，病因一个字都看不见，
            // 于是只能一条条猜。这条横幅就是把病因搬到症状旁边。
            if let blocked = model.uploadBlocked { blockedBanner(blocked) }
            Divider()
            HStack(spacing: 0) {
                SideRail(section: $section,
                         deviceConnected: model.device.connected || model.isBusy)
                    .frame(width: 132)
                Divider()
                switch section {
                case .library: librarySplit
                case .device:
                    DevicePage(model: model, onOpen: { base in
                        model.selection = base
                        section = .library
                    })
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .background(DS.bg(scheme == .dark))
    }

    /// 归档体检还是要盖住右侧——它是「要待一会儿」的任务，弹窗放不下。
    @ViewBuilder
    private func panelView(_ panel: AppModel.Panel) -> some View {
        switch panel {
        case .audit: ArchiveAuditPanel(model: model)
        }
    }

    /// 整条推送链停摆时的横幅。给原因，也给出口——只说"卡住了"等于没说。
    private func blockedBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warn)
            Text(text).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.title(scheme == .dark))
            Spacer(minLength: 8)
            Button("查看日志") { model.actions.openLog() }
                .buttonStyle(DSSecondaryButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(DS.warn.opacity(0.12))
    }

    /// 设备压成一行。电量、固件、增益基本不变，不该占三分之一屏。
    private var deviceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.focusBright)
            Text("深脑").font(DS.heading(15, .bold)).dsHeading()
                .foregroundStyle(DS.title(scheme == .dark))

            Spacer(minLength: 12)

            if model.isBusy {
                ProgressView().controlSize(.small)
                Text(model.phase.label).font(DS.bodyFont(DS.T.meta))
                    .foregroundStyle(DS.body(scheme == .dark)).lineLimit(1)
            }

            // 设备状态（连接/电量/固件/容量）已经搬到「设备」页，这里不再重复。
            // 顶栏是**动作**区；把硬件读数塞进来，会挤掉当前这条录音真正要做的事，
            // 而且它跟你此刻在看的内容毫无关系。左侧「设备」旁边那个点就够报警了。
            //
            // 只留一个例外：正在录音。这是**现在正在发生**的事，
            // 错过它的代价是录漏一场会，值得越过分区规矩喊一声。
            if model.device.connected, model.device.recordStatus == 1 {
                StatusPill(text: "正在录音", tone: .warn)
            }



            Button { model.actions.syncNow() } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(model.isBusy)
            .help(model.isBusy ? "正在同步中" : "立刻扫一次录音笔并导入新录音")

            // 跳到当前这条录音在深脑里的页面，不是首页。
            // 跳首页等于把人扔回大厅，还得自己再找一遍——那这个按钮就白给了。
            Button {
                if let item = selected, item.transcriptId != nil {
                    model.actions.openBrainSession(item)
                } else {
                    model.actions.openBrainHome()
                }
            } label: {
                Label(selected?.transcriptId != nil ? "在深脑打开" : "打开深脑",
                      systemImage: "arrow.up.forward")
            }
            .buttonStyle(DSSecondaryButtonStyle())

            // 账号入口只在菜单栏图标里，2026-09-07 真实反馈：菜单栏图标一多
            // 就被系统挤到看不见的地方（没有任何"还有更多"的提示），
            // 退出登录/重新登录这种偶尔才用一次但用的时候很急的动作，
            // 不能只有一条路能到——这里放一份完全一样的入口，不依赖菜单栏
            // 有没有空间显示图标。
            if let mail = model.signedInEmail {
                Menu {
                    Button("退出登录") {
                        let a = NSAlert()
                        a.messageText = "退出登录？"
                        a.informativeText = "本机已导入的录音不会受影响，但在重新登录之前不能再推给深脑。"
                        a.addButton(withTitle: "退出登录")
                        a.addButton(withTitle: "取消")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        if a.runModal() == .alertFirstButtonReturn { model.actions.signOut() }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("已登录：\(mail)　点开可退出登录")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
