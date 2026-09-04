import SwiftUI
import LuyinbiCore

/// 录音页。参考妙记那个录音窗的取舍：屏幕正中只有三样东西——
/// 计时、电平、开始/停止。别的都往后放。
///
/// 这一版**只录不转**（见 MicRecorder 顶部的说明）：录完落在本机，
/// 你决定推给深脑之后才上传、才转写。所以这里不假装有实时字幕，
/// 也不摆一个「正在生成…」的空骨架——那会让人以为在出字，其实什么都没有。
@MainActor
final class RecordStore: ObservableObject {
    @Published var recording = false
    @Published var seconds: Double = 0
    @Published var level: Float = 0
    /// 最近这一小段的电平，用来画那条跳动的柱子。
    @Published var trail: [Float] = []
    @Published var message: String?
    @Published var lastFile: URL?
    @Published var lastSeconds: Double = 0

    private let rec = MicRecorder()

    /// 录到哪里：和录音笔导入的那批放一起，后面的同步/审计逻辑一视同仁。
    private var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目/导入")
    }

    func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        message = nil
        Task {
            guard await MicRecorder.requestPermission() else {
                message = MicRecorder.RecorderError.denied.errorDescription
                return
            }
            rec.onProgress = { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.seconds = p.seconds
                    self.level = p.level
                    self.trail.append(p.level)
                    if self.trail.count > 90 { self.trail.removeFirst(self.trail.count - 90) }
                }
            }
            do {
                _ = try rec.start(directory: directory)
                recording = true
                seconds = 0
                trail = []
                lastFile = nil
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func stop() {
        let done = rec.stop()
        recording = false
        level = 0
        guard let done else { return }
        lastSeconds = done.seconds
        lastFile = done.url
        message = "录完了，正在转成上传格式…"

        // 转码放后台：三小时的录音要转十几秒，卡在主线程会让人以为死了。
        Task.detached(priority: .userInitiated) {
            do {
                let out = try AudioTranscode.toM4A(done.url)
                // 只有**回读确认过**输出可打开（toM4A 内部做了）才删源。
                // 反过来做就是拿唯一的原件赌转码器不出错。
                try? FileManager.default.removeItem(at: done.url)
                await MainActor.run { self.finish(out.url, seconds: out.seconds) }
            } catch {
                await MainActor.run {
                    // 转码失败不是灾难：caf 还在，人还能自己拿去处理。
                    self.lastFile = done.url
                    self.message = "转码失败（\((error as? LocalizedError)?.errorDescription ?? "\(error)")）。"
                        + "原始录音还在，用「在访达里看」拿走。"
                }
            }
        }
    }

    private func finish(_ url: URL, seconds: Double) {
        lastFile = url
        lastSeconds = seconds
        let mb = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
            .flatMap { $0 }?.doubleValue ?? 0
        let size = mb > 0 ? String(format: "%.0f MB", mb / 1024 / 1024) : ""
        // 不足 5 分钟的不推给深脑——这条规矩和录音笔那条是同一条，
        // 在录完当场说清楚，比事后在列表里显示「太短未推」要好。
        message = seconds < 300
            ? "录了 \(Fmt.clock(seconds))\(size.isEmpty ? "" : "（\(size)）")，不足 5 分钟，按规矩不推给深脑。文件已存在本机。"
            : "录了 \(Fmt.clock(seconds))\(size.isEmpty ? "" : "（\(size)）")，已进上传队列，下一轮同步推给深脑。"
    }

}

struct RecordPage: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel
    @StateObject private var store = RecordStore()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(Fmt.clock(store.seconds))
                .font(DS.mono(44))
                .foregroundStyle(DS.title(scheme == .dark))
                .monospacedDigit()
                .accessibilityLabel("已录 \(Fmt.clock(store.seconds))")

            meter.frame(height: 44).padding(.top, 18).padding(.horizontal, 40)

            Button(action: store.toggle) {
                Label(store.recording ? "停止" : "开始录音",
                      systemImage: store.recording ? "stop.fill" : "mic.fill")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .padding(.top, 24)

            if let m = store.message {
                Text(m)
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isStaticText)
            }

            if !store.recording, store.lastFile != nil {
                Button("在访达里看") {
                    if let u = store.lastFile { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .padding(.top, 10)
            }
            Spacer()

            Text("这台 Mac 的麦克风直接录，不经过浏览器那套降噪——开会时远处的人不会被当噪声压掉。")
                .font(DS.bodyFont(DS.T.micro)).foregroundStyle(DS.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 电平柱。不录的时候是一条静止的浅色基线——静止本身就说明「没在收音」。
    private var meter: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(store.trail.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DS.focusBright)
                        .frame(width: 2, height: max(3, CGFloat(v) * geo.size.height))
                }
                if store.trail.isEmpty {
                    Rectangle().fill(DS.glyph.opacity(0.4)).frame(height: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }
}
