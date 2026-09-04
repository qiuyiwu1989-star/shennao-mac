import Foundation
import LuyinbiCore

/// 假引擎：让界面在真引擎（Monitor.swift）写完之前就能独立编译、独立跑起来。
///
/// 它实现的是和真引擎完全一样的 `SyncEngineObserving`，
/// 所以换成真引擎时只需要改 LuyinbiRootApp.swift 里造对象那一行。
/// 脚本化地循环走一遍：等待 → 连接 → 读列表 → 下载 → 推送 → 完成 → 空闲。
@MainActor
final class PreviewEngine: SyncEngineObserving {

    private(set) var device = DeviceInfo()
    private(set) var items: [RecordingItem] = []
    private(set) var phase: SyncPhase = .idle
    private(set) var pendingBindMismatch: BindMismatch?
    private(set) var lastRun: Date?
    private(set) var lastSummary: String = "尚未同步"

    private var tick = 0
    private var timer: Timer?

    init(animated: Bool = true) {
        reset()
        guard animated else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    // MARK: - 假数据

    /// 四条录音刚好铺满链路的各种组合，方便肉眼核对界面。
    private func reset() {
        tick = 0
        phase = .waitingForDevice
        device = DeviceInfo()
        device.name = "CB08 录音笔"
        items = [
            // 已经全通，并且设备上那份已经清掉了
            RecordingItem(base: "note20260826-091203", durationSec: 3721,
                          deviceSize: nil, localBytes: 7_412_880,
                          sessionId: "854c3159-1f0a-4b2e-9a77-2c1d5b8e0a31",
                          brainStatus: "ready",
                          transcriptId: "4e2251fb-77c0-4a1d-8f3e-9b0c2d4e6f18"),
            // 三处都在
            RecordingItem(base: "note20260827-140801", durationSec: 848,
                          deviceSize: 1_812_400, localBytes: 1_812_400,
                          sessionId: "8350de23-bf6d-4e32-ba3d-22e892ce856a",
                          brainStatus: "ready",
                          transcriptId: "8350de23-bf6d-4e32-ba3d-22e892ce856a"),
            // 落了盘，推深脑失败
            RecordingItem(base: "note20260828-205856", durationSec: 1264,
                          deviceSize: 2_640_120, localBytes: 2_640_120,
                          sessionId: "1c9d77aa-0b2e-4f61-93c4-6d8a0e5b7c22",
                          brainStatus: "failed", transcriptId: nil,
                          lastError: "INVALID_ASR_TIMELINE：provider returned no canonical segments"),
            // 还只在设备上
            RecordingItem(base: "note20260828-221410", durationSec: 96,
                          deviceSize: 204_800),
        ]
    }

    // MARK: - 脚本

    private func step() {
        tick += 1
        switch tick {
        case 1...4:
            phase = .waitingForDevice

        case 5:
            phase = .connecting

        case 6...8:
            device.connected = true
            device.battery = 78
            device.firmware = "V1.0.0"
            device.gain = 3
            device.recordStatus = 2
            device.capacityRemain = 94_857_216      // 单位是设备的块数，不是字节
            device.capacityTotal = 121_634_816
            phase = .connecting

        case 9...11:
            phase = .listing

        case 12...26:
            let pct = min(100, (tick - 11) * 7)
            phase = .downloading("note20260828-221410.opus", pct)
            if pct >= 100 { items[3].localBytes = 204_800 }

        case 27...32:
            let steps = ["建会话", "要上传地址", "直传 COS", "校验分片", "冻结分片", "收尾"]
            phase = .uploading("note20260828-221410.opus", steps[min(tick - 27, steps.count - 1)])
            items[3].sessionId = "f7a1b3c5-2d4e-4a6b-8c0d-1e3f5a7b9c11"
            items[3].brainStatus = "finalizing"

        case 33:
            items[3].brainStatus = "ready"
            items[3].transcriptId = "b2c4d6e8-1a3b-4c5d-8e9f-0a1b2c3d4e5f"
            phase = .cleaning

        case 34:
            phase = .idle
            lastRun = Date()
            lastSummary = "本次导入 1 条，推送成功 1 条，跳过 3 条"

        case 35...44:
            phase = .idle
            device.recordStatus = (tick % 2 == 0) ? 1 : 2   // 让「录音中」这个态也能被看到

        default:
            // 循环回去，方便反复观察整条流程
            let keepRun = lastRun
            let keepSummary = lastSummary
            reset()
            lastRun = keepRun
            lastSummary = keepSummary
        }
    }
}
