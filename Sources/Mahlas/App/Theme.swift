import SwiftUI
import CoreText

/// Mahlas design tokens — a deep crimson palette on near-black.
enum Theme {
    static let bg        = Color(hex: 0x0A0204)
    static let bgRaised  = Color(hex: 0x14060A)
    static let panel     = Color(hex: 0x1A080D)
    static let stroke    = Color.white.opacity(0.08)
    static let strokeHi  = Color.white.opacity(0.16)

    static let red       = Color(hex: 0xE11D2E)
    static let redHi     = Color(hex: 0xFF3B4E)
    static let redDeep   = Color(hex: 0x7A0A14)
    static let ember     = Color(hex: 0xFF6A3D)

    static let ink       = Color(hex: 0xFFF1F2)
    static let dim       = Color(hex: 0xFFF1F2).opacity(0.62)
    static let faint     = Color(hex: 0xFFF1F2).opacity(0.32)

    static let ok        = Color(hex: 0x34D399)
    static let warn      = Color(hex: 0xFBBF24)

    static let backdrop = RadialGradient(
        colors: [Color(hex: 0x3A0710), Color(hex: 0x16040A), bg],
        center: .center, startRadius: 0, endRadius: 900
    )

    static func display(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
        Fonts.loaded ? .custom("Unbounded", size: size).weight(weight) : .system(size: size, weight: weight, design: .rounded)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum Fonts {
    private(set) static var loaded = false

    static func register() {
        guard !loaded else { return }
        let names = ["Unbounded"]
        var ok = true
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                ok = false; continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        loaded = ok
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Reusable surfaces

struct GlassPanel: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.panel.opacity(0.72))
                    .background(.ultraThinMaterial.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Theme.strokeHi, Theme.stroke], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func glassPanel(padding: CGFloat = 20) -> some View { modifier(GlassPanel(padding: padding)) }
}

struct RedButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(13, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    prominent
                    ? AnyShapeStyle(LinearGradient(colors: [Theme.redHi, Theme.red, Theme.redDeep], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
                )
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(0.18) : Theme.strokeHi, lineWidth: 1))
            .shadow(color: prominent ? Theme.red.opacity(configuration.isPressed ? 0.2 : 0.45) : .clear, radius: 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.body(10.5, weight: .bold))
            .tracking(2.4)
            .foregroundStyle(Theme.faint)
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.3 : 0.6)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Vertical page scroller. In `--snapshot` mode it renders flat, because
/// ImageRenderer can't draw ScrollView contents.
struct PageScroll<Content: View>: View {
    static var flat: Bool { CommandLine.arguments.contains("--snapshot") }
    @ViewBuilder var content: Content

    var body: some View {
        if Self.flat {
            VStack(spacing: 0) { content; Spacer(minLength: 0) }
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}
