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

extension View {
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
