import Foundation
import LuyinbiCore

// 与 Python 版 importer/test_protocol.py 逐条对应的自测。
// 纯命令行工具链没有 XCTest，所以跑成可执行目标：失败即非零退出。

var passed = 0, failed = 0

func check(_ name: String, _ got: String, _ want: String) {
    if got == want { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)\n        得到 \(got)\n        期望 \(want)") }
}
func check(_ name: String, _ got: Int, _ want: Int) { check(name, "\(got)", "\(want)") }
func check(_ name: String, _ got: Bool, _ want: Bool) { check(name, "\(got)", "\(want)") }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

print("1. CRC-16/XMODEM 标准检验向量")
check("\"123456789\" -> 0x31C3",
      String(format: "0x%04X", Proto.crc16(Array("123456789".utf8))), "0x31C3")

print("\n2. 厂商文档 7.3 的真机成功帧（下载 note20260710-162938.wav）")
let docFrame: [UInt8] = [
    0x5a, 0x03, 0x9e, 0x20, 0x1e, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00, 0x00,
    0x6e, 0x6f, 0x74, 0x65, 0x32, 0x30, 0x32, 0x36, 0x30, 0x37, 0x31, 0x30,
    0x2d, 0x31, 0x36, 0x32, 0x39, 0x33, 0x38, 0x2e, 0x77, 0x61, 0x76, 0x00]
let built = try! Proto.buildImportRequest("note20260710-162938.wav", offset: 0, seq: 3)
check("整帧字节完全一致", hex(built), hex(docFrame))
check("帧长 36B", built.count, 36)
check("CRC=0x209E", String(format: "0x%04X", UInt16(built[2]) | (UInt16(built[3]) << 8)), "0x209E")
check("LEN=30", Int(UInt16(built[4]) | (UInt16(built[5]) << 8)), 30)

print("\n3. 流式解析：在每一个字节位置切开都要能重组")
let frames = [
    Proto.buildFrame(Proto.T.ctrl, 4, [87], seq: 1),
    Proto.buildFrame(Proto.T.file, Proto.FileCmd.importData, (0..<200).map { UInt8($0) }, seq: 2),
    Proto.buildFrame(Proto.T.file, Proto.FileCmd.importEnd, [0], seq: 3),
]
let stream = frames.flatMap { $0 }
let wantSeqs = [1, 2, 3]
var badCuts: [Int] = []
for cut in 1..<stream.count {
    let p = FrameParser()
    let got = p.feed(Array(stream[0..<cut])) + p.feed(Array(stream[cut...]))
    if got.map({ Int($0.seq) }) != wantSeqs { badCuts.append(cut) }
}
check("\(stream.count - 1) 个切点全部通过", badCuts.count, 0)

print("\n4. 一个 notify 含多帧 / 20B 分片喂入")
let p4 = FrameParser()
var got4: [Proto.Frame] = []
for i in stride(from: 0, to: stream.count, by: 20) {
    got4 += p4.feed(Array(stream[i..<min(i + 20, stream.count)]))
}
check("20B 分片喂入得到 3 帧", got4.count, 3)
check("末帧是 2-5 code=0",
      "\(got4[2].type!)-\(got4[2].cmd!)-\(got4[2].body)", "2-5-[0]")

print("\n5. 坏帧不能卡死解析器（音频里必然出现假帧头 0x5A）")
var corrupt = stream
corrupt[20] ^= 0xFF                     // 第 1 帧占 0..8，第 2 帧占 9..216
let p5 = FrameParser()
let got5 = p5.feed(corrupt)
check("坏帧之前的第 1 帧正常解出", got5.first.map { Int($0.seq) } ?? -1, 1)
check("坏帧被丢弃", got5.contains { $0.seq == 2 }, false)
check("坏帧之后的第 3 帧仍能解出", got5.contains { $0.seq == 3 }, true)
check("CRC 错误被计数", p5.crcErrors > 0, true)

print("\n6. 文件列表大端解码（帧头小端，条目大端）")
func entry(_ t: UInt32, _ s: UInt32, _ n: String) -> [UInt8] {
    var out: [UInt8] = []
    for v in [t, s] { out += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    let nb = Array(n.utf8)
    return out + nb + [UInt8](repeating: 0, count: 20 - nb.count)
}
let body6: [UInt8] = [0, 0, 0, 2] + entry(3600, 7_200_000, "note20260710-162938.")
                                  + entry(72, 144_000, "note20260711-090000.")
let list = FileListDecoder.decode(body6)
check("条目数", list.count, 2)
check("时长 3600s", Int(list[0].time), 3600)
check("体积 7.2MB", Int(list[0].size), 7_200_000)
check("截断名", list[0].name, "note20260710-162938.")
check("候选名 opus 优先", list[0].candidates[0], "note20260710-162938.opus")

print("\n7. 声明 count 大于实际字节时不越界")
check("截到实际条目数", FileListDecoder.decode([0, 0, 0, 99] + entry(1, 2, "a")).count, 1)

print("\n8. 长度护栏与删除帧")
var rejected = false
do { _ = try Proto.buildImportRequest("note20260710-162938-toolong.opus") }
catch { rejected = true }
check("超长文件名被拒绝", rejected, true)
check("2-12 分段导入帧长", try! Proto.buildImportRange("a.opus", start: 0, end: 262144).count, 6 + 2 + 8 + 24)

let del = try! Proto.buildDeleteOne("note20260828-170058.opus", seq: 7)
check("2-8 删除帧长 36B（同 2-2 格式，非文档说的 28B 条目）", del.count, 36)
check("2-8 TYPE/CMD", "\(del[6])-\(del[7])", "2-8")
check("2-8 前四字节参数是 offset=0", hex(Array(del[8..<12])), "00 00 00 00")

print("\n9. Ogg 封装：与已验证的 Python 版逐字节对照")
// 用项目里真实的 8 对（裸包 → Python 封出的 ogg）当黄金标尺。
let dest = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/录音项目/导入")
let rawDir = dest.appendingPathComponent("原始包")
let fm = FileManager.default
if let raws = try? fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension == "opus" }).sorted(by: { $0.path < $1.path }), !raws.isEmpty {
    var same = 0, diff = 0
    for r in raws {
        let base = r.deletingPathExtension().lastPathComponent
        let oggURL = dest.appendingPathComponent(base + ".ogg")
        guard let rawData = try? Data(contentsOf: r),
              let wantData = try? Data(contentsOf: oggURL) else { continue }
        let got = (try? OggWrap.wrap([UInt8](rawData))) ?? []
        if got == [UInt8](wantData) { same += 1 } else {
            diff += 1
            print("        \(base) 不一致：得到 \(got.count)B / 期望 \(wantData.count)B")
        }
    }
    check("\(same + diff) 个文件与 Python 输出逐字节一致", diff, 0)
    check("确实比对了文件（不是空跑）", same > 0, true)
    if let first = raws.first, let d = try? Data(contentsOf: first) {
        check("裸包识别", OggWrap.looksRaw([UInt8](d)), true)
        let ogg = (try? OggWrap.wrap([UInt8](d))) ?? []
        check("已封装的不再被当成裸包", OggWrap.looksRaw(ogg), false)
    }
} else {
    print("  跳过：本机没有可对照的样本（导入/原始包 为空）")
}


// MARK: - 补账与截断守卫
//
// 2026-08-29 出过一次：三条录音完整下到本地，清单却没记账，于是每轮重下、
// 一整天没进深脑。补账是对的，但补账的判据必须严——差一个字节都不能算完整，
// 否则就会把半截录音当成完整的推上去（那个事故我们已经吃过一次）。
print("\n补账与截断守卫")
do {
    func entry(_ name: String, _ secs: UInt32, _ size: UInt32) -> FileEntry {
        FileEntry(time: secs, size: size, name: name, rawName: Array(name.utf8))
    }
    let e = entry("note20260829-140354.", 10801, 21_602_000)
    var empty = SyncManifest()

    // 本地没有 → 该下
    check("本地没有就该下",
          SyncPlanner.pending(entries: [e], manifest: empty, status: nil, current: nil,
                              localRaw: [:]).count, 1)

    // 本地完整 → 不下，且可补账
    let full = ["note20260829-140354": 21_602_000]
    check("本地完整就别重下",
          SyncPlanner.pending(entries: [e], manifest: empty, status: nil, current: nil,
                              localRaw: full).count, 0)
    check("本地完整应被补账",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: nil, current: nil,
                                 localRaw: full, localOgg: ["note20260829-140354"]).count, 1)

    // 少一个字节 → 必须重下，绝不补账
    let short = ["note20260829-140354": 21_601_999]
    check("差一个字节仍要重下",
          SyncPlanner.pending(entries: [e], manifest: empty, status: nil, current: nil,
                              localRaw: short).count, 1)
    check("差一个字节不许补账",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: nil, current: nil,
                                 localRaw: short, localOgg: ["note20260829-140354"]).count, 0)

    // 大小对得上但除不尽 40（不可能是完整的裸包）→ 不补账
    let odd = entry("x.", 2, 101)
    check("除不尽 40 不许补账",
          SyncPlanner.unrecorded(entries: [odd], manifest: empty, status: nil, current: nil,
                                 localRaw: ["x": 101], localOgg: ["x"]).count, 0)

    // 0 字节不算完整
    let zero = entry("z.", 0, 0)
    check("0 字节不算完整",
          SyncPlanner.unrecorded(entries: [zero], manifest: empty, status: nil, current: nil,
                                 localRaw: ["z": 0], localOgg: ["z"]).count, 0)

    // ── 录音时刻：文件名信不过时用现场证据 ────────────────────────────
    // 两条都是 2026-09-11 真实事故的原始数据，直接拿日志里的时刻当输入。
    // 公式必须重现人工破案的结论，否则这个修复就只是"看起来对"。
    do {
        func at(_ s: String) -> Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            return f.date(from: s)!
        }
        func show(_ d: Date?) -> String {
            guard let d else { return "nil" }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            return f.string(from: d)
        }

        // 案例一：今天下午录的会，笔把它命名成 2 月 17 号。
        // 日志：15:08:15 那次「没在录」，15:18:13 那次「正在录」，时长 8436 秒。
        let w1 = LiveWitness(notRecordingAt: at("2026-09-11 15:08:15"),
                             firstSeenLiveAt: at("2026-09-11 15:18:13"))
        let r1 = Continuation.trueStart(base: "note20260217-085152", witness: w1, durationSec: 8436)
        check("笔的时钟错 206 天 → 判为不可信", r1.corrected, true)
        check("改用窗口中点 15:13:14", show(r1.at), "2026-09-11 15:13:14")

        // 案例二：9-4 那条，同样的笔。日志：10:27:12 没在录，10:37:08 正在录，5446 秒。
        let w2 = LiveWitness(notRecordingAt: at("2026-09-04 10:27:12"),
                             firstSeenLiveAt: at("2026-09-04 10:37:08"))
        let r2 = Continuation.trueStart(base: "note20260209-064341", witness: w2, durationSec: 5446)
        check("第二条同样判为不可信", r2.corrected, true)
        check("改用窗口中点 10:32:10", show(r2.at), "2026-09-04 10:32:10")

        // 时钟准的笔：文件名落在窗口里，**必须原样采用**——
        // 它比窗口中点精确，不该被一个更粗的估计顶掉。
        let w3 = LiveWitness(notRecordingAt: at("2026-09-11 15:08:15"),
                             firstSeenLiveAt: at("2026-09-11 15:18:13"))
        let r3 = Continuation.trueStart(base: "note20260911-151030", witness: w3, durationSec: 8436)
        check("文件名落在窗口内 → 不动它", r3.corrected, false)
        check("原样采用文件名 15:10:30", show(r3.at), "2026-09-11 15:10:30")

        // 没有现场证据（Mac 不在旁边时录的）：只能信文件名，不假装知道。
        let r4 = Continuation.trueStart(base: "note20260217-085152", witness: nil, durationSec: 8436)
        check("没有证据 → 不声称纠正", r4.corrected, false)
        check("没有证据 → 照用文件名", show(r4.at), "2026-02-17 08:51:52")

        // 下界还要被时长约束住：没看到过「没在录」时，也不能算出一个
        // 早于「第一次看到在录 − 时长」的开始时刻——再早就录不完这么长。
        let w5 = LiveWitness(notRecordingAt: nil, firstSeenLiveAt: at("2026-09-11 15:18:13"))
        let r5 = Continuation.trueStart(base: "note20260217-085152", witness: w5, durationSec: 8436)
        check("没有下界时改用「上界减时长」当下界", r5.corrected, true)
        check("窗口 12:57:37~15:18:13 的中点", show(r5.at), "2026-09-11 14:07:55")

        // 证据自相矛盾（先看到在录、后又说更早没在录）时宁可不动。
        let w6 = LiveWitness(notRecordingAt: at("2026-09-11 16:00:00"),
                             firstSeenLiveAt: at("2026-09-11 15:18:13"))
        let r6 = Continuation.trueStart(base: "note20260217-085152", witness: w6, durationSec: 8436)
        check("证据自相矛盾 → 不动", r6.corrected, false)
    }

    // ── 0-0 同步时间 ────────────────────────────────────────────────
    // 厂商命令表第一条，我们一直没实现，于是从来没给笔校过时。
    // 代价：一条录音被命名成 note20260217-085152，而转写里有人说
    // 「今年的 5 月份去他办公室」——2 月录不出这句话。那个错了大半年的
    // 日期被原样当成录音时刻写进了深脑的 started_at。
    //
    // 这条帧**会改设备的时钟**，发错了比不发更糟，所以逐字节钉死。
    do {
        let f = Proto.buildSetTime((year: 2026, month: 9, day: 11,
                                    hour: 20, minute: 9, second: 12))
        check("0-0 帧长 = 6 头 + 2 类型命令 + 7 载荷", f.count, 15)
        check("MAGIC", Int(f[0]), 0x5A)
        check("LEN 小端低字节 = 9（TYPE+CMD+7）", Int(f[4]), 9)
        check("LEN 小端高字节", Int(f[5]), 0)
        check("TYPE = ctrl 0", Int(f[6]), 0)
        check("CMD = 0", Int(f[7]), 0)
        // year 2B 小端：2026 = 0x07EA
        check("year 低字节 0xEA", Int(f[8]), 0xEA)
        check("year 高字节 0x07", Int(f[9]), 0x07)
        check("month", Int(f[10]), 9)
        check("day", Int(f[11]), 11)
        check("hour", Int(f[12]), 20)
        check("minute", Int(f[13]), 9)
        check("second", Int(f[14]), 12)
        // CRC 覆盖 LEN 两字节 + DATA，跟其他帧同一条规矩
        let crc = Proto.crc16(Array(f[4..<6]) + Array(f[6...]))
        check("CRC 低字节对得上", Int(f[2]), Int(crc & 0xFF))
        check("CRC 高字节对得上", Int(f[3]), Int(crc >> 8))
    }

    // ── 设备自己报 0 字节：一次都不试 ────────────────────────────────
    // 2026-09-09 真实条目 `note20260829-190137.`：录音笔上的一次空录音，
    // 列表里就写着 time=0 size=0。老代码照常下载它、每次回 0 字节记一次失败，
    // 攒够 5 次放弃，然后永远留在设备页的「等着导入 1 条」里——
    // 用户看到的是「连上又断、老有一条卡着」，而链路完全正常。
    // 判据在列表阶段就拿到了，花任何一次连接时间去试都是白花。
    do {
        let 空 = FileEntry(time: 0, size: 0, name: "note20260829-190137.",
                          rawName: Array("note20260829-190137.".utf8))
        check("设备报 0 字节 → 不进待下队列",
              SyncPlanner.pending(entries: [空], manifest: SyncManifest(),
                                  status: nil, current: nil, localRaw: [:]).count, 0)
        check("设备报 0 字节 → 单独列为空文件",
              SyncPlanner.emptyOnDevice(entries: [空]).count, 1)
        check("正常条目不会被当成空文件",
              SyncPlanner.emptyOnDevice(entries: [e]).count, 0)

        // 关键：空文件不该被算成「放弃」。两者在老日志里长得一样，
        // 但该走的路相反——空文件永远不该再试，放弃的手动点一下还有机会。
        check("空文件没有失败记录，不算已放弃",
              SyncPlanner.givenUp(entries: [空], manifest: SyncManifest()).count, 0)
    }

    // ── 僵尸条目：连续失败够多次就不再自动重试 ─────────────────────────
    // 实测过一条设备报着、一下就回 0 字节的文件，9 天里被自动重试了 97 次，
    // 每次都占掉一段 27KB/s 的连接时间。判据是「连续」失败，成功一次就清零。
    do {
        var m = SyncManifest()
        let key = SyncPlanner.manifestKey(e)

        m.downloadFailures[key] = SyncPlanner.giveUpAfter - 1
        check("差一次到阈值，仍然要试",
              SyncPlanner.pending(entries: [e], manifest: m, status: nil, current: nil,
                                  localRaw: [:]).count, 1)
        check("没到阈值不算放弃",
              SyncPlanner.givenUp(entries: [e], manifest: m).count, 0)

        m.downloadFailures[key] = SyncPlanner.giveUpAfter
        check("到阈值就不再自动重试",
              SyncPlanner.pending(entries: [e], manifest: m, status: nil, current: nil,
                                  localRaw: [:]).count, 0)
        check("到阈值应被列为已放弃（界面要能手动重试）",
              SyncPlanner.givenUp(entries: [e], manifest: m).count, 1)

        // 放弃 ≠ 删账：本地已经有完整副本时，补账这条路不能被失败计数挡住，
        // 否则一条「下载老失败但其实早就下全了」的文件会永远补不上账。
        check("已放弃但本地完整，照样补账",
              SyncPlanner.unrecorded(entries: [e], manifest: m, status: nil, current: nil,
                                     localRaw: full, localOgg: ["note20260829-140354"]).count, 1)

        // 人手重置（界面上点「再试一次」）之后要能重新排上
        m.downloadFailures[key] = nil
        check("清零之后重新排上",
              SyncPlanner.pending(entries: [e], manifest: m, status: nil, current: nil,
                                  localRaw: [:]).count, 1)
    }

    // 正在录的一律不碰——哪怕本地大小恰好对上
    check("正在录的不补账",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: 1,
                                 current: "note20260829-140354.", localRaw: full,
                                 localOgg: ["note20260829-140354"]).count, 0)

    // 已经记过账的不重复补
    empty.imported[SyncPlanner.manifestKey(e)] =
        SyncManifest.Imported(file: "a.ogg", bytes: 1, at: "x")
    check("已记账的不重复补",
          SyncPlanner.unrecorded(entries: [e], manifest: empty, status: nil, current: nil,
                                 localRaw: full, localOgg: ["note20260829-140354"]).count, 0)
}

// MARK: - 裸包在、ogg 不在：本地重封，不许当成「已导入」
//
// 2026-09-07 code review：落盘那段是先写裸包、再封 ogg。封装那步失败时直接 continue，
// 裸包留在磁盘上、清单没记。下一轮补账只看裸包完整就记一条 `<base>.ogg` 的账——
// 断言了一个从没写成功的文件。此后 pending 因「已记账」跳过它、
// scanUploadable 因「没有 ogg」找不到它：音频还在，但自动路径里再没有东西会碰它。
print("\n裸包在但 ogg 缺失")
do {
    func entry(_ name: String, _ secs: UInt32, _ size: UInt32) -> FileEntry {
        FileEntry(time: secs, size: size, name: name, rawName: Array(name.utf8))
    }
    let e = entry("note20260829-140354.", 10801, 21_602_000)
    let m = SyncManifest()
    let raw = ["note20260829-140354": 21_602_000]

    check("ogg 不在 → 不许补账（那是在断言一个不存在的文件）",
          SyncPlanner.unrecorded(entries: [e], manifest: m, status: nil, current: nil,
                                 localRaw: raw, localOgg: []).count, 0)
    check("ogg 不在 → 应该走重封",
          SyncPlanner.needsRewrap(entries: [e], manifest: m, status: nil, current: nil,
                                  localRaw: raw, localOgg: []).count, 1)
    check("ogg 在 → 就是普通补账，不重封",
          SyncPlanner.needsRewrap(entries: [e], manifest: m, status: nil, current: nil,
                                  localRaw: raw, localOgg: ["note20260829-140354"]).count, 0)
    check("裸包不完整 → 两条路都不走（该重下）",
          SyncPlanner.needsRewrap(entries: [e], manifest: m, status: nil, current: nil,
                                  localRaw: ["note20260829-140354": 21_601_999],
                                  localOgg: []).count, 0)
    check("正在录的不重封",
          SyncPlanner.needsRewrap(entries: [e], manifest: m, status: 1,
                                  current: "note20260829-140354.",
                                  localRaw: raw, localOgg: []).count, 0)
}

// MARK: - 读不到设备状态时，「不碰正在录的那条」必须失效朝安全那边倒
//
// 2026-09-07 code review：原来第一行是 `guard let current else { return false }`，
// 也就是「读不到当前在录哪个」=「没有正在录的」。而 readDeviceInfo 用 try? 吞掉失败，
// 27KB/s 链路上 4 秒超时很常见。一次丢包就解除这道闸 → 拉到半截 →
// 字节数与设备当时声称的一致，下载完整性硬闸也拦不住（它内部自洽，只是短）→
// 以 mac-ble-<base> 推上去并 finalize → 完整版永远进不去。
print("\n设备状态读不全时的失效方向")
do {
    func entry(_ name: String, _ secs: UInt32, _ size: UInt32) -> FileEntry {
        FileEntry(time: secs, size: size, name: name, rawName: Array(name.utf8))
    }
    let e = entry("note20260907-153127.", 900, 1_800_000)
    let m = SyncManifest()

    check("说在录、但说不出录哪个 → 全拦",
          SyncPlanner.pending(entries: [e], manifest: m, status: 1, current: nil).count, 0)
    check("暂停中、也说不出录哪个 → 全拦",
          SyncPlanner.pending(entries: [e], manifest: m, status: 3, current: nil).count, 0)
    // status 也读不到时**不拦**：分不清「这次读失败」和「这个固件不实现 3-20」，
    // 一律拦会让老固件永远同步不了——为了防一种丢失而制造彻底不可用，是更坏的交易。
    // 这一路交给 readDeviceInfo 记日志，不在这里做判断。
    check("两个都读不到 → 放行（否则老固件永远同步不了）",
          SyncPlanner.pending(entries: [e], manifest: m, status: nil, current: nil).count, 1)
    check("明确说了没在录 → 放行（这是正常情况，不能误伤）",
          SyncPlanner.pending(entries: [e], manifest: m, status: 2, current: nil).count, 1)
    check("在录别的那条 → 这条放行",
          SyncPlanner.pending(entries: [e], manifest: m, status: 1,
                              current: "note20260907-999999.").count, 1)
    check("在录的就是这条 → 拦",
          SyncPlanner.pending(entries: [e], manifest: m, status: 1,
                              current: "note20260907-153127.").count, 0)
}

// MARK: - 清单读不出来时，绝不许把空账本写回去
//
// 2026-09-07 code review：load 把「文件不存在」「读不到」「半截 JSON」压成同一个空清单，
// 而每个写入点都是 load → 改一个键 → .atomic save，于是空清单被原子地永久写回。
// Python 版 pull.py 写同一个文件用的是 write_text（先截断再写），
// Swift 只要在那个窗口读一次就会撞上。
print("\n清单读失败不许覆盖")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("manifest-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("manifest.json")

    // 文件不存在 = 首次运行，这种空清单是可信的
    let fresh = SyncManifest.load(from: url)
    check("文件不存在 → 可信", fresh.isTrustworthy, true)
    var seeded = fresh
    seeded.imported["k"] = SyncManifest.Imported(file: "a.ogg", bytes: 1, at: "t")
    seeded.uploaded["a"] = "session-1"
    check("首次运行可以正常写", (try? seeded.save(to: url)) != nil, true)

    // 半截 JSON（正是 Python 非原子写的那个窗口）
    try? Data("{\"imported\": {\"k\": {\"file\"".utf8).write(to: url)
    let poisoned = SyncManifest.load(from: url)
    check("半截 JSON → 不可信", poisoned.isTrustworthy, false)
    check("不可信的清单拒绝保存", (try? poisoned.save(to: url)) == nil, true)

    // 关键断言：磁盘上那份没有被空清单覆盖掉
    let after = try? Data(contentsOf: url)
    check("磁盘上的内容没有被空清单抹掉", (after?.count ?? 0) > 0, true)

    // 跨重启必须活着的两本账：下载失败计数、重推轮次。
    // 后者原来只在内存里——重启后 repushFailed 又从 r2 开始，而 r2 那个会话
    // 如果已经是 failed，服务端会挡住重传，这条录音就再也推不上去了。
    var counted = seeded
    counted.downloadFailures["k"] = 3
    counted.repushRounds["a"] = 4
    check("失败计数与重推轮次能写进去", (try? counted.save(to: url)) != nil, true)
    let reread = SyncManifest.load(from: url)
    check("下载失败计数跨读写还在", reread.downloadFailures["k"] ?? 0, 3)
    check("重推轮次跨读写还在", reread.repushRounds["a"] ?? 0, 4)

    // 修好之后照常读写
    check("重新写入好的清单可以恢复", (try? seeded.save(to: url)) != nil, true)
    let recovered = SyncManifest.load(from: url)
    check("恢复后账目还在", recovered.uploaded["a"] ?? "", "session-1")
    check("恢复后可信", recovered.isTrustworthy, true)
}

// MARK: - 下载完整性硬闸
//
// 2026-08-29：三小时录音只收到 7,200,666/21,602,000 字节，设备照样回 endCode 0，
// 于是半截文件落盘、被当成完整录音推进深脑，时长按裸包算成 3600.333 秒，
// 服务端 ffmpeg 一比对就 OUTPUT_INVALID。这道闸就是为了让这件事不再发生。
print("\n下载完整性硬闸")
do {
    check("一字不差才算完整",
          SyncPlanner.downloadComplete(got: 21_602_000, announced: 21_602_000), true)
    check("少一个字节不算",
          SyncPlanner.downloadComplete(got: 21_601_999, announced: 21_602_000), false)
    check("多一个字节也不算",
          SyncPlanner.downloadComplete(got: 21_602_001, announced: 21_602_000), false)
    check("那次真实的截断必须被拦下",
          SyncPlanner.downloadComplete(got: 7_200_666, announced: 21_602_000), false)
    check("零字节不算",
          SyncPlanner.downloadComplete(got: 0, announced: 0), false)
    check("除不尽 40 不算（截在半包上）",
          SyncPlanner.downloadComplete(got: 101, announced: 101), false)
    check("能被 40 整除且相等才算",
          SyncPlanner.downloadComplete(got: 120, announced: 120), true)
}


// MARK: - 设备切分的识别与拼接
//
// 录音笔有 3 小时上限，到点自动断开、隔 1 秒开下一条。实测 2026-08-29：
// 14:03:54 录 3:00:01，17:03:56 接着录 13:16，中间只差 1 秒——同一场会。
// 判宽了会把两场独立会议粘成一条（正文串了、比切开糟得多），所以判据要严。
// MARK: - wav 不能用裸包的判据去卡
//
// 2026-09-07 code review：下载候选名里 .opus 之后就是 .wav（FileEntry.candidates），
// 设备真吐 wav 时，长度是任意的。而完整性硬闸原来无差别地要求 %40==0：
//   · 39/40 的概率 → 完好的文件被判「不完整」，重试五次进「放弃」名单
//     （很可能就是那条 9 天试了 97 次的僵尸条目）
//   · 剩下 1/40 → looksRaw 只排除 OggS，RIFF 不是 OggS 所以判成裸包，
//     wav 被塞进 wrap() 封成 Ogg/Opus——推上去的是一段垃圾，本地还看着正常
print("\nwav 与裸包的判据要分开")
do {
    check("裸包：除不尽 40 仍算不完整", SyncPlanner.downloadComplete(got: 101, announced: 101), false)
    check("裸包：整除且相等才算完整", SyncPlanner.downloadComplete(got: 120, announced: 120), true)
    check("wav：除不尽 40 也算完整（长度本来就是任意的）",
          SyncPlanner.downloadComplete(got: 101, announced: 101, isRawOpus: false), true)
    check("wav：字节数对不上照样不完整（这条不能松）",
          SyncPlanner.downloadComplete(got: 100, announced: 101, isRawOpus: false), false)
    check("wav：0 字节不算完整",
          SyncPlanner.downloadComplete(got: 0, announced: 0, isRawOpus: false), false)

    // looksRaw 必须正面识别，不能只排除 OggS
    func bytes(_ head: String, pad: Int) -> [UInt8] {
        var d = Array(head.utf8); d += [UInt8](repeating: 0, count: pad - d.count); return d
    }
    var wav = bytes("RIFF", pad: 8) + Array("WAVE".utf8)
    wav += [UInt8](repeating: 0, count: 40 - wav.count % 40)   // 凑成 40 的整数倍
    check("长度整除 40 的 wav 不许被当成裸包", OggWrap.looksRaw(wav), false)
    check("wav 被认成已知容器", OggWrap.isKnownContainer(wav), true)

    let ogg = bytes("OggS", pad: 80)
    check("Ogg 不是裸包", OggWrap.looksRaw(ogg), false)

    let raw = [UInt8](repeating: 0x41, count: 400)
    check("真裸包仍判为裸包", OggWrap.looksRaw(raw), true)
    check("真裸包不是已知容器", OggWrap.isKnownContainer(raw), false)
}

// MARK: - 跨连接断点能不能接着用
//
// 2026-09-08：CB08 连上约 8 秒就主动断链，而 15.5MB 的两小时录音要传 10 分钟。
// 原来的续传只在同一条连接内有效，一断就把已收字节全丢——那条文件永远下不完
// （实测一整天 108 次连接、0 次成功）。现在断点落盘、跨连接接着传。
// 但接错的代价很重：拼出来的会是一段前后不属于同一个文件的字节，
// 而它可能恰好整除 40、总长也刚好凑够，完整性硬闸未必拦得住。
// MARK: - 自动生成的设备号必须过得了服务端校验
//
// 2026-09-08：Mac 的机器名天生带空格（实测 Host.current().localizedName
// 是「qiu的MacBook Air」），而服务端 isValidDeviceNo 不收任何空白。
// 于是每次自动绑定都被判 device_no_invalid，客户端把它显示成
// 「名字里有空格或特殊字符，换一个」，然后又生成同样带空格的名字重试——
// 自己跟自己打架。写那段代码时我没实际看过它返回什么，是想当然。
print("\n自动设备号的清洗")
do {
    check("空格换成连字符", SyncPlanner.safeDeviceNo("CB08-qiu的MacBook Air"), "CB08-qiu的MacBook-Air")
    check("多个连续空格不产生空段", SyncPlanner.safeDeviceNo("a   b"), "a-b")
    check("首尾空白不留下悬空连字符", SyncPlanner.safeDeviceNo("  x  "), "x")
    check("换行也算空白", SyncPlanner.safeDeviceNo("a\nb"), "a-b")
    check("没有空白的原样返回", SyncPlanner.safeDeviceNo("CB08-Mac"), "CB08-Mac")
    check("超长截到 64", SyncPlanner.safeDeviceNo(String(repeating: "x", count: 100)).count, 64)
}

print("\n跨连接断点的可用性判据")
do {
    check("大小一致、整包边界、还没下完 → 可用",
          SyncPlanner.partialUsable(bytes: 4000, savedFor: 21_602_000, announced: 21_602_000), true)
    check("设备这次报的大小变了 → 作废（文件在设备上变过）",
          SyncPlanner.partialUsable(bytes: 4000, savedFor: 21_602_000, announced: 21_602_040), false)
    check("没记下当时的大小 → 作废（无从核对）",
          SyncPlanner.partialUsable(bytes: 4000, savedFor: nil, announced: 21_602_000), false)
    check("停在半个包上 → 作废（接着传会整体错位）",
          SyncPlanner.partialUsable(bytes: 4001, savedFor: 21_602_000, announced: 21_602_000), false)
    check("空断点没有意义",
          SyncPlanner.partialUsable(bytes: 0, savedFor: 21_602_000, announced: 21_602_000), false)
    check("已经够了就不该叫断点",
          SyncPlanner.partialUsable(bytes: 21_602_000, savedFor: 21_602_000, announced: 21_602_000), false)
    check("超过声称大小更不能用",
          SyncPlanner.partialUsable(bytes: 21_602_040, savedFor: 21_602_000, announced: 21_602_000), false)
}

print("\n设备切分识别")
do {
    let capped = 10801.0          // 顶满上限
    check("实测那一对：1 秒空档 + 顶满上限 → 合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: capped,
                                      nextBase: "note20260829-170356"), true)

    // 时长没顶满 → 是人手停的，不合
    check("时长没顶满就不合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: 600,
                                      nextBase: "note20260829-170356"), false)

    // 顶满了但隔了很久 → 是另一场会
    check("顶满但隔 1 小时不合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: capped,
                                      nextBase: "note20260829-180356"), false)

    // 空档 5 秒 = 边界，允许；6 秒不允许
    check("空档 5 秒（边界）合",
          Continuation.isContinuation(prevBase: "note20260829-140354", prevSeconds: 10800,
                                      nextBase: "note20260829-170354"), true)

    // 时间倒流（后一条比前一条早）→ 不合
    check("时间倒流不合",
          Continuation.isContinuation(prevBase: "note20260829-170356", prevSeconds: capped,
                                      nextBase: "note20260829-140354"), false)

    // 文件名解析
    let d = Continuation.startedAt(base: "note20260829-170356")
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = .current
    check("文件名解析出真实时刻", d.map { f.string(from: $0) } ?? "nil", "2026-08-29 17:03:56")
    check("认不出的名字返回 nil", Continuation.startedAt(base: "mac-xyz") == nil, true)

    // 分组
    let g = Continuation.groupContinuations([
        ("note20260829-140354", capped),
        ("note20260829-170356", 796),
        ("note20260829-190146", 7),
    ])
    check("三条分成两组", g.count, 2)
    check("前两条合成一组", g[0].count, 2)
    check("第三条自己一组", g[1].count, 1)

    // 拼接
    let a = [UInt8](repeating: 1, count: 80), b = [UInt8](repeating: 2, count: 40)
    check("拼接长度相加", Continuation.concatRawPackets([a, b])?.count ?? -1, 120)
    check("除不尽 40 拒绝拼", Continuation.concatRawPackets([a, [UInt8](repeating: 3, count: 41)]) == nil, true)
    check("空段拒绝拼", Continuation.concatRawPackets([a, []]) == nil, true)
}

print("\n\(String(repeating: "=", count: 46))\n通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
