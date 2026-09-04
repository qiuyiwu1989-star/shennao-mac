import LuyinbiCore
import SwiftUI

/// 待办分类。
///
/// 为什么要有：稳态下绝大多数录音不需要你管——已进深脑、转写好了、没事。
/// 把它们和真正卡住的平铺在一张表里，8 条时看着还行，80 条时你就再也找不到该处理的那几条。
/// 所以先分类，再显示：**待办区在没事的时候应该是空的**。
enum Triage {
    enum Kind: Int, CaseIterable {
        /// 落了盘、还没轮到它上传。**不是故障**，不该进待办。
        case queued
        case failed        // 转写失败
        case needsSpeaker  // 转写好了但没指认说话人
        case stuck         // 上传失败/卡住
        case working       // 正在搬运
        case skipped       // 太短，按规则只落盘没推
        case pendingDel    // 排队等着从设备删
        case done          // 一切正常

        var title: String {
            switch self {
            case .failed:       return "转写失败"
            case .needsSpeaker: return "等你认人"
            case .stuck:        return "推送卡住"
            case .queued:       return "排队等推送"
            case .working:      return "正在进行"
            case .skipped:      return "太短未推送"
            case .pendingDel:   return "等着从设备删"
            case .done:         return "已完成"
            }
        }
        var icon: String {
            switch self {
            case .failed:       return "exclamationmark.triangle.fill"
            case .needsSpeaker: return "person.2.wave.2.fill"
            case .stuck:        return "arrow.triangle.2.circlepath"
            case .queued:       return "arrow.up.circle"
            case .working:      return "arrow.down.circle"
            case .skipped:      return "clock.badge.questionmark"
            case .pendingDel:   return "trash"
            case .done:         return "checkmark.circle.fill"
            }
        }
        var tone: Color {
            switch self {
            case .failed:       return DS.bad
            case .needsSpeaker: return DS.iris
            case .stuck:        return DS.warn
            case .working:      return DS.focusBright
            // 排队和「正在进行」同色：它们是同一件事的两个阶段，不是两种状态。
            case .queued:       return DS.focusBright
            case .skipped:      return DS.ink300
            case .pendingDel:   return DS.warn
            case .done:         return DS.ok
            }
        }
        /// 一句话告诉人「该做什么」，不是只报状态。
        var advice: String {
            switch self {
            case .failed:       return "点开看原因，能重推的会给按钮"
            case .needsSpeaker: return "指认之后再让深脑分析，洞察里才是真名"
            case .stuck:        return "多半是网络或登录过期，可以重推"
            case .queued:       return "在上传队列里等着，轮到就推"
            case .working:      return "正在搬，等着就行"
            case .skipped:      return "本地留着了，需要的话可以手动推给深脑"
            case .pendingDel:   return "设备下次连上就删"
            case .done:         return ""
            }
        }
    }

    static func classify(_ item: RecordingItem, busyBase: String?) -> Kind {
        if item.pendingDeviceDelete { return .pendingDel }
        if item.base == busyBase { return .working }
        // 太短是「按你定的规则跳过」，不是故障——不能混进待办里让人以为出了问题
        if item.skippedShortSeconds != nil && !item.inBrain { return .skipped }
        if item.brainStatus == "failed" { return .failed }
        if item.inBrain && item.unconfirmedSpeakers > 0 { return .needsSpeaker }
        if item.lastError != nil && !item.inBrain { return .stuck }
        // 落了盘却没 sessionId 有两种：**还没轮到**、和**试过推不上去**。
        // 之前一律算「推送卡住」——刚下完的文件当场被标成故障，还进了待办计数。
        // 队列本来就记着 attempts，只是从没传到这儿来。
        if item.onDisk && item.sessionId == nil {
            return item.uploadAttempts > 0 ? .stuck : .queued
        }
        if item.inBrain { return .done }
        return .working
    }

    /// 需要人动手的三类。稳态下这三类都是空的。
    static let actionable: [Kind] = [.failed, .needsSpeaker, .stuck]
}
