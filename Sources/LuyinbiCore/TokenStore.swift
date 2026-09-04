import Foundation

/// 登录凭证的存放。
///
/// **为什么不用钥匙串**：钥匙串的授权绑代码签名身份，而 ad-hoc 签名的身份来自二进制哈希——
/// 每改一行代码重新部署，身份就换一个，macOS 每次都当陌生程序，弹框问你的登录密码。
/// 点「始终允许」也没用，下次部署又是新身份。开发期间这是没完没了的。
///
/// **代价说清楚**：文件权限 0600，只有你这个用户能读。这比钥匙串弱——
/// 钥匙串在锁定时是加密的，而这个文件只要你登录了就能被以你身份运行的任何程序读到。
/// 对一个自用工具，这个折中我认为划算；真要发给团队，届时用正式签名证书 + 钥匙串。
///
/// 存的是 refresh token 不是密码：泄露了可以在深脑那边吊销，密码从头到尾不落盘。
public enum TokenStore {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("深脑")
    }
    private static var file: URL { dir.appendingPathComponent("credentials.json") }

    private struct Blob: Codable {
        var refreshToken: String?
        var email: String?
        var orgId: String?
    }

    private static func read() -> Blob {
        guard let d = try? Data(contentsOf: file),
              let b = try? JSONDecoder().decode(Blob.self, from: d) else { return Blob() }
        return b
    }

    private static func write(_ b: Blob) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(b) else { return }
        try? d.write(to: file, options: .atomic)
        // 0600：别让同机器上的其他用户读到
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func get(_ key: String = "refresh_token") -> String? {
        let b = read()
        switch key {
        case "email":   return b.email
        case "org_id":  return b.orgId
        default:        return b.refreshToken
        }
    }

    @discardableResult
    public static func set(_ value: String, _ key: String = "refresh_token") -> Bool {
        var b = read()
        switch key {
        case "email":   b.email = value
        case "org_id":  b.orgId = value
        default:        b.refreshToken = value
        }
        write(b)
        return true
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    public static var path: String { file.path }
}
