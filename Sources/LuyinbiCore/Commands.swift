import Foundation

/// 高层命令。全部建立在 BLEClient 之上，语义与已验证的 Python 版一致。
public extension BLEClient {

    func battery(timeout: TimeInterval = 5) async throws -> UInt8? {
        try send(Proto.T.ctrl, 3)
        return await expect(Proto.T.ctrl, 4, timeout: timeout)?.body.first
    }

    func firmware(timeout: TimeInterval = 4) async throws -> String? {
        try send(Proto.T.ctrl, 10)
        guard let b = await expect(Proto.T.ctrl, 11, timeout: timeout)?.body else { return nil }
        return String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// 剩余 / 总。厂商原文单位标 8KB，实测更接近 64B——先原样返回，别替设备做单位换算。
    func capacity(timeout: TimeInterval = 4) async throws -> (remain: UInt32, total: UInt32)? {
        try send(Proto.T.ctrl, 1)
        guard let b = await expect(Proto.T.ctrl, 2, timeout: timeout)?.body, b.count >= 8 else { return nil }
        func le(_ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
        }
        return (le(0), le(4))
    }

    /// 1=低 2=中 3=高
    func gain(timeout: TimeInterval = 4) async throws -> UInt8? {
        try send(Proto.T.key, Proto.KeyCmd.gainReq)
        return await expect(Proto.T.key, Proto.KeyCmd.gainAck, timeout: timeout)?.body.first
    }

    /// 1=录音中 2=未录音 3=暂停。取不到返回 nil——调用方必须按最坏情况处理。
    func recordStatus(timeout: TimeInterval = 4) async throws -> UInt8? {
        try send(Proto.T.key, Proto.KeyCmd.statusReq)
        return await expect(Proto.T.key, Proto.KeyCmd.statusAck, timeout: timeout)?.body.first
    }

    func currentFilename(timeout: TimeInterval = 4) async throws -> String? {
        try send(Proto.T.key, Proto.KeyCmd.curNameReq)
        guard let b = await expect(Proto.T.key, Proto.KeyCmd.curNameAck, timeout: timeout)?.body,
              !b.isEmpty else { return nil }
        let s = String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// 累积多帧 2-1，收到 2-18 交付。旧固件不发 2-18，退化为「空闲即收尾」。
    func fileList(idleFallback: TimeInterval = 1.5,
                  hardTimeout: TimeInterval = 30) async throws -> (entries: [FileEntry], gotDone: Bool) {
        try send(Proto.T.file, Proto.FileCmd.listReq)
        var entries: [FileEntry] = []
        var gotDone = false
        let deadline = Date().addingTimeInterval(hardTimeout)
        var last = Date()
        while Date() < deadline {
            guard let (_, f) = await nextFrame(timeout: 0.3) else {
                if !entries.isEmpty && Date().timeIntervalSince(last) > idleFallback { break }
                continue
            }
            guard f.type == Proto.T.file else { continue }
            if f.cmd == Proto.FileCmd.listData {
                entries += FileListDecoder.decode(f.body); last = Date()
            } else if f.cmd == Proto.FileCmd.listDone {
                gotDone = true; break
            }
        }
        return (entries, gotDone)
    }

    struct DownloadResult {
        public var filename = ""
        public var data: [UInt8] = []
        public var endCode: UInt8?
        public var seconds: Double = 0
        public var resumes = 0
        public var tried: [String] = []
        /// 这次是被断线打断的（不是设备说完成、也不是设备拒绝）。
        /// 调用方据此决定：存断点、下次续传，而不是记一次「下载失败」。
        public var disconnected = false
        public var ok: Bool { endCode == 0 && !data.isEmpty }
        public var kbps: Double { seconds > 0 ? Double(data.count) / 1024 / seconds : 0 }
    }

    /// 按候选名依次尝试；中途断流用 offset 续传。
    /// 关键区分：received==0 才换候选名；已经有数据就只续传——换名会把两个文件的字节拼在一起。
    /// 下载一个文件。卡顿时按 offset 续传。
    ///
    /// `maxResumes` 必须随文件大小走，不能是个常数：
    /// 一条 21.6 MB 的三小时录音在 27 KB/s 下要连续传 13 分钟，中间不能有超过
    /// `idleTimeout` 秒的空档——蓝牙在弱信号下做不到。以前写死 5 次，用完就放弃，
    /// 而放弃后下一轮**从 0 重来**，于是这条录音整天在 30%→90%→30% 之间打转，
    /// 一个字节都没存下来。传 nil 就按每 MB 给 2 次、下限 8 次算。
    /// - Parameter resumeFrom: 上一次连接里已经收到、并且已经落到磁盘上的字节。
    ///   非空时从 `resumeFrom.count` 这个偏移接着要，而不是从 0 重来。
    ///
    ///   **为什么必须跨连接续传**：2026-09-08 实测，CB08 连上约 8 秒就主动断链，
    ///   而 15.5MB 的两小时录音在 27KB/s 下要传 10 分钟。原来的续传只在
    ///   同一条连接内有效——设备一断，sendRaw 抛错、整个 download 失败，
    ///   已经收到的几百 KB 全部丢弃，下一轮从 0 再来。
    ///   于是**这条文件永远下不完**：一整天 108 次连接、0 次成功。
    ///   协议本身早就支持 offset（buildImportRequest 就带这个参数），
    ///   缺的只是让进度活过一次断线。
    ///
    /// - Returns: 即使中途断了也会带回 `data`（已收到的部分），
    ///   由调用方决定要不要存成断点。
    func download(candidates: [String], expectSize: UInt32? = nil,
                  idleTimeout: TimeInterval = 12, maxResumes: Int? = nil,
                  resumeFrom: [UInt8] = [],
                  onProgress: ((Int, UInt32?) -> Void)? = nil) async throws -> DownloadResult {
        var res = DownloadResult()
        let resumeBudget = maxResumes
            ?? max(8, Int((expectSize.map(Double.init) ?? 0) / 1_048_576 * 2))
        for name in candidates {
            res.tried.append(name); res.filename = name
            var buf: [UInt8] = resumeFrom
            let started = Date()
            var resumes = 0
            while true {
                do {
                    try sendRaw(try Proto.buildImportRequest(name, offset: UInt32(buf.count), seq: nextSeq()))
                } catch {
                    // 断线了。**把已经收到的字节带回去**，别让它随异常一起蒸发——
                    // 调用方会把它存成断点，下次连上从这里接着要。
                    res.data = buf
                    res.seconds = Date().timeIntervalSince(started)
                    res.resumes = resumes
                    res.disconnected = true
                    return res
                }
                var stalled = false
                var last = Date()
                while true {
                    guard let (_, f) = await nextFrame(timeout: 0.5) else {
                        if Date().timeIntervalSince(last) > idleTimeout { stalled = true; break }
                        continue
                    }
                    guard f.type == Proto.T.file else { continue }
                    if f.cmd == Proto.FileCmd.importBegin { last = Date() }
                    else if f.cmd == Proto.FileCmd.importData {
                        buf += f.body; last = Date(); onProgress?(buf.count, expectSize)
                    } else if f.cmd == Proto.FileCmd.importEnd {
                        res.endCode = f.body.first; break
                    }
                }
                res.data = buf
                res.seconds = Date().timeIntervalSince(started)
                res.resumes = resumes
                if stalled && !buf.isEmpty && resumes < resumeBudget { resumes += 1; continue }
                break
            }
            if res.endCode == 0 && !buf.isEmpty { return res }
            if res.endCode == 1 && buf.isEmpty { continue }   // 文件不存在，换候选名
            return res
        }
        return res
    }

    /// 删除单个文件，然后**重拉列表确认它真的消失了**。
    /// 应答不可信（旧固件不发 2-13），以重拉列表为准。
    func deleteOne(_ entry: FileEntry, timeout: TimeInterval = 6) async throws -> (Bool, String) {
        var notes: [String] = []
        for name in entry.candidates {
            try sendRaw(try Proto.buildDeleteOne(name, seq: nextSeq()))
            let ack = await expect(Proto.T.file, Proto.FileCmd.delOneAck, timeout: timeout)
            let code = ack.map { $0.body.first.map { "应答 \($0)" } ?? "应答空" } ?? "无应答"
            let (left, _) = try await fileList()
            if !left.contains(where: { $0.rawName == entry.rawName && $0.size == entry.size }) {
                return (true, "\(name) → \(code)，重拉列表已消失")
            }
            notes.append("\(name):\(code)")
        }
        return (false, "全部候选名都被拒绝（" + notes.joined(separator: "；") + "）")
    }
}
