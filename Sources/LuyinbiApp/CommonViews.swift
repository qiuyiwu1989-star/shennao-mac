import SwiftUI

/// 小圆角标签，用来标「已连接 / 录音中 / 失败」这类一眼状态。
struct StatusPill: View {
    @Environment(\.colorScheme) private var scheme
    enum Tone { case ok, warn, bad, idle

        var color: Color {
            switch self {
            // 语义色取自深脑网页端，别用系统默认——两端要看着是同一个产品
            case .ok:   return DS.ok
            case .warn: return DS.warn
            case .bad:  return DS.bad
            case .idle: return DS.ink300
            }
        }
    }

    let text: String
    var tone: Tone = .idle

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.color.opacity(0.15)))
            .overlay(Capsule().stroke(tone.color.opacity(0.35), lineWidth: 1))
    }
}

/// 设备卡里的一格指标：图标 + 标题 + 值（+ 可选的细进度条）
struct MetricView: View {
    let icon: String
    let title: String
    let value: String
    var fraction: Double? = nil
    var fractionTone: Color = DS.focusBright

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
                .monospacedDigit()
            if let fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(.linear)
                    .tint(fractionTone)
                    .frame(width: 96)
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }
}

extension View {
    /// 卡片一律走深脑规格（大圆角 + 细边 + 大而淡的阴影），
    /// 实现在 DesignSystem.swift 的 DSCard，别在这里另起一套。
    func cardStyle() -> some View { dsCard(radius: DS.R.xl, padding: 0) }
}

/// 详情面板里的「标题：值」一行。值可以换行、可以选中复制。
struct FieldRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 空态占位（没设备、没录音、没选中都用它）
struct EmptyHint: View {
    let icon: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
