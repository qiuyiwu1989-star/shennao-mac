import Foundation
import LuyinbiCore

// 删除判据的离线单测。与 Python 版 importer/test_cleanup.py 逐条对应。
// 纯命令行工具链没有 XCTest，所以跑成可执行目标：失败即非零退出。
// 每一条闸都要能独立拦住——删除不可逆，判据松一格就是永久丢录音。

var passed = 0, failed = 0

func check(_ name: String, _ got: Bool, _ want: Bool) {
    if got == want { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("  FAIL  \(name)\n        得到 \(got)\n        期望 \(want)") }
}

// NOW 用本地时钟，跟 Cleanup.recordedAt 的解析时区一致（Python 版是 naive datetime）。
let NOW: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 8; c.day = 28; c.hour = 21; c.minute = 0; c.second = 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    return cal.date(from: c)!
}()

// MARK: - 构造设备列表条目

func entry(_ name: String = "note20260801-100000", secs: UInt32 = 20, size: UInt32? = nil) -> FileEntry {
    let bytes = size ?? secs * 2000                       // 16kbps = 2000B/s
    var raw = Array("\(name).".utf8)
    raw += [UInt8](repeating: 0, count: max(0, 20 - raw.count))
    raw = Array(raw.prefix(20))
    let shown = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    return FileEntry(time: secs, size: bytes, name: shown, rawName: raw)
}

// MARK: - 每个用例一个独立临时目录

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cleanup-selftest-\(UUID().uuidString)")
var caseNo = 0

/// 每个用例独立目录：共用目录会让前一个用例造的文件把"缺留档"这类断言变成假阳性。
/// Python 版就是踩了这个坑才加的 case 编号。
func setup(_ e: FileEntry, rawSize: Int? = nil, ogg: Bool = true, raw: Bool = true,
           oggContent: Data? = nil) -> (URL, URL) {
    caseNo += 1
    let dir = root.appendingPathComponent("case\(caseNo)")
    let dest = dir.appendingPathComponent("导入")
    let rawDir = dir.appendingPathComponent("原始包")
    let fm = FileManager.default
    try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    try! fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
    let base = e.base
    if raw {
        let n = rawSize ?? Int(e.size)
        try! Data(count: n).write(to: rawDir.appendingPathComponent("\(base).opus"))
    }
    if ogg {
        try! (oggContent ?? Data("OggS".utf8))
            .write(to: dest.appendingPathComponent("\(base).ogg"))
    }
    return (dest, rawDir)
}

// MARK: - 打桩的深脑查询

struct StubError: Error, CustomStringConvertible { let description = "网络断了" }

func lookup(status: String = "ready", tid: String? = "t1",
            fail: Bool = false) -> Cleanup.SessionLookup {
    { _ in
        if fail { throw StubError() }
        return .make(status: status, transcriptId: tid)
    }
}

func judge(_ e: FileEntry, uploaded: Bool = true, status: String = "ready",
           tid: String? = "t1", cooling: Int = 3, current: String? = nil,
           rawSize: Int? = nil, ogg: Bool = true, raw: Bool = true,
           fail: Bool = false, oggContent: Data? = nil) async -> Cleanup.Decision {
    let (dest, rawDir) = setup(e, rawSize: rawSize, ogg: ogg, raw: raw, oggContent: oggContent)
    let man = uploaded ? [e.base: "sess-1"] : [:]
    let planner = Cleanup.Planner(lookup: lookup(status: status, tid: tid, fail: fail))
    return await planner.judge(e, uploaded: man, dest: dest, rawDir: rawDir,
                               coolingDays: cooling, now: NOW, deviceCurrent: current)
}

// MARK: - 用例

print("1. 全部条件满足 → 删")
check("允许删除", await judge(entry()).delete, true)

print("\n2. 每一条闸都要能独立拦住")
check("没同步过", await judge(entry(), uploaded: false).delete, false)
check("深脑还在处理", await judge(entry(), status: "finalizing").delete, false)
check("深脑失败", await judge(entry(), status: "failed").delete, false)
check("深脑没转写", await judge(entry(), tid: nil).delete, false)
check("缺 ogg 留档", await judge(entry(), ogg: false).delete, false)
check("缺裸包留档", await judge(entry(), raw: false).delete, false)
check("字节数对不上", await judge(entry(), rawSize: 40).delete, false)
check("裸包非 40 倍数",
      await judge(entry(secs: 20, size: 40001), rawSize: 40001).delete, false)
check("在冷静期内", await judge(entry("note20260828-090000"), cooling: 3).delete, false)
check("是设备当前文件",
      await judge(entry(), current: "note20260801-100000.opus").delete, false)
check("文件名无时间戳", await judge(entry("recording-abc")).delete, false)

print("\n3. 时长必须吻合")
check("时长对得上", await judge(entry(secs: 20, size: 20 * 2000)).delete, true)
let e2 = FileEntry(time: 999, size: 20 * 2000, name: "note20260801-100000.",
                   rawName: Array("note20260801-100000.".utf8))
check("设备声称 999s 实际 20s → 拒绝", await judge(e2).delete, false)

print("\n4. 冷静期边界")
check("冷静期 0 天时立刻可删",
      await judge(entry("note20260828-090000"), cooling: 0).delete, true)

print("\n5. 整机在录音时全部否决")
do {
    let (dest, rawDir) = setup(entry())
    let man = ["note20260801-100000": "s"]
    for (st, label) in [(1, "录音中"), (3, "暂停"), (nil, "状态未知")] as [(Int?, String)] {
        let planner = Cleanup.Planner(lookup: lookup())
        let ds = await planner.plan([entry()], uploaded: man, dest: dest, rawDir: rawDir,
                                    coolingDays: 3, now: NOW, recordStatus: st,
                                    deviceCurrent: nil)
        check("设备\(label) → 一条都不删", ds.contains { $0.delete }, false)
    }
    let planner = Cleanup.Planner(lookup: lookup())
    let ds = await planner.plan([entry()], uploaded: man, dest: dest, rawDir: rawDir,
                                coolingDays: 3, now: NOW, recordStatus: 2, deviceCurrent: nil)
    check("设备未录音 → 正常判定", ds[0].delete, true)
}

print("\n5b. 文件名时间戳必须可信（设备 RTC 归零会绕过冷静期）")
check("RTC 归零的 note20000101 → 不删",
      await judge(entry("note20000101-000000")).delete, false)
check("未来时间戳 → 不删", await judge(entry("note20991231-235959")).delete, false)

print("\n5c. ogg 留档必须是真的")
check("0 字节 ogg → 不删", await judge(entry(), oggContent: Data()).delete, false)
check("内容不是 OggS 的 ogg → 不删",
      await judge(entry(), oggContent: Data("XXXX".utf8)).delete, false)

print("\n6. 查深脑失败时必须保守")
check("查询异常 → 不删", await judge(entry(), fail: true).delete, false)

try? FileManager.default.removeItem(at: root)

print("\n\(String(repeating: "=", count: 46))\n通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
