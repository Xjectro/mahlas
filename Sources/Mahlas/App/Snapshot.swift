import Virtualization
import SwiftUI

/// Debug aid: `Mahlas --snapshot <dir>` renders key screens to PNG and exits.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test-gateway") {
            let seconds = Double(args.count > i + 1 ? args[i + 1] : "90") ?? 90
            Task { await GatewayTest.run(seconds: seconds) }
            return
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Fonts.register()
        let size = CGSize(width: 1280, height: 800)

        for t in [0.5, 1.15, 1.6, 2.6, 3.5, 3.9] {
            save(IntroView(onDone: {}, frozenTime: t), size: size, to: dir.appendingPathComponent("intro-\(t).png"))
        }

        let session = SessionManager()
        session.vpnConfigured = false
        session.installed = false
        session.goldenReady = false
        session.phase = .downloading(0.42)
        for (name, section) in [("setup", Section.setup), ("settings", Section.settings)] {
            save(MainShot(section: section).environmentObject(session), size: size, to: dir.appendingPathComponent("\(name).png"))
        }
        session.vpnConfigured = true
        session.installed = true
        session.goldenReady = true
        var id = MachineIdentity.random(cores: 4...8, ramGB: [8, 12, 16])
        id.machineID = "QKZT7RWMHA"
        id.relay = "\(id.location.code)-wg-004"
        session.identity = id
        session.exit = Mullvad.ExitCheck(ip: "185.65.134.77", country: "Netherlands", city: "Amsterdam",
                                         mullvad_exit_ip: true, mullvad_exit_ip_hostname: id.relay, organization: "M247")
        session.lastHandshake = Date().addingTimeInterval(-12)
        session.sessionStarted = Date().addingTimeInterval(-300)
        session.phase = .running
        session.log("Kimlik: \(id.computerName)")
        session.log("Trafik Mullvad üzerinden çıkıyor: 185.65.134.77")
        save(MainShot(section: .session).environmentObject(session), size: CGSize(width: 1280, height: 1000), to: dir.appendingPathComponent("session.png"))
        exit(0)
    }

    private struct MainShot: View {
        let section: Section
        var body: some View {
            HStack(spacing: 0) {
                Sidebar(section: .constant(section)).frame(width: 232)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                ZStack(alignment: .top) {
                    Theme.backdrop.opacity(0.55)
                    switch section {
                    case .session: SessionView(section: .constant(section))
                    case .setup: SetupView(section: .constant(.setup))
                    default: SettingsView()
                    }
                }
            }
            .background(Theme.bg)
            .environment(\.colorScheme, .dark)
        }
    }

    private static func save<V: View>(_ view: V, size: CGSize, to url: URL) {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = 1
        guard let cg = r.cgImage else { print("render failed: \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// `Mahlas --test-gateway [seconds]`: boots the gateway with a throwaway
/// (unregistered) WireGuard key plus a tiny DHCP client VM on the LAN cable,
/// and prints both consoles. Verifies boot, firewall, wg0 and DHCP end to end.
@MainActor
enum GatewayTest {
    static var keep: [AnyObject] = []

    static func run(seconds: Double) async {
        func out(_ s: String) { print(s); fflush(stdout) }
        do {
            try await GatewayVM.prepareAssets { out("[asset] \($0)") }
            let relay = try await Mullvad.relays(in: "nl-ams").randomElement()!
            out("[test] relay \(relay.hostname) \(relay.ipv4_addr_in)")
            let (clientEnd, gwEnd) = try VirtualCable.make()
            let gw = GatewayVM()
            keep.append(gw)
            gw.rawConsole = { out("[gw] \($0)") }
            gw.onEvent = { e in
                switch e {
                case .ready: out("[test] >>> GATEWAY READY")
                case .status(let hs, let ex): out("[test] status handshake=\(hs) exit=\(ex?.ip ?? "nil")")
                case .stopped(let err): out("[test] gateway stopped \(err?.localizedDescription ?? "")")
                case .log: break
                }
            }
            let key = Mullvad.generateKeyPair().privateKey
            try await gw.start(tunnel: .init(privateKey: key, address: "10.64.99.2/32", relay: relay), lan: gwEnd)

            // DHCP client: same Alpine kernel, only NIC is the cable.
            let boot = VZLinuxBootLoader(kernelURL: GatewayVM.kernel)
            boot.initialRamdiskURL = GatewayVM.initramfs
            boot.commandLine = "console=hvc0 ip=dhcp modules=virtio_net"
            let c = VZVirtualMachineConfiguration()
            c.bootLoader = boot
            c.cpuCount = 1
            c.memorySize = 256 * 1024 * 1024
            let nic = VZVirtioNetworkDeviceConfiguration()
            nic.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: clientEnd)
            c.networkDevices = [nic]
            let pipe = Pipe()
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
            c.serialPorts = [serial]
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                for l in String(decoding: d, as: UTF8.self).split(separator: "\n") { print("[client] \(l)") }
                fflush(stdout)
            }
            try c.validate()
            // Give the gateway a head start so dnsmasq is up.
            try await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["MAHLAS_GW_WAIT"] ?? "25") ?? 25))
            if let cmds = ProcessInfo.processInfo.environment["MAHLAS_GW_CMDS"] {
                for c in cmds.components(separatedBy: ";;") { gw.send(c); try await Task.sleep(for: .seconds(2)) }
            }
            let client = VZVirtualMachine(configuration: c)
            keep.append(client); keep.append(pipe)
            try await client.start()
            out("[test] client started")
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            out("[test] ERROR \(error)")
        }
        exit(0)
    }
}
