import Foundation

/// 「这支录音笔绑定给了哪个账号」——本地记的一份账（spec 019）。
///
/// **为什么需要它。** 2026-09-03 真实事故：账号登错了，三份录音笔文件被
/// 静默同步进了错账号，靠人工查了几个小时才发现。同步本身不会报任何错——
/// 账号对不对，界面上完全没有依据可以核对。这份本地账就是那个依据：
/// 连上一支之前绑过的笔，本地记得它上次绑的是哪个账号，跟当前登录的
/// 账号一比对，对不上就能在同步开始之前拦一次。
///
/// 按 CoreBluetooth 的 `peripheral.identifier` 认设备——这个 UUID 是
/// macOS 给每台配对过的外设生成的、每台 Mac 各不相同（见 spec 019：
/// 同一支笔在安卓端和 Mac 端看到的"ID"根本对不上，没打算统一）。
///
/// 与 TokenStore 同一个存放目录，但**不需要它那样的强权限**——这里存的
/// 是 org id / 邮箱 / 设备名字，不是能直接冒充登录的长期钥匙。
public enum DeviceBinding {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("深脑")
    }
    private static var file: URL { dir.appendingPathComponent("device-bindings.json") }

    public struct Binding: Codable {
        public var orgId: String
        public var email: String
        public var deviceNo: String
    }

    private static func readAll() -> [String: Binding] {
        guard let d = try? Data(contentsOf: file),
              let b = try? JSONDecoder().decode([String: Binding].self, from: d) else { return [:] }
        return b
    }

    private static func writeAll(_ b: [String: Binding]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(b) else { return }
        try? d.write(to: file, options: .atomic)
    }

    public static func binding(for peripheralId: String) -> Binding? { readAll()[peripheralId] }

    public static func bind(_ peripheralId: String, orgId: String, email: String, deviceNo: String) {
        var all = readAll()
        all[peripheralId] = Binding(orgId: orgId, email: email, deviceNo: deviceNo)
        writeAll(all)
    }
}
