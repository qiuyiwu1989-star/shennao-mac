import AVFoundation
import Foundation

/// 波形包络。
///
/// 分块读而不是一次读进内存：12 分钟的文件解码后是 146MB 浮点，
/// 一小时的会到 700MB——直接读整个文件在真实录音上会把内存打爆。
///
/// 算完缓存到磁盘，同一个文件只算一次。切换录音时如果每次重算，界面会一顿一顿的。
public enum Waveform {
    public static let barCount = 160

    public static func cacheURL(for base: String, root: URL) -> URL {
        root.appendingPathComponent("out/waveform/\(base).json")
    }

    public static func cached(base: String, root: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: cacheURL(for: base, root: root)),
              let arr = try? JSONDecoder().decode([Float].self, from: data),
              arr.count == barCount else { return nil }
        return arr
    }

    /// 算包络。耗时几百毫秒，务必放到后台线程。
    public static func compute(audio: URL, bars: Int = barCount) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: audio), file.length > 0 else { return nil }
        let total = file.length
        let chunk: AVAudioFrameCount = 48_000            // 一次一秒，内存上限固定
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: chunk) else { return nil }

        var peaks = [Float](repeating: 0, count: bars)
        // 每根柱子覆盖多少采样，用计数器推进。
        // 实测：耗时的大头是 Opus 解码本身（12 分钟约 3.3 秒），不是这个循环——
        // 改成计数器几乎没有变化。所以真正的解法不是抠这里，而是**在导入时就把波形算好**
        // （见 Monitor 的导入路径），等用户点开时直接命中缓存。
        let samplesPerBar = max(1, Int(total) / bars)
        var bar = 0
        var inBar = 0
        while true {
            buf.frameLength = 0
            guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
            guard let ch = buf.floatChannelData?[0] else { break }
            let n = Int(buf.frameLength)
            var j = 0
            while j < n {
                // 最后一根柱子要吃掉所有剩余采样。否则 inBar 到顶后 room=0、take=0，
                // j 再也不前进——死循环，界面上表现为整个应用卡死。
                let room = (bar == bars - 1) ? (n - j) : (samplesPerBar - inBar)
                let take = min(room, n - j)
                var m: Float = peaks[bar]
                for k in j..<(j + take) {
                    let v = abs(ch[k])
                    if v > m { m = v }
                }
                peaks[bar] = m
                j += take
                inBar += take
                if inBar >= samplesPerBar && bar < bars - 1 { bar += 1; inBar = 0 }
            }
        }
        // 归一化：录音普遍偏小，不归一化画出来是一条平线
        let maxV = peaks.max() ?? 0
        guard maxV > 0.0001 else { return peaks }
        return peaks.map { $0 / maxV }
    }

    /// 取缓存，没有就算并写缓存。
    public static func load(base: String, audio: URL, root: URL) -> [Float]? {
        if let c = cached(base: base, root: root) { return c }
        guard let peaks = compute(audio: audio) else { return nil }
        let url = cacheURL(for: base, root: root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(peaks).write(to: url, options: .atomic)
        return peaks
    }
}
