import Foundation
import AVFoundation

/// 本机麦克风录音。只录，不做实时转写。
///
/// 为什么先做「只录」：录音这件事的第一属性是**不能丢**。实时转写要连网关、
/// 要处理断流重连，每多一条依赖就多一种录到一半没了的方式。先把「按下去就一定录到、
/// 掉电也还在」做扎实，实时转写作为后续增量接上去。
///
/// 与网页端的关键差别（也是这个原生版本存在的理由）：网页端走 `getUserMedia`，
/// 默认带 `echoCancellation` / `noiseSuppression` —— 那是**打电话**用的语音处理，
/// 假设「一个人贴着麦、其余都是噪声」。开会时屋里几个人远近不一，远处的人会被当噪声压掉。
/// 这里直接拿输入节点的原始格式，不做那套处理。
public final class MicRecorder {
    public struct Progress: Sendable {
        public let seconds: Double
        /// 0…1 的瞬时电平，画波形和「有没有在收音」都靠它。
        public let level: Float
    }

    public enum RecorderError: LocalizedError {
        case denied
        case noInput
        case engine(String)

        public var errorDescription: String? {
            switch self {
            case .denied:  return "没有麦克风权限。到「系统设置 → 隐私与安全性 → 麦克风」里打开。"
            case .noInput: return "找不到可用的输入设备"
            case .engine(let m): return "录音引擎起不来：\(m)"
            }
        }
    }

    /// 落盘格式。改这里之前先读上面那段——两个数都不是随手定的。
    public static let storeSampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    /// 麦克风给的（48k float32）→ 落盘的（16k int16）。
    /// AVAudioFile 写入时只转位深、**不做重采样**（实测：设 16k 写出来还是 48k 的大小），
    /// 所以重采样必须自己在这儿做。
    private var converter: AVAudioConverter?
    private var storeFormat: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 48_000
    private let lock = NSLock()

    public private(set) var url: URL?
    public var onProgress: ((Progress) -> Void)?

    public init() {}

    /// 询问权限。第一次会弹系统对话框。
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// 开录。写到 `directory` 下一个带时间戳的 .caf。
    ///
    /// 用 caf 裸 PCM 而不是压缩格式：实测 SIGKILL 一个正在写的进程，
    /// **PCM 救回 638 秒，AAC 读出 0.00 秒**（数据在磁盘上，但帧数索引是关闭时才写的）。
    /// 录音的第一属性是不能丢，所以录制期间不压缩，停下来再转 AAC 上传。
    ///
    /// 格式是 **16 kHz / int16 / 单声道 = 31 KB/s ≈ 110 MB/小时**（三小时 0.32 GB）。
    /// 两个数都是想过的：
    ///   · int16 而不是 float32 —— float32 是**处理**格式，存储从来用 int16。
    ///     直接拿引擎给的 float32 落盘，白白大一倍，人耳和 ASR 都听不出区别。
    ///   · 16k 而不是麦克风原生的 48k —— 服务端 ffmpeg 一律降到 16k（腾讯是 16k 引擎），
    ///     而录音笔本身就是 16 kHz 录的。我们的主力输入早就封顶在这儿，
    ///     Mac 这一路存 48k 只是给少数录音留一个今天没人消费的余量。
    ///     真要提精度，得连服务端那句写死的 `-ar 16000` 一起改，那时再说。
    public func start(directory: URL) throws -> URL {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.denied
        }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        guard let store = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: Self.storeSampleRate,
                                        channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: format, to: store) else {
            throw RecorderError.engine("建不出 \(Int(format.sampleRate))Hz → \(Int(Self.storeSampleRate))Hz 的转换器")
        }
        sampleRate = Self.storeSampleRate      // 时长按**落盘**采样率算，不是麦克风的

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date())
        let target = directory.appendingPathComponent("mac\(stamp).caf")

        let f = try AVAudioFile(forWriting: target, settings: store.settings,
                                commonFormat: .pcmFormatInt16, interleaved: true)

        lock.lock(); converter = conv; storeFormat = store; lock.unlock()
        lock.lock(); file = f; frames = 0; url = target; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.write(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            lock.lock(); file = nil; url = nil; lock.unlock()
            throw RecorderError.engine(error.localizedDescription)
        }
        return target
    }

    private func write(_ buf: AVAudioPCMBuffer) {
        lock.lock()
        let f = file
        let conv = converter
        let store = storeFormat
        lock.unlock()
        guard let f, let conv, let store else { return }

        // 电平在**转换前**量：转换后是 int16，还要换算；而且这里要的是"麦克风收到多大声"。
        var peak: Float = 0
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
        }

        // 重采样后的帧数按比例缩，多给一点余量免得截断
        let ratio = store.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: store, frameCapacity: cap) else { return }

        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0 else { return }

        try? f.write(from: out)
        lock.lock(); frames += AVAudioFramePosition(out.frameLength); let n = frames; lock.unlock()
        onProgress?(Progress(seconds: Double(n) / sampleRate, level: min(1, peak)))
    }

    /// 停止并落盘。    /// 停止并落盘。返回文件与时长；没在录就返回 nil。
    @discardableResult
    public func stop() -> (url: URL, seconds: Double)? {
        guard engine.isRunning || file != nil else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let u = url
        let secs = Double(frames) / sampleRate
        file = nil          // 触发 AVAudioFile 关闭、写完头
        converter = nil; storeFormat = nil
        lock.unlock()
        guard let u else { return nil }
        return (u, secs)
    }

    public var isRecording: Bool { engine.isRunning }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
