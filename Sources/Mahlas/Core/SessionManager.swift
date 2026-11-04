import Foundation
import SwiftUI
import Virtualization

@MainActor
final class SessionManager: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum Phase: Equatable {
        case idle
        case working(String)
        case downloading(Double)
        case installing(Double)
        case firstSetup
        case running
        case error(String)

        var isBusy: Bool {
            switch self { case .working, .downloading, .installing: true; default: false }
        }
        var hasMachine: Bool { self == .running || self == .firstSetup }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        var isError = false
    }

    // MARK: Published state

    @Published var phase: Phase = .idle
    @Published var vpnConfigured = WireGuardCredentials.load() != nil
    @Published var accountExpiry: Date?
    @Published var ipswReady = FileManager.default.fileExists(atPath: Paths.ipsw.path)
    @Published var installed = FileManager.default.fileExists(atPath: MacBundle.golden.hardwareModel.path)
    @Published var goldenReady = FileManager.default.fileExists(atPath: Paths.goldenMarker.path)
    @Published var identity: MachineIdentity?
    @Published var exit: Mullvad.ExitCheck?
    @Published var lastHandshake: Date?
    @Published var gatewayReady = false
    @Published var sessionStarted: Date?
    @Published var activity: [LogLine] = []
    @Published private(set) var macVM: VZVirtualMachine?

    let isAppleSilicon: Bool = {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }()

    // MARK: Settings

    @AppStorage("rotateKeyEachSession") var rotateKeyEachSession = true
    @AppStorage("randomLocation") var randomLocation = true
    @AppStorage("fixedLocationIndex") var fixedLocationIndex = 0
    @AppStorage("diskGB") var diskGB = 80

    var isReadyToLaunch: Bool { vpnConfigured && goldenReady && isAppleSilicon }
    var tunnelUp: Bool { exit?.mullvad_exit_ip == true }

    private let gateway = GatewayVM()
    private var readyWaiter: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        Paths.ensure()
        gateway.onEvent = { [weak self] in self?.handleGateway($0) }
    }

    // MARK: Logging

    func log(_ text: String, error: Bool = false) {
        activity.append(LogLine(text: text, isError: error))
        if activity.count > 500 { activity.removeFirst(activity.count - 500) }
    }

    private func fail(_ message: String) {
        log(message, error: true)
        phase = .error(message)
    }

    func dismissError() { if case .error = phase { phase = .idle } }

    // MARK: Mullvad

    func connectMullvad(account: String) async {
        let account = Mullvad.normalize(account: account)
        guard account.count == 16 else { fail("Mullvad hesap numarası 16 haneli olmalı."); return }
        phase = .working("Mullvad'a bağlanılıyor…")
        do {
            let token = try await Mullvad.token(account: account)
            let acc = try await Mullvad.account(token: token)
            accountExpiry = ISO8601DateFormatter().date(from: acc.expiry)
            let keys = Mullvad.generateKeyPair()
            let device = try await Mullvad.createDevice(token: token, publicKey: keys.publicKey)
            WireGuardCredentials(privateKey: keys.privateKey, address: device.ipv4_address, deviceID: device.id).save()
            Keychain.set(account, for: "mullvad.account")
            vpnConfigured = true
            log("Mullvad cihazı oluşturuldu: \(device.name ?? device.id)")
            phase = .idle
        } catch {
            fail(error.localizedDescription)
        }
    }

    func setManualWireGuard(privateKey: String, address: String) {
        let key = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",").first ?? ""
        guard Mullvad.publicKey(for: key) != nil else { fail("WireGuard özel anahtarı geçersiz."); return }
        guard addr.contains("/") else { fail("Adres CIDR biçiminde olmalı (ör. 10.68.12.34/32)."); return }
        WireGuardCredentials(privateKey: key, address: addr, deviceID: nil).save()
        vpnConfigured = true
        log("WireGuard bilgileri elle kaydedildi")
        phase = .idle
    }

    func signOutMullvad() {
        WireGuardCredentials.clear()
        vpnConfigured = false
        accountExpiry = nil
        log("Mullvad bilgileri silindi")
    }

    /// Fresh WireGuard key per session, so sessions can't be linked by key.
    private func rotateKeyIfNeeded() async {
        guard rotateKeyEachSession, var creds = WireGuardCredentials.load(), let deviceID = creds.deviceID,
              let account = Keychain.get("mullvad.account") else { return }
        do {
            let token = try await Mullvad.token(account: account)
            let keys = Mullvad.generateKeyPair()
            let device = try await Mullvad.rotate(token: token, deviceID: deviceID, publicKey: keys.publicKey)
            creds.privateKey = keys.privateKey
            creds.address = device.ipv4_address
            creds.save()
            log("WireGuard anahtarı yenilendi")
            try? await Task.sleep(for: .seconds(3)) // let relays pick up the new key
        } catch {
            log("Anahtar yenilenemedi, mevcut anahtarla devam: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: macOS image

    func downloadMacOS() async {
        phase = .working("Güncel macOS sürümü aranıyor…")
        do {
            let url = try await MacVM.latestRestoreImageURL()
            log("macOS indiriliyor: \(url.lastPathComponent)")
            phase = .downloading(0)
            let tmp = try await Downloader.download(url) { [weak self] p in self?.phase = .downloading(p) }
            try? FileManager.default.removeItem(at: Paths.ipsw)
            try FileManager.default.moveItem(at: tmp, to: Paths.ipsw)
            ipswReady = true
            log("macOS imajı indirildi")
            phase = .idle
        } catch {
            fail("macOS indirilemedi: \(error.localizedDescription)")
        }
    }

    func useLocalIPSW(_ url: URL) {
        do {
            try? FileManager.default.removeItem(at: Paths.ipsw)
            if clonefile(url.path, Paths.ipsw.path, 0) != 0 {
                try FileManager.default.copyItem(at: url, to: Paths.ipsw)
            }
            ipswReady = true
            log("IPSW seçildi: \(url.lastPathComponent)")
        } catch {
            fail("IPSW kopyalanamadı: \(error.localizedDescription)")
        }
    }

    func installMacOS() async {
        guard ipswReady else { return }
        phase = .installing(0)
        log("macOS kuruluyor (10–20 dk)")
        do {
            try await MacVM.install(ipsw: Paths.ipsw, diskGB: diskGB) { [weak self] p in self?.phase = .installing(p) }
            installed = true
            log("macOS kuruldu. Sırada ilk açılış var.")
            phase = .idle
        } catch {
            fail("Kurulum başarısız: \(error.localizedDescription)")
        }
    }

    func deleteIPSW() {
        try? FileManager.default.removeItem(at: Paths.ipsw)
        ipswReady = false
        log("IPSW silindi (\(goldenReady ? "imaj zaten mühürlü" : "yeniden indirmen gerekecek"))")
    }

    // MARK: Machines

    /// One-time: boot the golden image so the user can run Setup Assistant and
    /// install the Mahlas agent. Networking already goes through the gateway.
    func beginFirstSetup() async {
        guard installed, !goldenReady else { return }
        try? FileManager.default.removeItem(at: Paths.agentMarker)
        var id = MachineIdentity.random(cores: 4...4, ramGB: [8])
        id.display = .init(width: 1920, height: 1200, ppi: 110)
        await launch(bundle: .golden, identity: id, machineID: MacBundle.golden.loadMachineIdentifier(), shareReadOnly: false)
        if macVM != nil {
            phase = .firstSetup
            log("İlk açılış: Kurulum Yardımcısı'nı tamamla, ardından \"\(GuestAgent.installerName)\" dosyasını çalıştır")
        }
    }

    func startSession() async {
        guard isReadyToLaunch, !phase.isBusy, !phase.hasMachine else { return }
        phase = .working("Yeni kimlik üretiliyor…")
        exit = nil; lastHandshake = nil
        await rotateKeyIfNeeded()

        phase = .working("Disk klonlanıyor…")
        do { try MacVM.cloneGoldenToSession() } catch { fail("Disk klonlanamadı: \(error.localizedDescription)"); return }

        let res = MacVM.hostResources
        let fixed = randomLocation ? nil : Locations.all[min(max(fixedLocationIndex, 0), Locations.all.count - 1)]
        let id = MachineIdentity.random(location: fixed, cores: res.cpu, ramGB: res.ramGB)
        // A new machine identifier gives the guest a new serial number / ECID.
        await launch(bundle: .session, identity: id, machineID: VZMacMachineIdentifier(), shareReadOnly: true)
        if macVM != nil {
            phase = .running
            Synth.shared.open()
        } else {
            MacVM.wipeSession()
        }
    }

    private func launch(bundle: MacBundle, identity id: MachineIdentity, machineID: VZMacMachineIdentifier?, shareReadOnly: Bool) async {
        var id = id
        guard let creds = WireGuardCredentials.load() else { fail("Mullvad yapılandırılmamış."); return }
        do {
            if !GatewayVM.assetsReady {
                phase = .working("Ağ geçidi hazırlanıyor…")
                try await GatewayVM.prepareAssets { [weak self] in self?.log($0) }
            }

            phase = .working("Mullvad sunucusu seçiliyor…")
            let relays = try await Mullvad.relays(in: id.location.code)
            guard let relay = relays.filter({ $0.owned == true }).randomElement() ?? relays.randomElement() else {
                throw MahlasError("\(id.location.displayName) için aktif Mullvad sunucusu yok.")
            }
            id.relay = relay.hostname

            let machineID = machineID ?? VZMacMachineIdentifier()
            id.machineID = String(machineID.dataRepresentation.base64EncodedString().filter(\.isLetter).prefix(10)).uppercased()
            try GuestAgent.writeShare(sessionConfig: id.guestConfig)

            let (macEnd, gatewayEnd) = try VirtualCable.make()

            phase = .working("Şifreli tünel kuruluyor…")
            gatewayReady = false
            try await gateway.start(tunnel: .init(privateKey: creds.privateKey, address: creds.address, relay: relay), lan: gatewayEnd)
            guard await waitForGateway(timeout: 120) else {
                await gateway.stop()
                throw MahlasError("Ağ geçidi 2 dakikada hazır olmadı. İnternet bağlantını kontrol et; ayrıntılar Günlükler'de.")
            }

            phase = .working("Mac açılıyor…")
            let hw = try bundle.loadHardwareModel()
            let aux = VZMacAuxiliaryStorage(url: bundle.aux)
            let config = try MacVM.configuration(bundle: bundle, hardwareModel: hw, machineID: machineID, aux: aux,
                                                 cpu: id.cpuCores, ramGB: id.ramGB, display: id.display,
                                                 network: macEnd, mac: id.macAddress,
                                                 share: (Paths.share, shareReadOnly))
            let vm = VZVirtualMachine(configuration: config)
            vm.delegate = self
            try await vm.start()
            macVM = vm
            identity = id
            sessionStarted = Date()
            log("Kimlik: \(id.computerName) · \(id.cpuCores) çekirdek / \(id.ramGB) GB · \(id.display.label)")
        } catch {
            await gateway.stop()
            fail(error.localizedDescription)
        }
    }

    func stopSession() async {
        let wasSetup = phase == .firstSetup
        phase = .working("Kapatılıyor…")
        if let vm = macVM {
            if vm.canRequestStop { try? vm.requestStop() }
            for _ in 0..<30 where vm.state == .running || vm.state == .stopping {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if vm.canStop { try? await vm.stop() }
        }
        await gateway.stop()
        teardown(sealIfReady: wasSetup)
    }

    func newIdentity() async {
        await stopSession()
        await startSession()
    }

    private func teardown(sealIfReady: Bool) {
        macVM = nil
        identity = nil; exit = nil; lastHandshake = nil; sessionStarted = nil; gatewayReady = false
        try? GuestAgent.writeShare(sessionConfig: nil)
        if sealIfReady {
            if FileManager.default.fileExists(atPath: Paths.agentMarker.path) {
                FileManager.default.createFile(atPath: Paths.goldenMarker.path, contents: Data())
                goldenReady = true
                log("Altın imaj mühürlendi — artık her oturum sıfırdan, yeni bir kimlikle açılır")
                Synth.shared.select()
            } else {
                log("Mahlas ajanı kurulmadan kapatıldı. İlk açılışı tekrar başlatıp ajanı kur.", error: true)
            }
        } else if goldenReady {
            MacVM.wipeSession()
            log("Oturum diski silindi — hiçbir iz kalmadı")
            Synth.shared.back()
        }
        phase = .idle
    }

    func resetGolden() async {
        if phase.hasMachine { await stopSession() }
        try? FileManager.default.removeItem(at: Paths.golden)
        try? FileManager.default.removeItem(at: Paths.agentMarker)
        MacVM.wipeSession()
        Paths.ensure()
        goldenReady = false
        installed = false
        log("macOS imajı silindi")
    }

    // MARK: Gateway events

    private func waitForGateway(timeout: Double) async -> Bool {
        if gatewayReady { return true }
        return await withCheckedContinuation { cont in
            readyWaiter = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if let w = self.readyWaiter { self.readyWaiter = nil; w.resume(returning: false) }
            }
        }
    }

    private func handleGateway(_ event: GatewayVM.Event) {
        switch event {
        case .log(let s):
            log("Ağ geçidi: \(s)")
        case .ready:
            gatewayReady = true
            if let w = readyWaiter { readyWaiter = nil; w.resume(returning: true) }
        case .status(let hs, let e):
            if hs > 0 { lastHandshake = Date(timeIntervalSince1970: TimeInterval(hs)) }
            let wasUp = tunnelUp
            exit = e
            if let e, e.mullvad_exit_ip == true, !wasUp {
                log("Trafik Mullvad üzerinden çıkıyor: \(e.ip) (\(e.city ?? "?"), \(e.country ?? "?"))")
            } else if e == nil, wasUp {
                log("Tünel yanıt vermiyor — kill switch trafiği engelliyor", error: true)
            }
        case .stopped(let err):
            gatewayReady = false
            if let w = readyWaiter { readyWaiter = nil; w.resume(returning: false) }
            if phase.hasMachine {
                log("Ağ geçidi kapandı\(err.map { ": \($0.localizedDescription)" } ?? "") — Mac'in internet erişimi kesildi", error: true)
                exit = nil
            }
        }
    }

    // MARK: VZVirtualMachineDelegate (macOS guest)

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in await self.guestEnded(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in await self.guestEnded(error) }
    }

    private func guestEnded(_ error: Error?) async {
        guard macVM != nil, phase.hasMachine else { return }
        let wasSetup = phase == .firstSetup
        if let error { log("Mac beklenmedik şekilde durdu: \(error.localizedDescription)", error: true) }
        else { log(wasSetup ? "Sanal Mac kapandı" : "Mac kapatıldı") }
        await gateway.stop()
        teardown(sealIfReady: wasSetup)
    }
}

/// URLSession download with progress, for the multi-GB restore image.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var cont: CheckedContinuation<URL, Error>?
    private let onProgress: @MainActor (Double) -> Void
    private var lastReport = Date.distantPast

    private init(onProgress: @escaping @MainActor (Double) -> Void) { self.onProgress = onProgress }

    static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let d = Downloader(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.cont = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, Date().timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = Date()
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.onProgress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns — move it first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("mahlas-\(UUID().uuidString).ipsw")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            cont?.resume(returning: keep)
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}
