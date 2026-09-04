import Accelerate
import AVFoundation
import Foundation

/// 本地语音活动检测：在把一段录音推给云端转写**之前**，先在本机判断里面到底有没有人说话。
///
/// 为什么需要：这台设备录下的片段有相当一部分是垃圾——装在包里的环境噪音、桌面磕碰、
/// 试录两秒。这些推上去会同时花三份代价：转写费、失败重试（云端返回
/// `INVALID_ASR_TIMELINE`，意思就是"没识别到任何语音段"）、以及污染用户的素材库。
///
/// 为什么不能只看时长：现在唯一的闸是"短于 5 分钟不推"。时长是很粗的信号——
/// 3 分钟的环境噪音照样是垃圾，20 秒的重要交代反而必须留。
///
/// 判据方向刻意**偏保守**：漏掉一段垃圾只是浪费几毛钱，误杀一段真会议是不可接受的
/// （用户不会知道它被吞了，也无从找回）。所以下面每一条"判为噪音"的规则都要求
/// 多个指标同时越线，任何一条指标模棱两可就一律判"像有人说话"。
public enum VoiceActivity {

    // MARK: - 结果

    /// 判定结果。故意做成"可解释"的：`reason` 会直接显示在界面上给人看，
    /// 用户要能一眼看懂为什么这条被拦下来，而不是面对一个黑盒的 false。
    public struct Report: Sendable {
        /// 像不像有人说话。拿不准时恒为 true（见类型注释里的取舍）。
        public let isLikelySpeech: Bool
        /// 一句中文理由，可直接上界面。
        public let reason: String

        /// 音频时长（秒）。
        public let duration: Double
        /// 语音频段（300–3400Hz）能量占比，分母是 0–8kHz 的总能量。
        public let speechBandRatio: Double
        /// 低频（300Hz 以下）能量占比。噪音的主要藏身处。
        public let lowBandRatio: Double
        /// 语音最关键频段（1–3kHz）能量占比。
        public let coreBandRatio: Double
        /// 判为"有语音"的帧占总帧数的比例（有效语音时长占比）。
        public let voicedRatio: Double
        /// 判为"有语音"的帧占**活跃帧**（明显高于本底的帧）的比例。
        /// 判据真正用的是这个而不是上面那个：长录音里静默占大头，
        /// 用全片当分母，一段真会议里的人声会被稀释到和噪音一样低。
        public let activeVoicedRatio: Double
        /// 判为"有语音"的累计秒数。
        public let voicedSeconds: Double
        /// 判为"有语音"的帧数。稳态单音判据要求帧数够多才敢开火，自测要看这个数。
        public let voicedFrameCount: Int
        /// 全片峰值幅度（0–1）。
        public let peak: Double
        /// 全片 RMS。
        public let rms: Double
        /// 峰值因数 peak/rms。
        public let crest: Double
        /// 自适应本底噪声 RMS（帧 RMS 的第 10 百分位）。判"帧是否活跃"的参照系。
        public let noiseFloorRMS: Double
        /// 最长一段连续人声（秒）。零星几帧和一整句话不是一回事。
        public let longestVoicedRun: Double
        /// 人声帧的基频集中度：落在基频中位数 ±3% 以内的帧占比。
        /// 真人说话音高一直在动，这个值实测 7%–33%；空调/马达/蜂鸣这类稳态单音接近 100%。
        public let pitchConcentration: Double

        /// 一行紧凑的指标串，给日志和自测用。
        public var metricsLine: String {
            func p(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }
            return String(format:
                "%7.1fs 低频%@ 语音带%@ 1-3k%@ 人声%@/活跃%@(%6.1fs 最长%4.1fs) 基频集中%@ rms%.5f 峰值因数%6.1f",
                duration, p(lowBandRatio), p(speechBandRatio), p(coreBandRatio),
                p(voicedRatio), p(activeVoicedRatio), voicedSeconds, longestVoicedRun,
                p(pitchConcentration), rms, crest)
        }
    }

    // MARK: - 判据阈值
    //
    // 这些数字是在本机 8 条真实样本（3 条云端转写失败 / 5 条转写成功）上量出来的，
    // 不是拍脑袋。public 而不是 private，是为了自测（独立 target，看不到 internal）
    // 能引用同一份常量——阈值在两处各写一遍迟早会漂。

    /// 单帧算"像人声"的谐波性门槛（归一化自相关峰）。
    ///
    /// 这是整套判据里唯一真正管用的一维。踩过的两条弯路都记在这里，免得后人再走一遍：
    ///   * **频段能量占比不能进判据**。已知失败的那条录音确实是 58.7% 能量在 300Hz 以下、
    ///     1–3kHz 只有 6%，但把这条推广到全部样本就翻车了：一条真人说话、云端转写成功的
    ///     录音是 68.7% 低频、1–3kHz 只有 0.6%——比所有噪音样本还极端。
    ///     两组在能量占比上完全重叠，所以占比只报给人看，不参与判定。
    ///   * **不要先带限再算自相关**（教科书做法）。把宽带噪音削成一条窄带，
    ///     窄带噪声的自相关自己就是振荡的，噪音样本的谐波性被抬到和人声一样高，
    ///     实测两组余量从 2.9 倍掉到 1.2 倍。所以用全频带。
    ///
    /// 0.70 这个值：实测噪音组活跃帧过线率 0.86%/1.18%/0.98%，语音组 3.4%–10.2%。
    public static let voicedHarmonicity: Float = 0.70
    /// "活跃帧"门槛 = 本底噪声的多少倍。3 倍 ≈ 高出本底 9.5dB。
    /// 实测两组余量：2 倍 1.8x、2.5 倍 2.3x、3 倍 2.9x、4 倍 4.1x。
    /// 没有一路调大，是因为调大等于要求说话必须比环境响很多，会漏掉小声说话——
    /// 而漏判的代价（吞掉真会议）比多花的转写费大得多。3 倍是余量和保守性的折中。
    public static let activeGateFactor: Float = 3.0
    /// 但门槛最高不超过帧 RMS 的第 85 百分位。这是给"响度分布很平"的录音留的后门：
    /// 一段响亮的稳态嗡鸣会把本底自己抬上去，3 倍本底比整段都高，于是一帧都不算活跃、
    /// 藏在嗡鸣底下的人说话被整段吞掉。封了顶就至少还有 15% 的帧会被看到。
    /// 取 85 而不是更低，是因为 60/75 会在真实样本上生效并把余量从 2.9 倍削到 1.1 倍——
    /// 后门只该在病态输入上开，不该动正常录音的判据。
    public static let activeGateCeilPercentile = 0.85

    /// 人声帧占活跃帧的比例低于这个值，才有资格被判成垃圾。
    /// 2% 卡在实测两组之间（噪音上限 1.18%，语音下限 3.39%），两边各留约 1.7 倍余量。
    public static let minActiveVoicedRatio = 0.02
    /// 但只要全片攒够这么多秒人声，一律放行——这是给"长录音里只说了几句"留的活口，
    /// 比例判据在那种情况下会被静默稀释。
    public static let minVoicedSeconds = 1.0

    /// 稳态单音判据：人声帧数够多、基频却几乎钉死在一个值上 = 空调/马达/蜂鸣，不是人。
    public static let tonalConcentration = 0.85
    public static let tonalMinFrames = 30
    /// 基频"算同一个音"的相对容差。
    public static let tonalTolerance = 0.03

    /// 绝对静音门槛：RMS 低于这个值，人耳基本听不到东西，转写必然空手而归。
    public static let silenceRMS = 0.0008

    /// 一帧取 1024 点。48kHz 下 ≈ 21ms，语音分析的常规帧长。
    public static let frameSize = 1024
    /// FFT 补零到 2048：一是频率分辨率翻倍（23.4Hz，300Hz 这条边界才卡得准），
    /// 二是自相关必须补零才是线性自相关，不补零的循环自相关在长 lag 上会绕回来假谐波。
    public static let fftSize = 2048

    // MARK: - 逐帧原始指标（自测与调参用）

    /// 扫描结果。逐帧数组按时间顺序排列。一小时约 17 万帧 × 5 个 Float ≈ 3.4MB，
    /// 可以放心留着做第二遍统计——本底噪声要看完全片才知道，单遍做不了。
    public struct Scan {
        public var sampleRate: Double
        public var sampleCount: Int
        public var peak: Float
        public var rms: Double
        /// 每帧 RMS
        public var frameRMS: [Float]
        /// 每帧 300Hz 以下能量占比
        public var low: [Float]
        /// 每帧 300–3400Hz 能量占比
        public var speech: [Float]
        /// 每帧 1–3kHz 能量占比
        public var core: [Float]
        /// 每帧谐波性：归一化自相关在 75–350Hz 基频范围内的峰值。
        /// 人说话（元音）这个值高，宽带噪音/风声/摩擦声这个值低。
        public var harmonicity: [Float]
        /// 每帧自相关峰对应的 lag（采样数）。人说话时基频一直在变，稳态嗡鸣则一动不动。
        public var pitchLag: [Int32]

        public var duration: Double { sampleRate > 0 ? Double(sampleCount) / sampleRate : 0 }
        public var frameSeconds: Double { sampleRate > 0 ? Double(VoiceActivity.frameSize) / sampleRate : 0 }
    }

    // MARK: - 入口

    /// 分析一个本地音频文件。文件读不开或长度为 0 时返回 nil（交给调用方按"拿不准"处理，
    /// 也就是照推不误）。
    ///
    /// 耗时实测（release）：14 分钟的 opus 全流程 0.6 秒，一小时外推约 2.6 秒，
    /// 预算是 15 秒，余量充足。注意 debug 构建慢 6 倍（一小时约 16 秒），
    /// 因为逐帧那个找基频的循环在 debug 下带边界检查——别拿 debug 的数字下结论。
    /// 无论哪种构建都务必放到后台线程，别卡 UI。
    public static func analyze(audio: URL) -> Report? {
        guard let s = scan(audio: audio) else { return nil }
        return report(from: s)
    }

    /// 分块扫描。**绝不能**一次把整个文件读进内存：12 分钟解码后是 146MB 浮点，
    /// 一小时到 700MB，真实录音上会把内存打爆。
    public static func scan(audio: URL) -> Scan? {
        guard let file = try? AVAudioFile(forReading: audio), file.length > 0 else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }

        let chunk = AVAudioFrameCount(max(1, Int(sampleRate)))   // 一次一秒，内存上限固定
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let spectrum = Spectrum(frame: frameSize, fft: fftSize, sampleRate: sampleRate)
        else { return nil }

        var peak: Float = 0
        var sumSquares: Double = 0
        var sampleCount = 0

        var s = Scan(sampleRate: sampleRate, sampleCount: 0, peak: 0, rms: 0,
                     frameRMS: [], low: [], speech: [], core: [], harmonicity: [], pitchLag: [])
        let estFrames = max(16, Int(file.length) / frameSize + 1)
        s.frameRMS.reserveCapacity(estFrames); s.low.reserveCapacity(estFrames)
        s.speech.reserveCapacity(estFrames); s.core.reserveCapacity(estFrames)
        s.harmonicity.reserveCapacity(estFrames); s.pitchLag.reserveCapacity(estFrames)

        // 上一块凑不满一帧的尾巴接到下一块前面：既不丢块边界上的那一帧，
        // 也让分帧结果与 chunk 大小无关（否则换个 chunk 指标就变了）。
        var carry: [Float] = []
        carry.reserveCapacity(frameSize + Int(chunk))

        var lastPosition: AVAudioFramePosition = -1
        while true {
            buf.frameLength = 0
            guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
            // 双保险：读到帧但文件位置没前进，说明解码器卡住了，直接退出。
            // Waveform 那边踩过一次死循环（take 算成 0，j 不前进，整个应用卡死），
            // 这里宁可少算一段也不能把应用挂住。
            guard file.framePosition > lastPosition else { break }
            lastPosition = file.framePosition
            guard let ch = buf.floatChannelData?[0] else { break }
            let n = Int(buf.frameLength)

            // 全片峰值 / RMS 在时域直接累计，与分帧无关，不受尾巴取舍影响。
            var chunkPeak: Float = 0
            vDSP_maxmgv(ch, 1, &chunkPeak, vDSP_Length(n))
            if chunkPeak > peak { peak = chunkPeak }
            var chunkSq: Float = 0
            vDSP_svesq(ch, 1, &chunkSq, vDSP_Length(n))
            sumSquares += Double(chunkSq)
            sampleCount += n

            carry.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))

            // 步长是常量 frameSize，每轮必然前进——这个循环结构上不可能死循环。
            var off = 0
            carry.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                while off + frameSize <= src.count {
                    let f = spectrum.measure(base + off)
                    s.low.append(f.low)
                    s.speech.append(f.speech)
                    s.core.append(f.core)
                    s.harmonicity.append(f.harmonicity)
                    s.pitchLag.append(f.pitchLag)
                    var sq: Float = 0
                    vDSP_svesq(base + off, 1, &sq, vDSP_Length(frameSize))
                    s.frameRMS.append((sq / Float(frameSize)).squareRoot())
                    off += frameSize
                }
            }
            if off > 0 { carry.removeFirst(off) }
        }

        guard sampleCount > 0 else { return nil }
        s.sampleCount = sampleCount
        s.peak = peak
        s.rms = (sumSquares / Double(sampleCount)).squareRoot()
        return s
    }

    // MARK: - 从扫描结果到判定

    public static func report(from s: Scan) -> Report {
        let crest = s.rms > 0 ? Double(s.peak) / s.rms : 0

        // 全片频段占比用**能量加权**：按帧能量加权平均每帧的占比。
        // 直接对帧占比取算术平均是错的——大量近乎静音的帧里频谱是纯噪声的随机数，
        // 会把真正有人说话那几帧的结论稀释掉。
        var wLow = 0.0, wSpeech = 0.0, wCore = 0.0, wSum = 0.0
        for i in s.frameRMS.indices {
            let w = Double(s.frameRMS[i]) * Double(s.frameRMS[i])
            wSum += w
            wLow += Double(s.low[i]) * w
            wSpeech += Double(s.speech[i]) * w
            wCore += Double(s.core[i]) * w
        }
        let lowRatio = wSum > 0 ? wLow / wSum : 0
        let speechRatio = wSum > 0 ? wSpeech / wSum : 0
        let coreRatio = wSum > 0 ? wCore / wSum : 0

        // 本底噪声取帧 RMS 的第 10 百分位：录音里总有停顿，最安静的那一成就是本底。
        // 用最小值太脆（一个丢包帧就是 0），用均值又会被语音本身抬高。
        let noiseFloor = percentile(s.frameRMS, 0.10)

        // "人声帧" = 明显高于本底 **且** 自相关有清晰的基频峰。
        // 只用响度会把磕碰、风声、衣物摩擦全算进来；加上"有没有周期结构"才分得开，
        // 因为噪音是宽带无基频的，冲激更是连一个周期都没有。
        let gate = min(max(noiseFloor * activeGateFactor, Float(silenceRMS) * 0.5),
                       percentile(s.frameRMS, activeGateCeilPercentile))
        var voiced = [Bool](repeating: false, count: s.frameRMS.count)
        var voicedFrames = 0
        var activeFrames = 0
        var voicedLags: [Int32] = []
        for i in s.frameRMS.indices where s.frameRMS[i] > gate {
            activeFrames += 1
            if s.harmonicity[i] >= voicedHarmonicity {
                voiced[i] = true
                voicedFrames += 1
                voicedLags.append(s.pitchLag[i])
            }
        }
        // 最长连续段：允许中间断 2 帧（≈43ms），说话时的爆破音本来就有短暂静默，
        // 一帧不许断会把一句话切碎成十几段。
        var longestRun = 0, run = 0, holes = 0
        for v in voiced {
            if v { run += 1; holes = 0 }
            else if run > 0 && holes < 2 { holes += 1; run += 1 }
            else { longestRun = max(longestRun, run - holes); run = 0; holes = 0 }
        }
        longestRun = max(longestRun, run - holes)

        // 基频集中度：人声帧的基频有多少挤在中位数附近。
        var concentration = 0.0
        var offPitchFrames = voicedFrames
        if !voicedLags.isEmpty {
            let med = Double(voicedLags.sorted()[voicedLags.count / 2])
            let near = voicedLags.filter { abs(Double($0) - med) <= med * tonalTolerance }.count
            concentration = Double(near) / Double(voicedLags.count)
            offPitchFrames = voicedLags.count - near
        }

        let fs = s.frameSeconds
        let voicedRatio = s.frameRMS.isEmpty ? 0 : Double(voicedFrames) / Double(s.frameRMS.count)
        let activeRatio = activeFrames > 0 ? Double(voicedFrames) / Double(activeFrames) : 0
        let voicedSeconds = Double(voicedFrames) * fs
        let longestVoiced = Double(longestRun) * fs

        let (isSpeech, reason) = judge(rms: s.rms, lowRatio: lowRatio, coreRatio: coreRatio,
                                       voicedRatio: voicedRatio, activeVoicedRatio: activeRatio,
                                       voicedSeconds: voicedSeconds, longestVoiced: longestVoiced,
                                       voicedFrames: voicedFrames, concentration: concentration,
                                       offPitchSeconds: Double(offPitchFrames) * fs)

        return Report(isLikelySpeech: isSpeech, reason: reason, duration: s.duration,
                      speechBandRatio: speechRatio, lowBandRatio: lowRatio,
                      coreBandRatio: coreRatio, voicedRatio: voicedRatio,
                      activeVoicedRatio: activeRatio,
                      voicedSeconds: voicedSeconds, voicedFrameCount: voicedFrames,
                      peak: Double(s.peak), rms: s.rms,
                      crest: crest, noiseFloorRMS: Double(noiseFloor),
                      longestVoicedRun: longestVoiced, pitchConcentration: concentration)
    }

    // MARK: - 判据

    /// 只有在证据很硬的时候才判"没人说话"。顺序 = 理由的优先级，先命中先出。
    ///
    /// 每条否决规则都要求**多个**指标同时越线；任何一条单独看着可疑但别的指标正常，
    /// 一律放行。宁可多花几毛钱转写噪音，也不能吞掉一段真会议。
    public static func judge(rms: Double, lowRatio: Double, coreRatio: Double,
                             voicedRatio: Double, activeVoicedRatio: Double,
                             voicedSeconds: Double, longestVoiced: Double,
                             voicedFrames: Int, concentration: Double,
                             offPitchSeconds: Double) -> (Bool, String) {
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        func sec(_ v: Double) -> String { String(format: "%.1f", v) }

        // 1. 基本听不见。这种推上去 100% 是空转写。
        if rms < silenceRMS {
            return (false, "整段几乎无声（RMS \(String(format: "%.5f", rms))），推上去也识别不到语音")
        }
        // 2. 有周期结构，但音高钉死在一个值上，而且刨掉这个单音之后剩不下一秒——
        //    空调、风扇、马达、设备蜂鸣。第三个条件是保命用的：万一嗡鸣底下真藏着人说话，
        //    那些帧的基频跟嗡鸣对不上，会被 offPitchSeconds 捞出来，整段就放行。
        if voicedFrames >= tonalMinFrames && concentration > tonalConcentration
            && offPitchSeconds < minVoicedSeconds {
            return (false, "整段是一个音高不变的嗡鸣（\(pct(concentration)) 的帧基频相同），不是人说话")
        }
        // 3. 活跃的声音里几乎找不出带基频的帧 —— 环境噪音、翻动、磕碰。
        //    两个条件都不达标才判死：比例低但绝对时长够（长录音里说了几句）要放行，
        //    绝对时长短但比例高（十几秒的短交代）也要放行。
        if activeVoicedRatio < minActiveVoicedRatio && voicedSeconds < minVoicedSeconds {
            let shape = lowRatio > 0.45
                ? "能量几乎全压在低频（300Hz 以下占 \(pct(lowRatio))、1–3kHz 只占 \(pct(coreRatio))）"
                : "频谱里找不到人声的基频结构"
            return (false, "全片只有 \(sec(voicedSeconds)) 秒像人声（有声音的部分里才占 \(pct(activeVoicedRatio))），\(shape)")
        }

        // 剩下的一律放行，理由也要说人话——界面上"通过"也需要给个说法。
        return (true, "检测到约 \(sec(voicedSeconds)) 秒人声（占全片 \(pct(voicedRatio))，最长一段 \(sec(longestVoiced)) 秒）")
    }

    // MARK: - 小工具

    /// 第 p 百分位。会排序一份拷贝；帧数量级在十万，排序几十毫秒，可以接受。
    public static func percentile(_ xs: [Float], _ p: Double) -> Float {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }
}

// MARK: - FFT

/// 一个复用的实数 FFT + 自相关器。缓冲区全部在 init 里一次性分配：
/// 每帧都 new 一遍数组的话，十几万帧的分配开销会盖过 FFT 本身。
private final class Spectrum {
    private let frame: Int
    private let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let work: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let mags: UnsafeMutablePointer<Float>
    private let acf: UnsafeMutablePointer<Float>
    /// 每个 lag 的偏置补偿系数，init 里算好（见 measure 里的说明）。
    private let lagNorm: UnsafeMutablePointer<Float>

    // 频段边界对应的 bin 下标，init 里算好。
    private let bLow: Int      // 300Hz
    private let b1k: Int       // 1000Hz
    private let b3k: Int       // 3000Hz
    private let b34k: Int      // 3400Hz
    private let b8k: Int       // 8000Hz。这台设备是 16kHz 宽带 opus，8kHz 以上本来就空白，
                               // 占比的分母只取到 8kHz，免得把编码器的空气算进分母。
    // 基频搜索范围对应的 lag：70Hz（低沉男声）到 350Hz（女声/儿童）。
    private let lagMin: Int
    private let lagMax: Int

    init?(frame: Int, fft n: Int, sampleRate: Double) {
        guard frame >= 64, n >= frame, n & (n - 1) == 0 else { return nil }
        let lg = vDSP_Length(log2(Double(n)).rounded())
        guard let s = vDSP_create_fftsetup(lg, FFTRadix(kFFTRadix2)) else { return nil }
        self.frame = frame
        self.n = n
        self.half = n / 2
        self.log2n = lg
        self.setup = s
        window = UnsafeMutablePointer<Float>.allocate(capacity: frame)
        work = UnsafeMutablePointer<Float>.allocate(capacity: n)
        realp = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        imagp = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        mags = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        acf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        lagNorm = UnsafeMutablePointer<Float>.allocate(capacity: n)
        // 汉宁窗：矩形窗的旁瓣会把强低频能量"漏"到中高频去，
        // 恰好会让低频噪音看起来像有语音——正是我们最不能出的错。
        vDSP_hann_window(window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        // 补零区一次性清零，之后每帧只覆盖前 frame 个点。
        vDSP_vclr(work, 1, vDSP_Length(n))

        func bin(_ f: Double) -> Int { min(n / 2, max(0, Int((f * Double(n) / sampleRate).rounded()))) }
        bLow = bin(300); b1k = bin(1000); b3k = bin(3000)
        b34k = bin(3400); b8k = bin(8000)
        lagMin = max(2, Int(sampleRate / 350))
        // 上限卡在 frame 的 5/8：再往后重叠样本太少，补偿系数会大到把噪声也放大成"谐波"。
        // 代价是基频低于约 75Hz 的极低沉男声测不准——那种情况会判成"没有谐波"，
        // 但判据是保守的（缺少人声证据只是不否决），不会因此误杀。
        lagMax = min(frame * 5 / 8, Int(sampleRate / 70))
        // 加窗后的线性自相关天然随 lag 衰减（重叠样本变少 + 窗本身两头轻），
        // 不补偿的话低基频会被系统性低估。这里用三角偏置的倒数近似补偿。
        for k in 0..<n {
            let overlap = Float(max(1, frame - k)) / Float(frame)
            lagNorm[k] = 1 / overlap
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate(); work.deallocate(); acf.deallocate(); lagNorm.deallocate()
        realp.deallocate(); imagp.deallocate(); mags.deallocate()
    }

    struct Measure {
        var low: Float
        var speech: Float
        var core: Float
        var harmonicity: Float
        /// 自相关峰所在的 lag（采样数）。0 表示没找到。用来识别稳态单音。
        var pitchLag: Int32
    }

    func measure(_ src: UnsafePointer<Float>) -> Measure {
        // 先去直流：解码后常带一点 DC 偏置，不去掉会被算成"300Hz 以下的巨大能量"，
        // 直接把判据带偏。
        var mean: Float = 0
        vDSP_meanv(src, 1, &mean, vDSP_Length(frame))
        var negMean = -mean
        vDSP_vsadd(src, 1, &negMean, work, 1, vDSP_Length(frame))
        vDSP_vmul(work, 1, window, 1, work, 1, vDSP_Length(frame))
        // work 的 [frame, n) 段在 init 时清零过，之后再没写过，保持是零填充。

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        work.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // zrip 打包格式把 Nyquist 塞在 imagp[0] 里。这台设备 24kHz 处恒为 0，
        // 但还是显式清掉，免得换个音源时它混进最低频那个桶。
        imagp[0] = 0
        vDSP_zvmags(&split, 1, mags, 1, vDSP_Length(half))

        func sum(_ a: Int, _ b: Int) -> Float {
            guard b > a else { return 0 }
            var v: Float = 0
            vDSP_sve(mags + a, 1, &v, vDSP_Length(b - a))
            return v
        }
        let low = sum(0, bLow)
        let core = sum(b1k, b3k)
        let speechFull = sum(bLow, b34k)          // 300–3400，含 core
        let high = sum(b34k, b8k)
        let total = low + speechFull + high

        // 谐波性：功率谱的逆变换就是自相关（维纳-辛钦）。已经算了正变换，
        // 再做一次逆变换比直接在时域枚举 550 个 lag 便宜两个数量级。
        // 补零到 2n 保证这是**线性**自相关，不补零的话长 lag 会绕回来变成假谐波峰。
        var h: Float = 0
        var bestLag: Int32 = 0
        realp.update(from: mags, count: half)
        // 这里刻意用**全频带**自相关。试过先带限到 300–3400Hz 再算（教科书做法），
        // 在这批真实样本上反而更差：把宽带噪音削成一条窄带，窄带噪声的自相关本身就是
        // 振荡的，噪音样本的"谐波性"被抬到和真人说话一样高，两组直接糊在一起
        //（实测余量从 2.9 倍掉到 1.2 倍）。所以不带限。
        vDSP_vclr(imagp, 1, vDSP_Length(half))
        var isplit = DSPSplitComplex(realp: realp, imagp: imagp)
        vDSP_fft_zrip(setup, &isplit, 1, log2n, FFTDirection(FFT_INVERSE))
        acf.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ztoc(&isplit, 1, cp, 2, vDSP_Length(half))
        }
        let r0 = acf[0]
        if r0 > 0 && lagMax > lagMin {
            var best: Float = 0
            // 手写循环而不是 vDSP_maxvi：要边比边乘补偿系数，argmax 会因此改变。
            // 500 个 lag × 十几万帧对 CPU 来说微不足道，实测占比在 FFT 之下。
            for k in lagMin..<lagMax {
                let v = acf[k] * lagNorm[k]
                if v > best { best = v; bestLag = Int32(k) }
            }
            h = max(0, min(1, best / r0))
        }

        guard total > 0 else {
            return Measure(low: 0, speech: 0, core: 0, harmonicity: h, pitchLag: bestLag)
        }
        return Measure(low: low / total, speech: speechFull / total,
                       core: core / total, harmonicity: h, pitchLag: bestLag)
    }
}
