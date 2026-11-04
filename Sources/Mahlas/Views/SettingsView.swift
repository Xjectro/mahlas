import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionManager

    @AppStorage("rotateKeyEachSession") private var rotateKey = true
    @AppStorage("randomLocation") private var randomLocation = true
    @AppStorage("fixedLocationIndex") private var fixedLocationIndex = 0
    @AppStorage("diskGB") private var diskGB = 80
    @AppStorage("mahlas.muted") private var muted = false
    @State private var confirmReset = false

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Ayarlar")
                    Text("İnce ayar.")
                        .font(Theme.display(28, weight: .bold)).foregroundStyle(Theme.ink)
                }

                group("Kimlik ve gizlilik") {
                    toggle("Her oturumda WireGuard anahtarını yenile",
                           "Oturumlar Mullvad tarafında aynı anahtarla ilişkilendirilemez.", $rotateKey)
                    toggle("Rastgele çıkış konumu",
                           "Her oturum farklı bir şehirden internete çıkar; saat dilimi buna uyar.", $randomLocation)
                    if !randomLocation {
                        row("Sabit konum") {
                            Picker("", selection: $fixedLocationIndex) {
                                ForEach(Array(Locations.all.enumerated()), id: \.offset) { i, l in
                                    Text("\(l.flag)  \(l.displayName)").tag(i)
                                }
                            }
                            .labelsHidden().frame(width: 260)
                        }
                    }
                }

                group("Güvenlik modeli") {
                    bullet("lock.shield.fill", "Sanal Mac'in tek ağ çıkışı Mullvad WireGuard tünelidir. Tünel düşerse internet kesilir (kill switch); IPv6 kapalıdır.")
                    bullet("network.slash", "DNS yalnızca Mullvad'ın tünel içi sunucusuna gider. Sanal Mac, ana Mac'inin yerel ağını göremez.")
                    bullet("trash.fill", "Her oturum altın imajın anlık klonudur; kapatınca disk silinir.")
                    bullet("mic.slash.fill", "Mikrofon, kamera ve USB yoktur. Paylaşılan klasör oturumlarda salt okunurdur.")
                    bullet("key.fill", "WireGuard özel anahtarı diske yazılmaz; Keychain'den yalnızca ağ geçidinin belleğine geçer.")
                }

                group("macOS imajı") {
                    row("Disk boyutu") {
                        Picker("", selection: $diskGB) {
                            ForEach([64, 80, 128, 192], id: \.self) { Text("\($0) GB").tag($0) }
                        }.labelsHidden().frame(width: 160)
                    }
                    .disabled(session.installed)
                    row("İndirilen IPSW dosyası") {
                        Button("Sil") { session.deleteIPSW() }
                            .buttonStyle(RedButtonStyle(prominent: false))
                            .disabled(!session.ipswReady || session.phase.isBusy)
                    }
                }

                group("Uygulama") {
                    toggle("Sesleri kapat", "Açılış ve arayüz sesleri.", $muted)
                    row("Veri klasörü") {
                        Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
                            .buttonStyle(RedButtonStyle(prominent: false))
                    }
                    row("Ağ geçidi dosyalarını yeniden indir") {
                        Button("Yenile") { GatewayVM.resetAssets(); session.log("Ağ geçidi dosyaları bir sonraki oturumda yeniden indirilecek") }
                            .buttonStyle(RedButtonStyle(prominent: false))
                            .disabled(session.phase.hasMachine || session.phase.isBusy)
                    }
                }

                group("Tehlikeli bölge") {
                    row("macOS imajını sıfırla") {
                        Button("Sıfırla") { confirmReset = true }
                            .buttonStyle(RedButtonStyle())
                            .disabled(!session.installed || session.phase.isBusy)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 36)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("macOS imajı silinsin mi?", isPresented: $confirmReset) {
            Button("Sil ve sıfırla", role: .destructive) { Task { await session.resetGolden() } }
        } message: {
            Text("Kurulu sanal Mac diski kalıcı olarak silinir. Kurulumu ve ilk açılışı yeniden yapman gerekir.")
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.redHi).font(.system(size: 12, weight: .semibold)).frame(width: 18)
            Text(text).font(Theme.body(12.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.display(14, weight: .bold)).foregroundStyle(Theme.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(padding: 22)
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(13.5, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.body(12)).foregroundStyle(Theme.faint)
            }
            Spacer()
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.red)
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).font(Theme.body(13.5, weight: .medium)).foregroundStyle(Theme.ink)
            Spacer()
            content()
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Günlükler")
                Text("Kaputun altı.").font(Theme.display(28, weight: .bold)).foregroundStyle(Theme.ink)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if session.activity.isEmpty {
                            Text("Henüz kayıt yok.").foregroundStyle(Theme.faint)
                        }
                        ForEach(session.activity) { line in
                            Text("\(line.date.formatted(date: .omitted, time: .standard))  \(line.text)")
                                .foregroundStyle(line.isError ? Theme.redHi : Theme.dim)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(Theme.mono(11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .onChange(of: session.activity.count) { proxy.scrollTo("end") }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 24)
    }
}
