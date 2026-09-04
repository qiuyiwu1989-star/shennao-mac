import AVFoundation
import Foundation
import SwiftUI

/// 本地试听。
///
/// 为什么要有：失败提示里写着「可以先试听本地文件确认录到了什么」——
/// 没有播放入口，那句话就是空话。而且判断一条录音到底是设备没录到、还是转写没识别出来，
/// 只有耳朵能定，界面上再多状态也代替不了。
///
/// 直接用 AVAudioPlayer 播 Ogg/Opus（实测能开：CoreAudio 认这个容器），
/// 不用把文件丢给外部播放器——系统默认播放器多半不认 .ogg。
@MainActor
final class AudioPreview: NSObject, ObservableObject {
    @Published private(set) var playingBase: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// startAt 用于「跳到这个说话人开口的那一秒」——指认说话人时听一句就知道是谁，
    /// 从头听一段十几分钟的录音是没法用的。
    func toggle(base: String, url: URL, startAt: Double? = nil) {
        if playingBase == base && startAt == nil { stop(); return }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            if let startAt, startAt > 0, startAt < p.duration { p.currentTime = startAt }
            guard p.play() else { lastError = "播放器启动失败"; return }
            player = p
            playingBase = base
            lastError = nil
            ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.player, p.duration > 0 else { return }
                    self.progress = p.currentTime / p.duration
                }
            }
        } catch {
            lastError = "打不开这个音频：\(error.localizedDescription)"
        }
    }

    /// 前后跳。听录音时漏了一句想重听是最高频的操作，
    /// 只有播放/停止的播放器等于逼人从头再来。
    func skip(_ seconds: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(0, p.currentTime + seconds), p.duration - 0.05)
        progress = p.duration > 0 ? p.currentTime / p.duration : 0
    }

    /// 当前播放位置（秒）。界面上要显示精确时间。
    var currentSeconds: Double { player?.currentTime ?? 0 }

    func stop() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        playingBase = nil
        progress = 0
    }
}

extension AudioPreview: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
