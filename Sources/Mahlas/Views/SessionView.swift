import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var session: SessionManager
    @Binding var section: Section

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 22) {
                header
                HeroCard(section: $section)
                if session.phase == .running, let id = session.identity {
                    IdentityGrid(identity: id, exit: session.exit, handshake: session.lastHandshake)
                } else {
                    EmptyIdentity()
                }
                ActivityFeed()
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 36)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Oturum")
            Text("Kimliğin, senin kontrolünde.")
                .font(Theme.display(28, weight: .bold))
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Hero

struct HeroCard: View {
    @EnvironmentObject private var session: SessionManager
    @Binding var section: Section

    var body: some View {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        StatusDot(color: statusColor, pulsing: session.phase == .running || session.phase.isBusy)
                        Text(statusTitle.uppercased())
                            .font(Theme.body(11, weight: .bold))
                            .tracking(2.2)
                            .foregroundStyle(statusColor)
                    }

                    Text(headline)
                        .font(Theme.display(session.identity == nil ? 34 : 40, weight: .black))
                        .foregroundStyle(Theme.ink)
                        .shadow(color: Theme.red.opacity(0.5), radius: 18)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())

                    Text(subline)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)

                    actions.padding(.top, 6)
                }
                Spacer(minLength: 0)
                if session.phase == .running, let id = session.identity {
                    LocationBadge(location: id.location, exit: session.exit)
                }
            }
            .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A0710), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .topTrailing) {
            // Glow, kept out of layout so it never sizes the card
            Circle()
                .fill(RadialGradient(colors: [Theme.red.opacity(glow), .clear], center: .center, startRadius: 0, endRadius: 260))
                .frame(width: 520, height: 520)
                .offset(x: 140, y: -220)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.red.opacity(0.55), Theme.stroke], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: Theme.red.opacity(0.18), radius: 30, y: 10)
    }

    private var glow: Double { session.phase == .running ? 0.45 : 0.22 }

    private var statusColor: Color {
        switch session.phase {
        case .running: session.tunnelUp ? Theme.ok : Theme.warn
        case .working, .downloading, .installing, .firstSetup: Theme.warn
        case .error: Theme.redHi
        case .idle: Theme.faint
        }
    }

    private var statusTitle: String {
        switch session.phase {
        case .running: session.tunnelUp ? "Aktif · Şifreli" : "Aktif · Tünel doğrulanıyor"
        case .working(let s): s
        case .downloading: "macOS indiriliyor"
        case .installing: "macOS kuruluyor"
        case .firstSetup: "İlk açılış"
        case .error: "Hata"
        case .idle: session.isReadyToLaunch ? "Hazır" : "Kurulum gerekli"
        }
    }

    private var headline: String {
        if session.phase == .running, let id = session.identity { return id.computerName }
        if session.phase == .firstSetup { return "Altın imajı hazırla." }
        return session.isReadyToLaunch ? "Yeni bir Mac ol." : "Önce kurulum."
    }

    private var subline: String {
        switch session.phase {
        case .error(let msg): return msg
        case .firstSetup:
            return "Sanal Mac'te Kurulum Yardımcısı'nı tamamla ve Mahlas ajanını kur. Mac kapanınca imaj otomatik mühürlenir."
        default: break
        }
        if session.phase == .running, let id = session.identity, let start = session.sessionStarted {
            return "\(id.model) · \(id.location.displayName) · \(start.formatted(.relative(presentation: .named))) açıldı"
        }
        return session.isReadyToLaunch
            ? "Her başlatışta temiz bir macOS, yeni makine kimliği ve farklı bir Mullvad çıkış noktası. Kapattığında disk tamamen silinir."
            : "Mullvad'ı bağlamak ve macOS imajını hazırlamak için Kurulum sekmesine geç."
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch session.phase {
            case .running:
                Button { section = .desktop } label: { Label("Masaüstünü Aç", systemImage: "display") }
                    .buttonStyle(RedButtonStyle())
                Button { Task { await session.newIdentity() } } label: { Label("Yeni Kimlik", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(RedButtonStyle(prominent: false))
                Button { Task { await session.stopSession() } } label: { Label("Kapat ve Sil", systemImage: "power") }
                    .buttonStyle(RedButtonStyle(prominent: false))
            case .firstSetup:
                Button { section = .desktop } label: { Label("Sanal Mac'e Git", systemImage: "display") }
                    .buttonStyle(RedButtonStyle())
                Button { section = .setup } label: { Label("Talimatlar", systemImage: "list.number") }
                    .buttonStyle(RedButtonStyle(prominent: false))
            case .working, .downloading, .installing:
                ProgressView().controlSize(.small).tint(Theme.red)
            case .idle, .error:
                if session.isReadyToLaunch {
                    Button { Task { await session.startSession() } } label: { Label("Yeni Kimlikle Başlat", systemImage: "bolt.fill") }
                        .buttonStyle(RedButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button { section = .setup } label: { Label("Kuruluma Git", systemImage: "arrow.right") }
                        .buttonStyle(RedButtonStyle())
                }
            }
        }
    }
}

struct LocationBadge: View {
    let location: ExitLocation
    let exit: Mullvad.ExitCheck?

    var body: some View {
        VStack(spacing: 10) {
            Text(location.flag).font(.system(size: 54))
                .shadow(color: .black.opacity(0.4), radius: 8)
            Text(location.displayName)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Image(systemName: exit?.mullvad_exit_ip == true ? "lock.shield.fill" : "lock.open")
                Text(exit?.ip ?? "Tünel doğrulanıyor…")
            }
            .font(Theme.mono(11))
            .foregroundStyle(exit?.mullvad_exit_ip == true ? Theme.ok : Theme.faint)
        }
        .frame(width: 210)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke))
    }
}

// MARK: - Identity

struct IdentityGrid: View {
    let identity: MachineIdentity
    let exit: Mullvad.ExitCheck?
    let handshake: Date?

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Bu oturumun kimliği")
            LazyVGrid(columns: columns, spacing: 14) {
                IdentityTile(icon: "laptopcomputer", label: "Bilgisayar adı", value: identity.computerName)
                IdentityTile(icon: "network", label: "Yerel ağ adı", value: identity.localHostName, mono: true)
                IdentityTile(icon: "barcode", label: "Makine kimliği (seri/ECID)", value: identity.machineID, mono: true)
                IdentityTile(icon: "cable.connector", label: "MAC adresi", value: identity.macAddress, mono: true)
                IdentityTile(icon: "cpu", label: "Kaynak", value: "\(identity.cpuCores) çekirdek · \(identity.ramGB) GB RAM")
                IdentityTile(icon: "display", label: "Ekran", value: identity.display.label)
                IdentityTile(icon: "clock", label: "Saat dilimi", value: identity.location.timeZone)
                IdentityTile(icon: "server.rack", label: "Mullvad sunucusu", value: identity.relay ?? "—", mono: true)
                IdentityTile(icon: "globe.europe.africa.fill", label: "Görünen IP",
                             value: exit.map { "\($0.ip)\($0.organization.map { " · " + $0 } ?? "")" } ?? "Doğrulanıyor…", mono: true)
                IdentityTile(icon: "lock.shield", label: "Son WireGuard el sıkışması",
                             value: handshake.map { $0.formatted(date: .omitted, time: .standard) } ?? "Bekleniyor…")
            }
        }
    }
}

struct IdentityTile: View {
    let icon: String
    let label: String
    let value: String
    var mono = false
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Synth.shared.select()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.redHi)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.red.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(copied ? "Kopyalandı" : label)
                        .font(Theme.body(11, weight: .medium))
                        .foregroundStyle(copied ? Theme.ok : Theme.faint)
                    Text(value)
                        .font(mono ? Theme.mono(12.5, weight: .medium) : Theme.body(13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(mono ? 1 : 2)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .glassPanel(padding: 14)
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.red.opacity(hover ? 0.4 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Kopyalamak için tıkla")
    }
}

struct EmptyIdentity: View {
    var body: some View {
        HStack(spacing: 18) {
            ForEach(["laptopcomputer", "barcode", "cable.connector", "globe.europe.africa.fill"], id: \.self) { icon in
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Aktif kimlik yok")
                    .font(Theme.body(14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Başlattığında bilgisayar adı, makine kimliği (seri no/ECID), MAC adresi, işlemci/bellek, ekran çözünürlüğü, saat dilimi ve Mullvad çıkış sunucusu rastgele seçilir. Oturum kapanınca disk tamamen silinir.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

struct ActivityFeed: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Etkinlik")
            VStack(alignment: .leading, spacing: 8) {
                if session.activity.isEmpty {
                    Text("Henüz etkinlik yok.")
                        .font(Theme.body(12.5)).foregroundStyle(Theme.faint)
                }
                ForEach(session.activity.suffix(8).reversed()) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(line.date.formatted(date: .omitted, time: .standard))
                            .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                        Text(line.text)
                            .font(Theme.body(12.5))
                            .foregroundStyle(line.isError ? Theme.redHi : Theme.dim)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(padding: 16)
        }
    }
}
