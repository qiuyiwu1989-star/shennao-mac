import LuyinbiCore
import SwiftUI

/// 首次运行引导。
///
/// 之前没有这个：新用户打开只看到一个空表格——不知道要登录、不知道要给蓝牙权限、
/// 不知道要把录音笔开机。三件事全都没有提示，等于把人扔在门口。
struct WelcomeView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AppModel

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 8) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(DS.focusBright)
                Text("深脑").font(DS.heading(24, .bold)).dsHeading()
                    .foregroundStyle(DS.title(scheme == .dark))
                Text("把录音笔里的话，变成深脑里的判断")
                    .font(DS.bodyFont(DS.T.body)).foregroundStyle(DS.body(scheme == .dark))
            }
            .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 12) {
                Text("先登录你的深脑账号").font(DS.bodyFont(DS.T.body, .semibold))
                    .foregroundStyle(DS.title(scheme == .dark))

                TextField("邮箱", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(signIn)

                if let error {
                    Text(error).font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: signIn) {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "登录中" : "登录")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(busy || email.isEmpty || password.isEmpty)

                // 密码去向要写清楚。这是要人输密码的地方，含糊就是不负责任。
                Text("密码只用来换取登录凭证，不会保存在本机，也不会写进日志。")
                    .font(DS.bodyFont(DS.T.meta)).foregroundStyle(DS.body(scheme == .dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320)
            .dsCard(radius: DS.R.xl, padding: 20)

            VStack(alignment: .leading, spacing: 7) {
                stepRow(1, "登录深脑账号", done: false)
                stepRow(2, "允许使用蓝牙", done: false,
                        note: "首次连接录音笔时系统会问")
                stepRow(3, "把录音笔开机放在电脑旁", done: false,
                        note: "它一广播就会自动导入，你不用点任何按钮")
            }
            .frame(width: 320, alignment: .leading)
            .padding(.top, 22)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg(scheme == .dark))
    }

    private func stepRow(_ n: Int, _ text: String, done: Bool, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(DS.bodyFont(DS.T.meta, .semibold))
                .foregroundStyle(DS.body(scheme == .dark))
                .frame(width: 17, height: 17)
                .background(Circle().fill(DS.ink200.opacity(scheme == .dark ? 0.25 : 1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(DS.bodyFont(DS.T.title))
                    .foregroundStyle(DS.title(scheme == .dark))
                if let note {
                    Text(note).font(DS.bodyFont(DS.T.meta))
                        .foregroundStyle(DS.body(scheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func signIn() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            let result = await model.actions.signIn(email, password)
            busy = false
            if let result { error = result } else { password = "" }
        }
    }
}
