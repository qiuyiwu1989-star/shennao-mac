import LuyinbiCore
import SwiftUI

/// 归档体检结果面板。
///
/// 为什么值得有一整个面板：深脑 30 天后会清掉原始音频，之后**本机这份裸包是唯一一份**。
/// 而已经从设备上删掉的那些，连"重导一次"的退路都没有。
/// 这个面板守的是唯一一份，不是锦上添花。
struct ArchiveAuditPanel: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "shield.checkered").foregroundStyle(DS.focusBright)
                Text("本地归档体检").font(DS.heading(14, .semibold)).dsHeading()
                    .foregroundStyle(DS.title(scheme == .dark))
                Spacer()
                Button("重新体检") { model.actions.runAudit() }
                    .buttonStyle(DSSecondaryButtonStyle())
                Button("关闭") { model.panel = nil }
                    .buttonStyle(DSPrimaryButtonStyle())
            }
            .padding(14)
            Divider()

            if let r = model.auditReport {
                HStack(spacing: 10) {
                    Text(r.summary).font(DS.bodyFont(DS.T.title))
                        .foregroundStyle(r.hasProblems ? DS.bad : DS.ok)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(r.items, id: \.base) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.status.isHealthy
                                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.status.isHealthy ? DS.ok : DS.warn)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Fmt.dateTitle(item.base)).font(DS.bodyFont(DS.T.title))
                                        .foregroundStyle(DS.title(scheme == .dark))
                                    Text(item.detail).font(DS.bodyFont(DS.T.meta))
                                        .foregroundStyle(DS.body(scheme == .dark))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(item.status.label).font(DS.bodyFont(DS.T.meta))
                                    .foregroundStyle(item.status.isHealthy ? DS.ink300 : DS.warn)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            } else {
                EmptyHint(icon: "shield", title: "还没体检过",
                          detail: "检查本机归档是不是还在、还能不能解码")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg(scheme == .dark))
        .onAppear { if model.auditReport == nil { model.actions.runAudit() } }
    }
}
