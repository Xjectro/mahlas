import Foundation
import Virtualization

/// A tiny diskless Alpine Linux VM that is the macOS guest's only way out:
/// it hands the guest DHCP/DNS on a private link and forwards its traffic
/// exclusively into a Mullvad WireGuard tunnel, with an iptables kill switch.
///
///   macOS guest ──(socketpair "cable")── eth1 [gateway] wg0 ══ Mullvad
///                                              eth0 (NAT) only carries the
///                                              encrypted WireGuard UDP
@MainActor
final class GatewayVM: NSObject, VZVirtualMachineDelegate {
    static let alpineRelease = "v3.22"
    static let lanAddress = "10.99.0.1"

    struct Tunnel {
        let privateKey: String
        let address: String
        let relay: Mullvad.Relay
    }

    enum Event {
        case log(String)
        case ready
        case status(handshake: Int, exit: Mullvad.ExitCheck?)
        case stopped(Error?)
    }

    private(set) var vm: VZVirtualMachine?
    private var consolePipe: Pipe?
    private var inputPipe: Pipe?
    private var buffer = Data()
    var onEvent: ((Event) -> Void)?
    /// Every console line, unparsed (debug/test only).
    var rawConsole: ((String) -> Void)?

    // MARK: Assets

    static var kernel: URL { Paths.gateway.appendingPathComponent("Image") }
    static var initramfs: URL { Paths.gateway.appendingPathComponent("initramfs-virt") }
    static var modloop: URL { Paths.gateway.appendingPathComponent("modloop-virt") }
    static var configDisk: URL { Paths.gateway.appendingPathComponent("boot.img") }
    static var repo: URL { Paths.gateway.appendingPathComponent("apks", isDirectory: true) }
    /// Bump when the boot disk layout changes so cached assets are rebuilt.
    static let assetsVersion = "4"
    static var versionFile: URL { Paths.gateway.appendingPathComponent("assets-version") }
    static var assetsReady: Bool {
        [kernel, initramfs, configDisk].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            && (try? String(contentsOf: versionFile, encoding: .utf8)) == assetsVersion
    }

    /// Everything the gateway runs. Resolved with dependencies and stored on
    /// the boot disk, so the gateway never touches the network to boot.
    static let packages = ["alpine-base", "wireguard-tools-wg", "iproute2", "iptables", "dnsmasq", "curl", "openssl"]

    /// Downloads Alpine's netboot kernel, unpacks the EFI zboot wrapper into the
    /// raw arm64 Image VZLinuxBootLoader needs, downloads the packages into a
    /// local repository and builds the FAT boot disk (apkovl + modloop + repo)
    /// that Alpine's init finds on its own. Runs once, on the host.
    static func prepareAssets(log: @escaping (String) -> Void) async throws {
        Paths.ensure()
        if assetsReady { return }
        resetAssets()
        let base = URL(string: "https://dl-cdn.alpinelinux.org/alpine/\(alpineRelease)/releases/aarch64/netboot/")!
        let fm = FileManager.default
        log("Ağ geçidi için Alpine Linux indiriliyor")
        for name in ["vmlinuz-virt", "initramfs-virt", "modloop-virt"] {
            let (tmp, resp) = try await URLSession.shared.download(from: base.appendingPathComponent(name))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MahlasError("\(name) indirilemedi") }
            let dst = Paths.gateway.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: tmp, to: dst)
        }
        try unpackKernel(Paths.gateway.appendingPathComponent("vmlinuz-virt"), to: kernel)
        try? fm.removeItem(at: Paths.gateway.appendingPathComponent("vmlinuz-virt"))
        let count = try await AlpineRepo.mirror(packages: packages, release: alpineRelease, into: repo)
        log("Ağ geçidi paketleri indirildi (\(count) paket)")
        try await buildConfigDisk()
        try assetsVersion.write(to: versionFile, atomically: true, encoding: .utf8)
        log("Ağ geçidi hazır — açılışta internete çıkmaz")
    }

    /// arm64 EFI zboot: "MZ" + "zimg" magic, payload offset at 8, size at 12, gzip payload.
    private static func unpackKernel(_ src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src)
        guard data.count > 64, data[4..<8] == Data("zimg".utf8) else {
            try data.write(to: dst); return // already a raw Image
        }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1]) << 8 | Int(data[o+2]) << 16 | Int(data[o+3]) << 24 }
        let offset = u32(8), size = u32(12)
        let gz = Paths.gateway.appendingPathComponent("Image.gz")
        try data.subdata(in: offset..<(offset + size)).write(to: gz)
        let r = Shell.runSync("/usr/bin/gunzip", ["-f", gz.path])
        guard r.ok else { throw MahlasError("Kernel açılamadı: \(r.err)") }
    }

    /// FAT boot disk: Alpine's nlplug-findfs mounts it, unpacks the apkovl
    /// (our config) and later finds boot/modloop-virt (kernel modules) on it.
    private static func buildConfigDisk() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mahlas-gw-\(UUID().uuidString)")
        let ovlRoot = work.appendingPathComponent("ovl")
        defer { try? fm.removeItem(at: work) }

        // 1. apkovl tree
        func put(_ rel: String, _ content: String, mode: Int = 0o644) throws {
            let url = ovlRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try put("etc/.default_boot_services", "")
        try put("etc/hostname", "gateway\n")
        try put("etc/apk/world", "alpine-base\nwireguard-tools-wg\niproute2\niptables\ndnsmasq\ncurl\n")
        try put("etc/apk/repositories", "/media/vda/apks\n")
        try put("etc/local.d/mahlas.start", GatewayScripts.start, mode: 0o755)
        let runlevel = ovlRoot.appendingPathComponent("etc/runlevels/default")
        try fm.createDirectory(at: runlevel, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: runlevel.appendingPathComponent("local").path, withDestinationPath: "/etc/init.d/local")

        let ovl = work.appendingPathComponent("mahlas.apkovl.tar.gz")
        var r = Shell.runSync("/usr/bin/tar", ["--no-xattrs", "--no-mac-metadata", "--uid", "0", "--gid", "0",
                                               "--uname", "root", "--gname", "root", "-czf", ovl.path, "-C", ovlRoot.path, "etc"],
                              env: ["COPYFILE_DISABLE": "1"])
        guard r.ok else { throw MahlasError("apkovl oluşturulamadı: \(r.err)") }

        // 2. raw FAT16 image (superfloppy, no partition table)
        let img = work.appendingPathComponent("boot.img")
        fm.createFile(atPath: img.path, contents: nil)
        let h = try FileHandle(forWritingTo: img)
        try h.truncate(atOffset: 96 * 1024 * 1024)
        try h.close()

        r = Shell.runSync("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", img.path])
        guard r.ok, let dev = r.out.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw MahlasError("Disk imajı bağlanamadı: \(r.err)")
        }
        r = Shell.runSync("/sbin/newfs_msdos", ["-F", "16", "-v", "MAHLASGW", dev])
        _ = Shell.runSync("/usr/bin/hdiutil", ["detach", dev, "-force"])
        guard r.ok else { throw MahlasError("FAT biçimlendirilemedi: \(r.err)") }

        let mnt = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
        r = Shell.runSync("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nobrowse",
                                               "-mountpoint", mnt.path, img.path])
        guard r.ok else { throw MahlasError("Disk imajı açılamadı: \(r.err)") }
        // cp -X: no extended attributes, so macOS writes no "._" AppleDouble files.
        let copies: [(URL, String)] = [(ovl, "mahlas.apkovl.tar.gz"), (modloop, "boot/modloop-virt"), (repo, "apks")]
        for (src, rel) in copies {
            let dst = mnt.appendingPathComponent(rel)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            r = Shell.runSync("/bin/cp", ["-RX", src.path, dst.path])
            if !r.ok {
                _ = Shell.runSync("/usr/bin/hdiutil", ["detach", mnt.path, "-force"])
                throw MahlasError("Açılış diski yazılamadı: \(r.err)")
            }
        }
        // Alpine's init treats any dir with this marker as a package repository.
        fm.createFile(atPath: mnt.appendingPathComponent("apks/.boot_repository").path, contents: Data())
        // Strip any macOS metadata that slipped in.
        _ = Shell.runSync("/usr/bin/find", [mnt.path, "-name", "._*", "-delete"])
        for junk in [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"] {
            try? fm.removeItem(at: mnt.appendingPathComponent(junk))
        }
        _ = Shell.runSync("/usr/bin/hdiutil", ["detach", mnt.path])
        try? fm.removeItem(at: configDisk)
        try fm.moveItem(at: img, to: configDisk)
    }

    static func resetAssets() {
        try? FileManager.default.removeItem(at: Paths.gateway)
        Paths.ensure()
    }

    // MARK: Lifecycle

    /// - Parameter lan: the gateway's end of the cable to the macOS guest.
    func start(tunnel: Tunnel, lan: FileHandle) async throws {
        let cmdline = [
            "console=hvc0",
            ProcessInfo.processInfo.environment["MAHLAS_GW_DEBUG"] == nil ? "quiet loglevel=3" : "loglevel=6",
            "modules=loop,squashfs,virtio_blk,vfat,virtio_net",
            // No ip= / alpine_repo=: init boots entirely from the local disk.
            "modloop_verify=yes",
            // Session parameters. The private key lives only in VM memory.
            "mahlas.key=\(tunnel.privateKey)",
            "mahlas.addr=\(tunnel.address)",
            "mahlas.peer=\(tunnel.relay.public_key)",
            "mahlas.endpoint=\(tunnel.relay.ipv4_addr_in)",
            "mahlas.port=51820"
        ].joined(separator: " ")

        let boot = VZLinuxBootLoader(kernelURL: Self.kernel)
        boot.initialRamdiskURL = Self.initramfs
        boot.commandLine = cmdline

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = 1
        config.memorySize = 512 * 1024 * 1024
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let disk = try VZDiskImageStorageDeviceAttachment(url: Self.configDisk, readOnly: true)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let wan = VZVirtioNetworkDeviceConfiguration()           // eth0
        wan.attachment = VZNATNetworkDeviceAttachment()
        let lanNIC = VZVirtioNetworkDeviceConfiguration()        // eth1
        lanNIC.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: lan)
        config.networkDevices = [wan, lanNIC]

        let pipe = Pipe()
        consolePipe = pipe
        // Console input exists only in debug builds of a session (MAHLAS_GW_DEBUG).
        let input: Pipe? = ProcessInfo.processInfo.environment["MAHLAS_GW_DEBUG"] == nil ? nil : Pipe()
        inputPipe = input
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: input?.fileHandleForReading,
                                                             fileHandleForWriting: pipe.fileHandleForWriting)
        config.serialPorts = [serial]
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.vm = vm
        try await vm.start()
        onEvent?(.log("Ağ geçidi açılıyor → \(tunnel.relay.hostname)"))
    }

    func stop() async {
        guard let vm, vm.canStop else { cleanup(); return }
        try? await vm.stop()
        cleanup()
    }

    /// Types a line into the gateway console (debug only).
    func send(_ line: String) {
        inputPipe?.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    private func cleanup() {
        consolePipe?.fileHandleForReading.readabilityHandler = nil
        consolePipe = nil
        inputPipe = nil
        vm = nil
        buffer.removeAll()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.cleanup(); self.onEvent?(.stopped(nil)) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.cleanup(); self.onEvent?(.stopped(error)) }
    }

    // MARK: Console protocol

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        rawConsole?(line)
        if line.hasPrefix("MAHLAS-READY") {
            onEvent?(.ready)
        } else if line.hasPrefix("MAHLAS-EVENT ") {
            onEvent?(.log(String(line.dropFirst(13))))
        } else if line.hasPrefix("MAHLAS-STATUS ") {
            // MAHLAS-STATUS handshake=<unix> {json}
            let rest = line.dropFirst(14)
            let hsPart = rest.prefix { $0 != " " }
            let hs = Int(hsPart.split(separator: "=").last ?? "0") ?? 0
            let json = rest.dropFirst(hsPart.count).trimmingCharacters(in: .whitespaces)
            let exit = json.data(using: .utf8).flatMap { try? JSONDecoder().decode(Mullvad.ExitCheck.self, from: $0) }
            onEvent?(.status(handshake: hs, exit: exit))
        }
    }
}

enum GatewayScripts {
    /// OpenRC local.d script: firewall first, then tunnel, then LAN services.
    static let start = #"""
    #!/bin/sh
    # Mahlas gateway. Reports to the host over /dev/hvc0.
    OUT=/dev/hvc0
    say() { echo "MAHLAS-EVENT $*" > $OUT; }

    for x in $(cat /proc/cmdline); do
      case "$x" in
        mahlas.key=*) M_KEY="${x#*=}" ;;
        mahlas.addr=*) M_ADDR="${x#*=}" ;;
        mahlas.peer=*) M_PEER="${x#*=}" ;;
        mahlas.endpoint=*) M_ENDPOINT="${x#*=}" ;;
        mahlas.port=*) M_PORT="${x#*=}" ;;
      esac
    done
    LAN=10.99.0.1

    say "Ağ geçidi açıldı"
    passwd -l root >/dev/null 2>&1   # no console logins
    sysctl -q -w net.ipv4.ip_forward=1
    sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -q -w net.ipv6.conf.default.disable_ipv6=1

    # --- Kill switch first: nothing leaves except the encrypted handshake ---
    # (udhcpc uses raw packet sockets, so DHCP on the NAT link still works.)
    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP
    iptables -F; iptables -X; iptables -t nat -F; iptables -t mangle -F
    if command -v ip6tables >/dev/null; then
      ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT DROP
    fi
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i eth1 -p udp --dport 67 -j ACCEPT
    iptables -A INPUT -i eth1 -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i eth1 -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -i eth1 -p icmp -j ACCEPT
    iptables -A OUTPUT -o eth1 -j ACCEPT
    iptables -A OUTPUT -o wg0 -j ACCEPT
    iptables -A OUTPUT -o eth0 -p udp -d "$M_ENDPOINT" --dport "$M_PORT" -j ACCEPT
    iptables -A FORWARD -i eth1 -o wg0 -j ACCEPT
    iptables -A FORWARD -i wg0 -o eth1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    say "Kill switch etkin"

    ip link set lo up
    ip link set eth0 up
    ip link set eth1 up
    ip addr flush dev eth1
    ip addr add $LAN/24 dev eth1
    udhcpc -i eth0 -n -q -t 8 >/dev/null 2>&1
    GW=$(ip -4 route show default | awk '{print $3; exit}')
    [ -n "$GW" ] || say "UYARI: NAT bağlantısı yok"

    # --- WireGuard ---
    modprobe wireguard
    ip link add wg0 type wireguard
    umask 077
    printf '%s' "$M_KEY" > /run/wg.key
    wg set wg0 private-key /run/wg.key peer "$M_PEER" endpoint "$M_ENDPOINT:$M_PORT" \
      allowed-ips 0.0.0.0/0 persistent-keepalive 25
    rm -f /run/wg.key
    M_KEY=
    ip addr add "$M_ADDR" dev wg0
    ip link set wg0 mtu 1420 up
    [ -n "$GW" ] && ip route add "$M_ENDPOINT/32" via "$GW" dev eth0
    # Only route to the outside world: the tunnel. Drop the NAT default route.
    while ip -4 route del default dev eth0 2>/dev/null; do :; done
    ip route replace default dev wg0
    echo "nameserver 10.64.0.1" > /etc/resolv.conf
    say "WireGuard tüneli kuruldu"

    # --- DHCP + DNS for the Mac (DNS only via Mullvad, in-tunnel) ---
    dnsmasq --interface=eth1 --bind-interfaces --no-resolv --no-hosts --server=10.64.0.1 \
      --dhcp-range=10.99.0.20,10.99.0.200,255.255.255.0,12h --dhcp-authoritative --no-ping \
      --dhcp-option=option:router,$LAN --dhcp-option=option:dns-server,$LAN --dhcp-option=option:mtu,1380
    echo "MAHLAS-READY" > $OUT

    ( while true; do
        hs=$(wg show wg0 latest-handshakes | awk '{print $2}')
        j=$(curl -fsS -m 8 https://am.i.mullvad.net/json 2>/dev/null | tr -d '\n')
        echo "MAHLAS-STATUS handshake=${hs:-0} $j" > $OUT
        sleep 20
      done ) >/dev/null 2>&1 &
    """#
}
