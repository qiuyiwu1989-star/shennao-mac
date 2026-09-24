import Foundation

/// 界面与同步引擎之间的共享模型。
/// 先定死这层，UI 和引擎才能并行开发、各写各的文件。

/// 一条录音在三个地方的状态。界面上就画成 [设备] → [本地] → [深脑] 的状态链。
public struct RecordingItem: Identifiable, Sendable {
    public var id: String { base }
    public let base: String              // 不含扩展名，如 note20260828-205856
    public var durationSec: Int
    public var deviceSize: UInt32?       // 还在设备上则有值
    public var localBytes: Int?          // 已落盘则有值
    public var sessionId: String?        // 已推深脑则有值
    public var brainStatus: String?      // ready / failed / finalizing …
    public var transcriptId: String?
    public var lastError: String?
    /// 上传试过几次。0 = 还在队列里排队，没轮到它。
    ///
    /// 没有这个数，界面就分不出「排队中」和「反复推不上去」——
    /// 两者都是「落了盘、没 sessionId」，于是一律显示成「推送卡住」。
    /// 刚下完的文件当场被标成故障，而队列其实好好的。
    public var uploadAttempts: Int = 0
    /// 上传前定的标题与项目。只对还没推上去的有意义。
    public var plannedTitle: String?
    public var plannedProjectId: String?
    /// 深脑侧的失败码（如 INVALID_ASR_TIMELINE）。界面靠它判断"值不值得重推"，
    /// 而不是笼统给个重试按钮——有些失败重推一百次结果都一样。
    public var brainErrorCode: String?
    /// 深脑分析后生成的标题。没分析过就是 nil，界面退回显示日期时间。
    public var brainTitle: String?
    /// 收藏。纯本地标记——深脑那边没有这个概念，也不该为一个个人偏好去改服务端。
    public var starred = false
    /// 人手标了「忽略」。只影响计数和配色，不动录音本身。
    public var dismissed = false
    /// 深脑里已经没有这条了（服务端回 404）。本地留档不受影响。
    public var serverGone = false
    /// 还没指认的说话人个数。>0 就该进「需要你处理」——
    /// 不指认的话，后面所有洞察里都是「说话人1」。
    public var unconfirmedSpeakers: Int = 0
    /// 因为短于门槛而没推深脑（不是失败，是按规则跳过）。值是实际秒数。
    public var skippedShortSeconds: Double?
    /// 已排队等着从设备上删除，等设备下次出现时执行
    public var pendingDeviceDelete = false

    public var onDevice: Bool { deviceSize != nil }
    public var onDisk: Bool { localBytes != nil }
    public var inBrain: Bool { brainStatus == "ready" && transcriptId != nil }

    public init(base: String, durationSec: Int, deviceSize: UInt32? = nil,
                localBytes: Int? = nil, sessionId: String? = nil,
                brainStatus: String? = nil, transcriptId: String? = nil,
                lastError: String? = nil, brainErrorCode: String? = nil) {
        self.base = base; self.durationSec = durationSec; self.deviceSize = deviceSize
        self.localBytes = localBytes; self.sessionId = sessionId
        self.brainStatus = brainStatus; self.transcriptId = transcriptId
        self.lastError = lastError; self.brainErrorCode = brainErrorCode
    }
}

public struct DeviceInfo: Sendable {
    public var name: String = "—"
    public var connected = false
    public var battery: UInt8?
    public var firmware: String?
    public var gain: UInt8?
    public var recordStatus: UInt8?      // 1录音中 2未录音 3暂停
    public var capacityRemain: UInt32?
    public var capacityTotal: UInt32?
    /// 这支笔在深脑里登记的名字。**每支笔各不相同**——
    /// name 是型号（所有 CB08 都叫 CB08），认不出是哪一支。
    public var bindingName: String?
    /// 本机给这支笔的标识（CoreBluetooth peripheral UUID）。改名要用它定位。
    public var peripheralId: String?
    /// 最后一次**确认这支笔就在旁边**的时刻：收到它的广播，或者跟它连着。
    ///
    /// 2026-09-16 用户第三次说「连上之后马上断」。日志里那天真正连不上的只有 2 次，
    /// 而「连上看一眼没新录音就断开」有 59 次——每一次界面都从「已连接」跳回
    /// 「未连接」，电量容量固件一起变成「—」。笔明明就在桌上、醒着、一直在广播。
    /// 「此刻连没连着」回答不了「笔在不在」，广播才回答得了。
    public var lastSeenAt: Date?
    /// 电量/容量/固件最近一次真读到的时刻。断开之后照样摆读数，但要说清是几点读的。
    public var readingsAt: Date?

    /// 笔醒着就会持续广播；空闲几分钟休眠后广播才停。
    /// 45 秒没收到任何广播、也没连着，才算不在旁边——
    /// 我们自己断开之后笔要过几秒才重新广播，窗口不能卡得太紧。
    public static let nearbyWindow: TimeInterval = 45

    public func isNearby(now: Date = Date()) -> Bool {
        if connected { return true }
        guard let seen = lastSeenAt else { return false }
        return now.timeIntervalSince(seen) <= Self.nearbyWindow
    }
    public init() {}
}

/// 一支笔本地记着绑给了别的账号，跟当前登录的账号不一致（spec 019）。
/// 界面据此显示确认卡片：换到当前账号需要人手确认，不会自动发生。
public struct BindMismatch: Identifiable, Sendable {
    public var id: String { peripheralId }
    public let peripheralId: String
    public let deviceName: String
    public let previousEmail: String
    public let currentEmail: String
    public init(peripheralId: String, deviceName: String, previousEmail: String, currentEmail: String) {
        self.peripheralId = peripheralId; self.deviceName = deviceName
        self.previousEmail = previousEmail; self.currentEmail = currentEmail
    }
}

public enum SyncPhase: Equatable, Sendable {
    case idle
    case waitingForDevice            // 持续监听中
    case connecting
    case listing
    case downloading(String, Int)    // 文件名, 百分比
    case uploading(String, String)   // 文件名, 步骤
    case cleaning
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "空闲"
        case .waitingForDevice: return "等待录音笔"
        case .connecting: return "连接中"
        case .listing: return "读取列表"
        case .downloading(let n, let p): return "下载 \(n) \(p)%"
        case .uploading(let n, let s): return "推送 \(n)：\(s)"
        case .cleaning: return "清理设备"
        case .failed(let e): return "失败：\(e)"
        }
    }
}

extension String {
    /// 空串当没有。上传前定的标题被清空时，应该退回文件名而不是推一个空标题上去。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
