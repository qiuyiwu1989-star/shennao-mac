import AppKit
import LuyinbiCore
import SwiftUI

/// 主窗口：顶部设备条 + 左侧录音列表 + 右侧工作台。
///
/// 划分标准只有一条：**需要音频本身或需要碰设备的，放这里；只需要文本的，去深脑网页。**
/// 所以这里有播放器、波形、逐句转写、说话人指认、设备管理；
/// 没有总结、要点、思维导图、标签、项目空间——那些网页做得更好，两边各做一遍是白费。
struct MainWindowView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel

    private var pendingSpeakers: Int {
        model.items.filter { $0.transcriptId != nil && $0.unconfirmedSpeakers > 0 }.count
    }

    private var selected: RecordingItem? {
        model.items.first { $0.id == model.selection } ?? model.items.first
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
                WorkbenchView(model: model, store: model.speakers,
                              audio: model.audio, item: item)
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
                SideRail(section: $section, pending: pendingSpeakers,
                         deviceConnected: model.device.connected)
                    .frame(width: 132)
                Divider()
                switch section {
                case .library: librarySplit
                case .device:  DevicePage(model: model)
                case .record:  RecordPage(model: model)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .background(DS.bg(scheme == .dark))
    }

    /// 大面板覆盖工作台而不是弹窗：搜索和批量指认都是「要待一会儿」的任务，
    /// 弹窗压着主界面反而碍事，而且弹窗里放不下这么多内容。
    @ViewBuilder
    private func panelView(_ panel: AppModel.Panel) -> some View {
        switch panel {
        case .search:
            SearchView(store: model.search,
                       onPick: { base, secs in model.selectAndPlay(base: base, seconds: secs) },
                       onRebuild: { model.actions.rebuildSearchIndex() })
        case .bulkNaming:
            if let brain = model.brain {
                BulkNamingView(items: model.items.filter {
                                   $0.transcriptId != nil && $0.unconfirmedSpeakers > 0
                               },
                               brain: brain, audio: model.audio,
                               audioFolder: model.importFolder,
                               onClose: { model.panel = nil })
            } else {
                EmptyHint(icon: "person.2.slash", title: "还没接通深脑",
                          detail: "登录之后才能指认说话人")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .audit:
            ArchiveAuditPanel(model: model)
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

            Button {
                model.panel = model.panel == .search ? nil : .search
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.panel == .search ? DS.focusBright : DS.body(scheme == .dark))
            .help("搜索本机录音的转写内容")

            // 有待认人的才显示这个入口——没事的时候不该占位置。
            //
            // 谁当主按钮取决于「此刻有没有事要人做」，不是固定的：
            // 同步是自动的、会自己发生；待认人是**只有人能干**、不认就一直挂着。
            // 把最重的渐变常年给同步，等于每次开窗最亮的那个东西都在说
            // 「点我做一件本来就会自动发生的事」，而真正等人的那件是灰的。
            if pendingSpeakers > 0 {
                Button { model.panel = model.panel == .bulkNaming ? nil : .bulkNaming } label: {
                    Label("认人 \(pendingSpeakers)", systemImage: "person.2.wave.2")
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .help("有 \(pendingSpeakers) 条录音还不知道谁在说话")
            }

            Button { model.actions.syncNow() } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(pendingSpeakers > 0 ? AnyButtonStyleBox(DSSecondaryButtonStyle())
                                             : AnyButtonStyleBox(DSPrimaryButtonStyle()))
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
