import SwiftUI

/// 深脑设计系统在 macOS 侧的落点。
///
/// 数值不是我拍脑袋定的，是从深脑网页端 `apps/web/tailwind.config.ts` 抄过来的，
/// 目的是两端看起来是同一个产品。改配色请回去改那份 config，再同步到这里。
enum DS {

    // MARK: - 中性色（ink：冷调灰阶）
    static let ink50  = Color(hex: 0xf4f5f8)   // 造物云「中性冷灰」底色
    static let ink100 = Color(hex: 0xe8eaef)
    static let ink200 = Color(hex: 0xd3d7e0)
    static let ink300 = Color(hex: 0x9096a4)
    /// 次要文字专用。ink300 在白底只有 2.96:1，达不到 WCAG AA 的 4.5:1，
    /// 而它承载着列表时长、状态、「未连接」、空态提示——App 里一多半的字。
    /// 这一档 4.54:1 刚过线，又比 ink400 正文浅，层级还在。
    static let muted  = Color(hex: 0x6f7688)
    /// 信息性图形（波形条、进度轨）专用，白底 3.12:1，过 1.4.11 的 3:1。
    /// 别拿 ink200(1.44:1) 画有含义的图形——那等于没画。
    static let glyph  = Color(hex: 0x8b92a1)
    static let ink400 = Color(hex: 0x646b7d)
    static let ink600 = Color(hex: 0x3f4654)
    static let ink700 = Color(hex: 0x2a2f3a)
    static let ink800 = Color(hex: 0x1c1c1e)
    // 造物云「冷墨」：设计系统明说文字不用纯黑，#16181F 白底 17.73:1，够黑也不刺目
    static let ink900 = Color(hex: 0x16181f)

    // MARK: - 强调色（蓝 + 紫，深脑的招牌配对）
    // 主色对齐造物云设计系统（design-system.html）：一个紫蓝主色族，不再蓝紫并存。
    //
    // 之前 App 里 focus 蓝 #0052d9 和 iris 紫 #6725ff 同时当主色，两者互相对比
    // 只有 1.02:1——放在一起看是两种"主色"在打架，这就是「配色不统一」的来源。
    //
    // 品牌主色 #7B80FF 白底只有 3.29:1，扛不住文字和实心按钮，只能做非文字；
    // 承重的活交给深一档 #5A4FE6（5.68:1，白字压其上也是 5.68:1）。
    static let focus       = Color(hex: 0x5A4FE6)   // 链接/小字/实心按钮底，AA 达标
    static let focusFill   = Color(hex: 0x5A4FE6)
    static let focusBright = Color(hex: 0x7B80FF)   // 品牌主色，只做选中条/辉光/图标等非文字
    static let focusSoft   = Color(hex: 0xeeeeff)
    // iris 曾是第二套主色。现在收进同一族：它只用在「待认人」这一种状态上，
    // 与主色同色相、更深一档，读起来是"同一个系统里更要紧的那档"，不是另一种品牌色。
    static let iris        = Color(hex: 0x5A4FE6)
    static let iris400     = Color(hex: 0x7B80FF)
    static let irisSoft    = Color(hex: 0xeeeeff)

    // MARK: - 语义色
    static let ok   = Color(hex: 0x16a34a)
    static let warn = Color(hex: 0xd97706)
    static let bad  = Color(hex: 0xdc2626)

    /// 深浅色自适应：网页端只有浅色，深色这边按同一套色相往暗里推，别引入新色相。
    /// 深色底不用纯黑。纯黑配高饱和色会显得对比过强、发廉价，
    /// 也让长时间读转写更累。抬到 #16181c 一档，观感立刻沉下来。
    static func bg(_ dark: Bool) -> Color { dark ? Color(hex: 0x16181c) : ink50 }
    static func surface(_ dark: Bool) -> Color { dark ? Color(hex: 0x1d2026) : .white }
    /// 比 surface 低一档的凹面。给「附属信息条」用——链路状态这类东西
    /// 不该和正文抢同一个平面，压下去一档就自然退到背景里。
    static func sunkenBg(_ dark: Bool) -> Color { dark ? Color(hex: 0x16181c) : Color(hex: 0xf4f5f8) }
    static func border(_ dark: Bool) -> Color { dark ? Color(hex: 0x2c313a) : ink200 }
    static func title(_ dark: Bool) -> Color { dark ? Color(hex: 0xe8eaef) : ink900 }
    static func body(_ dark: Bool) -> Color { dark ? Color(hex: 0x9096a4) : ink400 }

    // MARK: - 圆角（比常规大一档，网页端 config 里特意调圆润过）
    enum R {
        static let sm: CGFloat = 6
        static let base: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
    }

    // MARK: - 字体
    /// 网页端标题用 Outfit（几何无衬线）+ 紧字距。macOS 上没有这个字体，
    /// 不为一个图标级差异去打包字体文件；改用系统字并保留 -0.015em 的字距，
    /// 观感最接近。正文同理对齐 Plus Jakarta Sans 的中性感。
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    static let headingTracking: CGFloat = -0.4
    /// 字号阶梯。整体比之前提了一档。
    ///
    /// 之前全 App 压在 10–12pt：Mac 上确实"能放下更多"，但代价是**什么都不显目**——
    /// 一屏灰蒙蒙的小字，标题、时长、状态一样大，眼睛没有落点。
    /// 造物云设计系统的 Body 是 15px，妙记也在这个量级。
    ///
    /// 每一档的用途写在这里，别再靠记数字：
    enum T {
        /// 11 · 角标、墙上时钟这类"看一眼就够"的
        static let micro: CGFloat = 11
        /// 13 · 次要信息：时长、状态、说明
        static let meta: CGFloat = 13
        /// 14 · 列表标题
        static let title: CGFloat = 14
        /// 15 · 正文与按钮
        static let body: CGFloat = 15
        /// 17 · 页面标题
        static let head: CGFloat = 17
    }

    static func bodyFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

/// 深脑风格的卡片：白面 + 细边 + 大圆角 + 一层很淡的大阴影。
struct DSCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = DS.R.xl
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.surface(dark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DS.border(dark), lineWidth: 1)
            )
            // 网页端 shadow-soft：0 32px 54px rgba(0,0,0,0.05)。大而淡，不是投影感。
            .shadow(color: .black.opacity(dark ? 0.35 : 0.05), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func dsCard(radius: CGFloat = DS.R.xl, padding: CGFloat = 16) -> some View {
        modifier(DSCard(radius: radius, padding: padding))
    }
    /// 标题统一收字距，对齐网页端 letter-spacing: -0.015em
    func dsHeading() -> some View { tracking(DS.headingTracking) }
}

// MARK: - 按钮

/// 深脑的主按钮：药丸形 + 蓝紫渐变 + 白字。
/// 网页端 borderRadius.pill = 980px，就是完全的胶囊，不是大圆角——这是它最强的视觉签名之一。
struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.bodyFont(DS.T.body, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [DS.focusFill, DS.iris],
                                   startPoint: .leading, endPoint: .trailing)
                )
            )
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            // 网页端 shadow-glow-blue：按钮底下有一层蓝色辉光，不是灰色投影
            .shadow(color: DS.focusBright.opacity(enabled ? 0.30 : 0), radius: 8, x: 0, y: 3)
            .contentShape(Capsule())
    }
}

/// 次按钮：同样是胶囊，白底细边。
struct DSSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        configuration.label
            .font(DS.bodyFont(DS.T.body, .medium))
            .foregroundStyle(enabled ? DS.title(dark) : DS.ink300)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(DS.surface(dark)))
            .overlay(Capsule().stroke(DS.border(dark), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

extension View {
    /// 标题用蓝紫渐变——网页端主标题就是这么处理的。
    func dsGradientText() -> some View {
        foregroundStyle(LinearGradient(colors: [DS.focusFill, DS.iris],
                                       startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - 说话人配色

/// 每个说话人一个稳定颜色。
///
/// 为什么需要：读一段多人转写时，最要紧的信息是「谁在说」。
/// 如果三个说话人的名字只有文字不同，眼睛必须逐字读才能分辨——
/// 一个色点能让人在扫视中就分清楚，这是转写区最该有的可供性。
///
/// 颜色按标签稳定分配（说话人1 永远是同一个颜色），不随排序变化——
/// 否则重新加载一次，颜色全变，之前建立的对应关系就废了。
enum SpeakerPalette {
    private static let colors: [Color] = [
        Color(hex: 0x2563eb),   // 蓝
        Color(hex: 0x16a34a),   // 绿
        Color(hex: 0xd97706),   // 琥珀
        Color(hex: 0x9333ea),   // 紫
        Color(hex: 0x0891b2),   // 青
        Color(hex: 0xdc2626),   // 红
    ]

    /// 从标签里取尾号，稳定映射到颜色。取不到号就用哈希兜底。
    static func color(for label: String) -> Color {
        if let n = label.compactMap({ $0.wholeNumberValue }).last {
            return colors[n % colors.count]
        }
        return colors[abs(label.hashValue) % colors.count]
    }

    /// 圆头像里显示什么。「说话人1」取「1」比取「说」有信息量得多。
    static func initial(for label: String, name: String?) -> String {
        if let name, !name.isEmpty { return String(name.prefix(1)) }
        if let n = label.compactMap({ $0.wholeNumberValue }).last { return "\(n)" }
        return String(label.prefix(1))
    }
}

/// 让「哪个是主按钮」可以随状态换。SwiftUI 的 buttonStyle 要求编译期定类型，
/// 两个分支给不同 style 会类型不符；装箱一层就行。
struct AnyButtonStyleBox: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
