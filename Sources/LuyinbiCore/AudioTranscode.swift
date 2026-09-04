import Foundation
import AVFoundation

/// 把录音的 caf 裸 PCM 转成 m4a（AAC），用于上传。
///
/// 为什么是两个文件而不是直接录成 m4a：
/// 录制过程要的是**掉电也不丢**，AAC 编码器中途被杀会留下读不出来的残件，
/// 而 caf 里的裸 PCM 录到哪秒、那秒之前就一定还在（见 MicRecorder）。
/// 上传要的是**小**：16k 单声道 int16 是 110 MB/小时，AAC 只要 23 MB。
/// （实测：3 小时录音 0.32 GB → 69 MB）
/// 两个诉求打架，那就分两步——录完再转。
///
/// 为什么不转 Opus：macOS 没有原生 Opus 编码器（AudioToolbox 只解不编），
/// 引一个 libopus 进来只为了迎合 `.ogg` 这个后缀不值得——
/// 服务端本来就会用 ffmpeg 归一化成 `-ac 1 -ar 16000 -c:a aac`，
/// 而 `audio/mp4` 就在录音链路的白名单里（`lib/recording/service.ts:25`）。
///
/// 采样率**不在本地降**。服务端那边会降到 16k（腾讯引擎是 16k 引擎），
/// 但那是它的事；本地留着原始采样率，将来换更好的引擎不必重录。
public enum AudioTranscode {
    public enum TranscodeError: LocalizedError {
        case unreadable(String)
        case emptyOutput

        public var errorDescription: String? {
            switch self {
            case .unreadable(let m): return "读不了源文件：\(m)"
            case .emptyOutput:       return "转码输出是空的"
            }
        }
    }

    /// caf → m4a。返回输出文件与时长（秒）。
    ///
    /// 不删源文件：删不删由调用方在**确认输出可读**之后决定。
    /// 转码器报成功但输出打不开是真实发生过的事，这里不替调用方赌。
    /// 码率梯。**AAC 的合法码率取决于采样率**，不是随便填一个数就行：
    /// 16 kHz 单声道的上限实测是 48 kbps，填 64 kbps 会在
    /// `AudioConverterSetProperty(kAudioConverterEncodeBitRate)` 上直接抛错，
    /// 而且错误里只有一个数字码，看不出是码率的问题。
    ///
    /// 与其为每个采样率查一张表，不如从高往低试——第一个成立的就用。
    /// 这样将来改采样率也不会再被这一条绊住。
    private static let bitrateLadder = [64_000, 48_000, 32_000, 24_000, 16_000]

    /// caf → m4a。返回输出文件与时长（秒）。
    ///
    /// 不删源文件：删不删由调用方在**确认输出可读**之后决定。
    /// 转码器报成功但输出打不开是真实发生过的事，这里不替调用方赌。
    @discardableResult
    public static func toM4A(_ source: URL, bitrate: Int? = nil) throws -> (url: URL, seconds: Double) {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) }
        catch { throw TranscodeError.unreadable(error.localizedDescription) }

        let format = input.processingFormat
        let total = input.length
        guard total > 0 else { throw TranscodeError.emptyOutput }

        let target = source.deletingPathExtension().appendingPathExtension("m4a")
        let candidates = bitrate.map { [$0] + bitrateLadder } ?? bitrateLadder
        var lastError: Error?

        for br in candidates {
            try? FileManager.default.removeItem(at: target)
            input.framePosition = 0
            do {
                // 写入必须收在自己的作用域里：m4a 的 moov 原子是 AVAudioFile **析构时**才写的，
                // 句柄还活着就去回读，拿到的是一个没有索引的半截文件——打不开。
                // 这不是假设，是这段代码第一版实测撞到的：转码明明成功、301KB 好端端躺在那儿，
                // 回读却报空，于是把好文件当失败扔了。
                try {
                    let output = try AVAudioFile(forWriting: target, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: br,
                    ])
                    // 分块读写，别把三小时录音整个读进内存。
                    let chunk: AVAudioFrameCount = 32_768
                    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                        throw TranscodeError.unreadable("建不出读缓冲")
                    }
                    while input.framePosition < total {
                        try input.read(into: buf, frameCount: chunk)
                        if buf.frameLength == 0 { break }
                        try output.write(from: buf)
                    }
                }()
            } catch {
                lastError = error
                continue                    // 这个码率这个采样率不支持，降一档再来
            }

            // 现在句柄已经析构，文件完整了，再回读确认真能打开。
            guard let check = try? AVAudioFile(forReading: target), check.length > 0 else {
                lastError = TranscodeError.emptyOutput
                continue
            }
            return (target, Double(total) / format.sampleRate)
        }

        try? FileManager.default.removeItem(at: target)
        throw lastError ?? TranscodeError.emptyOutput
    }

    /// 读一个音频文件的时长。ogg 走不通时返回 nil（AVFoundation 不认 ogg/opus）。
    public static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
