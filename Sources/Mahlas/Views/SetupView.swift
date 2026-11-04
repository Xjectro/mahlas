import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject private var session: SessionManager
    @Binding var section: Section
    @State private var account = ""
    @State private var manual = false
    @State private var manualKey = ""
    @State private var manualAddress = ""
    @State private var pickIPSW = false

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Kurulum")
                    Text("Üç adımda hazır.")
                        .font(Theme.display(28, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Bu adımlar yalnızca bir kez yapılır. Sonrasında her başlatış tek tıktır.")
                        .font(Theme.body(13.5)).foregroundStyle(Theme.dim)
                }
                .padding(.bottom, 6)

                if !session.isAppleSilicon {
                    Note(icon: "cpu", color: Theme.redHi, text: "Mahlas, macOS sanal makineleri için Apple Silicon (M serisi) bir Mac gerektirir.")
                }

                mullvadStep
                imageStep
                firstBootStep

                if case .error(let msg) = session.phase {
                    HStack(alignment: .top) {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.body(12.5))
                            .foregroundStyle(Theme.redHi)
                        Spacer()
                        Button("Tamam") { session.dismissError() }.buttonStyle(RedButtonStyle(prominent: false))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.red.opacity(0.12)))
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 36)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $pickIPSW, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data]) { result in
            if case .success(let url) = result {
                let ok = url.startAccessingSecurityScopedResource()
                session.useLocalIPSW(url)
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: Steps

    private var mullvadStep: some View {
        StepCard(number: 1, title: "Mullvad VPN", done: session.vpnConfigured,
                 subtitle: session.vpnConfigured
                    ? "WireGuard anahtarı Keychain'de. Sanal Mac'in tüm trafiği Mullvad tünelinden geçer."
                    : "Sanal Mac internete yalnızca Mullvad WireGuard tüneli üzerinden çıkar. Ana Mac'inin trafiği etkilenmez.") {
            VStack(alignment: .leading, spacing: 12) {
                if session.vpnConfigured {
                    HStack {
                        if let exp = session.accountExpiry {
                            Text("Hesap bitiş: \(exp.formatted(date: .abbreviated, time: .omitted))")
                                .font(Theme.body(12.5)).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        Button("Bilgileri sil") { session.signOutMullvad() }
                            .buttonStyle(RedButtonStyle(prominent: false))
                    }
                } else if manual {
                    field("WireGuard özel anahtarı (PrivateKey)", text: $manualKey, secure: true)
                    field("Adres (Address), ör. 10.68.12.34/32", text: $manualAddress)
                    HStack {
                        Button("Kaydet") { session.setManualWireGuard(privateKey: manualKey, address: manualAddress) }
                            .buttonStyle(RedButtonStyle())
                            .disabled(manualKey.isEmpty || manualAddress.isEmpty)
                        Button("Hesap numarasıyla bağlan") { manual = false }
                            .buttonStyle(RedButtonStyle(prominent: false))
                    }
                    Text("mullvad.net → Hesap → WireGuard yapılandırması bölümünden oluşturduğun .conf dosyasındaki değerler.")
                        .font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                } else {
                    field("Mullvad hesap numarası (16 hane)", text: $account, secure: true)
                    HStack {
                        Button { Task { await session.connectMullvad(account: account) } } label: {
                            Label("Bağlan", systemImage: "lock.shield.fill")
                        }
                        .buttonStyle(RedButtonStyle())
                        .disabled(Mullvad.normalize(account: account).count != 16 || session.phase.isBusy)
                        Button("WireGuard bilgilerini elle gir") { manual = true }
                            .buttonStyle(RedButtonStyle(prominent: false))
                    }
                    Text("Mahlas yeni bir WireGuard anahtarı üretir ve Mullvad hesabına cihaz olarak ekler. Hesap numarası yalnızca Keychain'de saklanır.")
                        .font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private var imageStep: some View {
        StepCard(number: 2, title: "macOS imajı", done: session.installed,
                 subtitle: session.installed
                    ? "macOS sanal diske kuruldu."
                    : "Apple'ın resmi macOS geri yükleme imajı (~17 GB) indirilir ve sanal diske kurulur.") {
            VStack(alignment: .leading, spacing: 12) {
                switch session.phase {
                case .downloading(let p):
                    ProgressRow(title: "İndiriliyor", value: p)
                case .installing(let p):
                    ProgressRow(title: "Kuruluyor", value: p)
                default:
                    if !session.installed {
                        HStack {
                            if session.ipswReady {
                                Button { Task { await session.installMacOS() } } label: { Label("macOS'u kur", systemImage: "square.and.arrow.down.on.square") }
                                    .buttonStyle(RedButtonStyle())
                                    .disabled(session.phase.isBusy || !session.isAppleSilicon)
                            } else {
                                Button { Task { await session.downloadMacOS() } } label: { Label("Güncel macOS'u indir", systemImage: "arrow.down.circle") }
                                    .buttonStyle(RedButtonStyle())
                                    .disabled(session.phase.isBusy || !session.isAppleSilicon)
                            }
                            Button("IPSW dosyası seç…") { pickIPSW = true }
                                .buttonStyle(RedButtonStyle(prominent: false))
                                .disabled(session.phase.isBusy)
                        }
                        Text("Disk: \(session.diskGB) GB (seyrek, yalnızca kullanılan alanı kaplar). Ayarlar'dan değiştirilebilir.")
                            .font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                    }
                }
            }
        }
    }

    private var firstBootStep: some View {
        StepCard(number: 3, title: "İlk açılış ve mühürleme", done: session.goldenReady,
                 subtitle: session.goldenReady
                    ? "Altın imaj mühürlü. Her oturum bu imajın anlık bir klonundan açılır ve kapanınca silinir."
                    : "Sanal Mac bir kez açılır: hesabını oluşturur, Mahlas ajanını kurarsın. Sonra imaj mühürlenir.") {
            VStack(alignment: .leading, spacing: 12) {
                if session.phase == .firstSetup {
                    VStack(alignment: .leading, spacing: 8) {
                        instruction(1, "Kurulum Yardımcısı'nı tamamla. Apple hesabıyla giriş yapma; konum servislerini ve analizleri kapat.")
                        instruction(2, "Finder → kenar çubuğunda \"My Shared Files\" (Paylaşılan Dosyalarım) klasörünü aç.")
                        instruction(3, "\"\(GuestAgent.installerName)\" dosyasına çift tıkla ve parolanı gir.")
                        instruction(4, "Sanal Mac kendiliğinden kapanır, Mahlas imajı mühürler.")
                    }
                    Button { section = .desktop } label: { Label("Sanal Mac'e git", systemImage: "display") }
                        .buttonStyle(RedButtonStyle())
                } else if !session.goldenReady {
                    Button { Task { await session.beginFirstSetup(); section = .desktop } } label: {
                        Label("İlk açılışı başlat", systemImage: "power")
                    }
                    .buttonStyle(RedButtonStyle())
                    .disabled(!session.installed || !session.vpnConfigured || session.phase.isBusy)
                    Text("Ağ trafiği ilk açılışta da Mullvad ağ geçidinden geçer.")
                        .font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private func instruction(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(Theme.mono(11, weight: .bold)).foregroundStyle(Theme.redHi)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.red.opacity(0.15)))
            Text(text).font(Theme.body(12.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
        }
        .textFieldStyle(.plain)
        .font(Theme.mono(13))
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.strokeHi))
    }
}

struct ProgressRow: View {
    let title: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Text(value.formatted(.percent.precision(.fractionLength(0)))).font(Theme.mono(12)).foregroundStyle(Theme.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.redHi, Theme.red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * value))
                        .shadow(color: Theme.red.opacity(0.6), radius: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle()
                    .fill(done ? AnyShapeStyle(Theme.ok.opacity(0.15)) : AnyShapeStyle(LinearGradient(colors: [Theme.redHi, Theme.redDeep], startPoint: .top, endPoint: .bottom)))
                    .frame(width: 38, height: 38)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ok)
                } else {
                    Text("\(number)").font(Theme.display(15, weight: .bold)).foregroundStyle(.white)
                }
            }
            .shadow(color: done ? .clear : Theme.red.opacity(0.5), radius: 10)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.display(16, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(Theme.body(12.5)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            Spacer(minLength: 0)
        }
        .glassPanel(padding: 22)
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(done ? Theme.ok.opacity(0.25) : .clear))
    }
}

struct Note: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12, weight: .semibold)).padding(.top, 1)
            Text(text).font(Theme.body(12.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.2)))
    }
}
