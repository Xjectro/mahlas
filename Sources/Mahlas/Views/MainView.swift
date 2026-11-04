import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case session, desktop, setup, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "Oturum"
        case .desktop: "Masaüstü"
        case .setup: "Kurulum"
        case .logs: "Günlükler"
        case .settings: "Ayarlar"
        }
    }

    var icon: String {
        switch self {
        case .session: "person.crop.square.filled.and.at.rectangle"
        case .desktop: "display"
        case .setup: "checklist"
        case .logs: "text.alignleft"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var section: Section = .session

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
                .frame(width: 232)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ZStack {
                Theme.backdrop.opacity(0.55)
                Group {
                    switch section {
                    case .session: SessionView(section: $section)
                    case .desktop: DesktopView()
                    case .setup: SetupView(section: $section)
                    case .logs: LogsView()
                    case .settings: SettingsView()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
                .id(section)
            }
            .animation(.easeOut(duration: 0.2), value: section)
        }
        .background(Theme.bg)
        .overlay(GrainOverlay(opacity: 0.035))
        .onAppear {
            if !session.isReadyToLaunch && session.phase == .idle { section = .setup }
        }
        .onChange(of: session.phase) { _, new in
            if new == .running, section == .setup { section = .desktop }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var session: SessionManager
    @Binding var section: Section
    @State private var hovered: Section?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leave room for the traffic lights
            Spacer().frame(height: 44)

            HStack(spacing: 10) {
                LogoMark().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MAHLAS")
                        .font(Theme.display(17, weight: .black))
                        .foregroundStyle(Theme.ink)
                        .shadow(color: Theme.red.opacity(0.6), radius: 8)
                    Text("Anonim Mac")
                        .font(Theme.body(10.5))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)

            VStack(spacing: 4) {
                ForEach(Section.allCases) { s in
                    Button {
                        if section != s { Synth.shared.select() }
                        section = s
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: s.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 18)
                            Text(s.title).font(Theme.body(13.5, weight: .medium))
                            Spacer()
                            if s == .desktop && session.macVM != nil {
                                StatusDot(color: Theme.ok)
                            }
                            if s == .setup && !session.isReadyToLaunch {
                                Circle().fill(Theme.red).frame(width: 6, height: 6)
                            }
                        }
                        .foregroundStyle(section == s ? Theme.ink : Theme.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(section == s
                                      ? AnyShapeStyle(LinearGradient(colors: [Theme.red.opacity(0.32), Theme.red.opacity(0.08)],
                                                                     startPoint: .leading, endPoint: .trailing))
                                      : AnyShapeStyle(Color.white.opacity(hovered == s ? 0.04 : 0)))
                        )
                        .overlay(alignment: .leading) {
                            if section == s {
                                Capsule().fill(Theme.redHi).frame(width: 3, height: 16)
                                    .shadow(color: Theme.red, radius: 6)
                                    .offset(x: -1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hovered = inside ? s : (hovered == s ? nil : hovered)
                        if inside { Synth.shared.hover() }
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            StatusFooter()
                .padding(14)
        }
        .background(
            LinearGradient(colors: [Theme.bgRaised, Theme.bg], startPoint: .top, endPoint: .bottom)
        )
    }
}

struct StatusFooter: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Mullvad", session.vpnConfigured ? Theme.ok : Theme.red, session.vpnConfigured ? "Hazır" : "Yok")
            row("Ağ geçidi", session.gatewayReady ? Theme.ok : Theme.faint, session.gatewayReady ? "Açık" : "Kapalı")
            row("Tünel", session.tunnelUp ? Theme.ok : Theme.faint, session.exit.map { $0.ip } ?? "—")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    private func row(_ label: String, _ color: Color, _ value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 3)
            Text(label).font(Theme.body(11.5, weight: .medium)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }
}

/// The Mahlas mark: a stylised mask / "M" cut from a crimson shield.
struct LogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Theme.redHi, Theme.red, Theme.redDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.red.opacity(0.6), radius: 8)
            MaskShape()
                .fill(Color.white)
                .padding(6)
        }
    }
}

struct MaskShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        // Domino mask silhouette
        p.move(to: CGPoint(x: x, y: y + h * 0.28))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.36), control: CGPoint(x: x + w * 0.25, y: y + h * 0.12))
        p.addQuadCurve(to: CGPoint(x: x + w, y: y + h * 0.28), control: CGPoint(x: x + w * 0.75, y: y + h * 0.12))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.62, y: y + h * 0.82), control: CGPoint(x: x + w * 1.02, y: y + h * 0.8))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.66), control: CGPoint(x: x + w * 0.54, y: y + h * 0.66))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.38, y: y + h * 0.82), control: CGPoint(x: x + w * 0.46, y: y + h * 0.66))
        p.addQuadCurve(to: CGPoint(x: x, y: y + h * 0.28), control: CGPoint(x: x - w * 0.02, y: y + h * 0.8))
        p.closeSubpath()
        // Eye holes
        p.addEllipse(in: CGRect(x: x + w * 0.16, y: y + h * 0.38, width: w * 0.24, height: h * 0.16))
        p.addEllipse(in: CGRect(x: x + w * 0.60, y: y + h * 0.38, width: w * 0.24, height: h * 0.16))
        return p
    }
}

extension MaskShape {
    /// Even-odd so the eye holes are cut out.
    func fill(_ color: Color) -> some View {
        self.fill(color, style: FillStyle(eoFill: true))
    }
}
