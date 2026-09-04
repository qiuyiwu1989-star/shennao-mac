import AVFoundation
import Foundation
import LuyinbiCore

// 语音活动检测的离线自测。纯命令行工具链没有 XCTest，所以跑成可执行目标：失败即非零退出。
//
// 三段，重要性递增：
//   1. 合成信号 —— 判据方向对不对（静音 / 稳态嗡鸣 / 宽带噪声 / 音高会动的类语音）；
//   2. 健壮性   —— 文件不存在、不是音频、空文件、不足一帧都不能崩也不能卡死；
//   3. 真实样本 —— 本机 导入/ 下 8 条已知云端转写结果的录音。
//                 这是唯一能证明判据在真实设备上管用的证据，也是唯一有资格定阈值的依据。
//                 样本缺失时优雅跳过，不算失败。

var passed = 0, failed = 0, skipped = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)\(detail.isEmpty ? "" : "\n        \(detail)")") }
}

func skip(_ name: String, _ why: String) {
    skipped += 1
    print("  SKIP  \(name)  (\(why))")
}

// MARK: - 定位项目根目录
//
// 从源码路径倒推，而不是靠 cwd：swift run 的工作目录取决于在哪敲的命令，
// 靠 cwd 会在别的机器上莫名其妙地"样本不存在"、于是整组测试静默跳过——
// 那比测试失败更糟糕，因为看起来是绿的。

let projectRoot: URL = {
    // .../录音项目/mac-app/Sources/VoiceSelfTest/main.swift → 上溯 4 层
    var u = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { u = u.deletingLastPathComponent() }
    return u
}()
let sampleDir = projectRoot.appendingPathComponent("导入")

// MARK: - 1. 合成信号

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("voice-selftest-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

/// 合成一段 mono 48kHz 的 wav。写盘而不是喂内存数组：要把 AVAudioFile 的分块读取路径
/// 也一起测到。
func synth(_ name: String, seconds: Double, _ gen: (Double) -> Float) -> URL? {
    let sr = 48000.0
    let url = tmp.appendingPathComponent("\(name).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sr,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return nil }
    let total = Int(sr * seconds)
    let chunk = 48000
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(chunk)) else { return nil }
    var i = 0
    while i < total {
        let n = min(chunk, total - i)
        buf.frameLength = AVAudioFrameCount(n)
        guard let ch = buf.floatChannelData?[0] else { return nil }
        for k in 0..<n { ch[k] = gen(Double(i + k) / sr) }
        guard (try? file.write(from: buf)) != nil else { return nil }
        i += n
    }
    return url
}

/// 类语音：基频在 160–240Hz 之间来回滑（相位积分保证连续），带 800/1600/2400Hz 共振峰，
/// 并且有停顿。**音高必须会动**——音高钉死的谐波复合音是嗡鸣不是人声，判据正是靠这一点
/// 区分二者；拿定频信号当"类语音"来测，测的其实是错的东西。
func voiceLike(_ t: Double, level: Double) -> Float {
    let gate = t.truncatingRemainder(dividingBy: 1.5) < 1.0 ? 1.0 : 0.0
    let phi = 2 * Double.pi * 200 * t + 50 * sin(2 * Double.pi * 0.8 * t)   // 瞬时基频 200±40Hz
    let s = 0.30 * sin(4 * phi) + 0.35 * sin(8 * phi)
        + 0.20 * sin(12 * phi) + 0.08 * sin(phi)
    return Float(gate * s * level)
}

print("\n[1] 合成信号")

if let u = synth("silence", seconds: 3, { _ in 0 }) {
    let r = VoiceActivity.analyze(audio: u)
    check("纯静音判为无语音", r?.isLikelySpeech == false,
          "得到 \(r.map { "\($0.isLikelySpeech) / \($0.reason)" } ?? "nil")")
} else { skip("纯静音", "合成失败") }

// 55/120/240Hz 定频复合音，模拟空调、马达、桌面共振：有周期结构但音高一动不动。
// 20 秒而不是几秒：稳态单音判据要求攒够 tonalMinFrames 帧才敢开火（帧太少时"音高都一样"
// 可能只是统计巧合）。所以很短的一段嗡鸣会被放行——这是故意的保守取舍，
// 而且那种长度本来就过不了上游"短于 5 分钟不推"那道闸。
if let u = synth("hum", seconds: 20, { t in
    0.20 * Float(sin(2 * .pi * 120 * t))
        + 0.10 * Float(sin(2 * .pi * 55 * t))
        + 0.05 * Float(sin(2 * .pi * 240 * t))
}) {
    let r = VoiceActivity.analyze(audio: u)
    check("定频嗡鸣判为无语音", r?.isLikelySpeech == false,
          "得到 \(r.map { "\($0.isLikelySpeech) / \($0.reason)" } ?? "nil")")
    if let r { print("        \(r.metricsLine)") }
} else { skip("定频嗡鸣", "合成失败") }

// 宽带白噪：翻动、摩擦、风声的模型，完全没有基频。
var rng = SystemRandomNumberGenerator()
if let u = synth("hiss", seconds: 6, { _ in Float.random(in: -0.08...0.08, using: &rng) }) {
    let r = VoiceActivity.analyze(audio: u)
    check("宽带噪声判为无语音", r?.isLikelySpeech == false,
          "得到 \(r.map { "\($0.isLikelySpeech) / \($0.reason)" } ?? "nil")")
    if let r { print("        \(r.metricsLine)") }
} else { skip("宽带噪声", "合成失败") }

if let u = synth("voicelike", seconds: 8, { voiceLike($0, level: 0.5) }) {
    let r = VoiceActivity.analyze(audio: u)
    check("音高会动的类语音判为有语音", r?.isLikelySpeech == true,
          "得到 \(r.map { "\($0.isLikelySpeech) / \($0.reason)" } ?? "nil")")
    if let r { print("        \(r.metricsLine)") }
} else { skip("类语音", "合成失败") }

// 保守性回归：很轻的说话（远处人声）绝不能被误杀——误杀真会议是这套判据唯一不可接受的错。
if let u = synth("faint", seconds: 8, { voiceLike($0, level: 0.012) }) {
    let r = VoiceActivity.analyze(audio: u)
    check("很轻但结构正常的人声不被误杀", r?.isLikelySpeech == true,
          "得到 \(r.map { "\($0.isLikelySpeech) / \($0.reason)" } ?? "nil")")
} else { skip("微弱人声", "合成失败") }

// 保守性回归：嗡鸣底下藏着人说话，整段必须放行（稳态单音判据的保命条款）。
// 嗡鸣的电平要低于人声，否则人根本听不清、云端也转不出来，那就不是这条判据该管的事了。
if let u = synth("hum+voice", seconds: 8, { t in
    0.08 * Float(sin(2 * .pi * 120 * t)) + voiceLike(t, level: 0.5)
}) {
    let r = VoiceActivity.analyze(audio: u)
    check("嗡鸣里混着人声要放行", r?.isLikelySpeech == true,
          "得到 \(r.map { "\($0.isLikelySpeech) / \($0.reason)" } ?? "nil")")
} else { skip("嗡鸣混人声", "合成失败") }

// MARK: - 2. 健壮性

print("\n[2] 健壮性")

check("文件不存在返回 nil",
      VoiceActivity.analyze(audio: tmp.appendingPathComponent("nope.wav")) == nil)

let junk = tmp.appendingPathComponent("junk.wav")
try? Data("这不是音频".utf8).write(to: junk)
check("非音频文件返回 nil 而不是崩溃", VoiceActivity.analyze(audio: junk) == nil)

let empty = tmp.appendingPathComponent("empty.wav")
try? Data().write(to: empty)
check("空文件返回 nil 而不是崩溃", VoiceActivity.analyze(audio: empty) == nil)

// 比一帧还短的文件：分块循环最容易在这里退化成不前进。
if let u = synth("tiny", seconds: 0.01, { _ in 0.1 }) {
    check("不足一帧的文件不卡死也不崩", VoiceActivity.analyze(audio: u) != nil, "得到 nil")
} else { skip("超短文件", "合成失败") }

// MARK: - 3. 真实样本
//
// 已知云端转写**失败**（返回 INVALID_ASR_TIMELINE，没识别到任何语音段）的 3 条，
// 和已知**成功**（确实有真人说话）的 5 条。判据必须把这两组分开。

let knownNoise = ["note20260102-105203", "note20260828-170058", "note20260828-171840"]
let knownSpeech = ["note20260102-105251", "note20260102-105641",
                   "note20260828-170044", "note20260828-192104", "note20260828-205856"]

print("\n[3] 真实样本  (\(sampleDir.path))")

struct Row { let base: String; let expectSpeech: Bool; let r: VoiceActivity.Report }
var rows: [Row] = []
var missing = 0

for (base, expect) in knownNoise.map({ ($0, false) }) + knownSpeech.map({ ($0, true) }) {
    let url = sampleDir.appendingPathComponent("\(base).ogg")
    guard FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
    let t0 = Date()
    guard let r = VoiceActivity.analyze(audio: url) else {
        check("\(base) 能解析", false, "analyze 返回 nil")
        continue
    }
    let dt = Date().timeIntervalSince(t0)
    rows.append(Row(base: base, expectSpeech: expect, r: r))
    // 性能预算：一小时不超过 15 秒，按时长折算再放宽一倍余量，短文件给 1 秒地板。
    let budget = max(1.0, r.duration / 3600.0 * 15.0 * 2)
    check("\(base) 耗时 \(String(format: "%.2f", dt))s / \(String(format: "%.0f", r.duration))s 音频",
          dt < budget, "超出预算 \(String(format: "%.2f", budget))s")
}

if rows.isEmpty {
    skip("真实样本分组", "导入/ 下一个样本都没找到")
} else {
    if missing > 0 { print("  注意  有 \(missing) 个样本文件不存在，已跳过") }

    print("\n  ── 指标分布 ──")
    for g in [(false, "转写失败(应判无语音)"), (true, "转写成功(应判有语音)")] {
        print("  \(g.1)")
        for row in rows where row.expectSpeech == g.0 {
            print("    \(row.base)  \(row.r.isLikelySpeech ? "有语音" : "无语音")")
            print("      \(row.r.metricsLine)")
            print("      理由: \(row.r.reason)")
        }
    }

    for row in rows {
        check("\(row.base) 判为\(row.expectSpeech ? "有语音" : "无语音")",
              row.r.isLikelySpeech == row.expectSpeech,
              "实际 \(row.r.isLikelySpeech ? "有语音" : "无语音") — \(row.r.reason)")
    }

    // 分离度。判据真正依赖的是 activeVoicedRatio，所以只在它身上要求余量：
    // 两组必须不重叠，阈值必须落在两组中间，而且离两边都有距离。
    // 光看"8 条都判对了"是不够的——阈值贴着某一条样本的边缘也能全对，
    // 但那种判据换一台设备、换一个录音环境就翻车。分不开就必须在这里暴露出来。
    let noiseRows = rows.filter { !$0.expectSpeech }
    let speechRows = rows.filter { $0.expectSpeech }
    if !noiseRows.isEmpty && !speechRows.isEmpty {
        let nMax = noiseRows.map { $0.r.activeVoicedRatio }.max()!
        let sMin = speechRows.map { $0.r.activeVoicedRatio }.min()!
        print(String(format: "\n  人声帧占活跃帧：噪音组最高 %.2f%% / 语音组最低 %.2f%%（阈值 %.2f%%）",
                     nMax * 100, sMin * 100, VoiceActivity.minActiveVoicedRatio * 100))
        check("两组不重叠", nMax < sMin, "噪音组最高 \(nMax) ≥ 语音组最低 \(sMin)")
        check("阈值落在两组之间",
              nMax < VoiceActivity.minActiveVoicedRatio
                && VoiceActivity.minActiveVoicedRatio < sMin,
              "阈值 \(VoiceActivity.minActiveVoicedRatio) 不在 (\(nMax), \(sMin)) 内")
        check("两侧各留 1.5 倍余量",
              VoiceActivity.minActiveVoicedRatio > nMax * 1.5
                && sMin > VoiceActivity.minActiveVoicedRatio * 1.5,
              String(format: "下侧 %.2fx / 上侧 %.2fx",
                     nMax > 0 ? VoiceActivity.minActiveVoicedRatio / nMax : .infinity,
                     sMin / VoiceActivity.minActiveVoicedRatio))

        // 稳态单音判据不该在任何真实录音上开火。只看帧数够多、规则真会生效的那些行——
        // 只有一两帧人声的样本集中度必然是 100%，那是统计噪声不是嗡鸣。
        let tonalCandidates = rows.filter { $0.r.voicedFrameCount >= VoiceActivity.tonalMinFrames }
        let maxConc = tonalCandidates.map { $0.r.pitchConcentration }.max() ?? 0
        print(String(format: "  基频集中度：帧数够多的 %d 条真实样本里最高 %.0f%%（稳态单音阈值 %.0f%%）",
                     tonalCandidates.count, maxConc * 100, VoiceActivity.tonalConcentration * 100))
        check("稳态单音判据不误伤真实录音", maxConc < VoiceActivity.tonalConcentration,
              String(format: "最高 %.0f%%", maxConc * 100))
    }
}

try? FileManager.default.removeItem(at: tmp)

// MARK: - 结果

print("\n通过 \(passed)  失败 \(failed)  跳过 \(skipped)")
if failed > 0 { exit(1) }
print("VoiceSelfTest 全部通过")
