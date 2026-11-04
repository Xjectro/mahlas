import Foundation
import Virtualization

/// Files that make up one macOS virtual machine bundle.
struct MacBundle {
    let dir: URL
    var disk: URL { dir.appendingPathComponent("Disk.img") }
    var aux: URL { dir.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModel: URL { dir.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { dir.appendingPathComponent("MachineIdentifier") }

    static let golden = MacBundle(dir: Paths.golden)
    static let session = MacBundle(dir: Paths.session)

    func loadHardwareModel() throws -> VZMacHardwareModel {
        guard let data = try? Data(contentsOf: hardwareModel),
              let model = VZMacHardwareModel(dataRepresentation: data), model.isSupported else {
            throw MahlasError("macOS donanım modeli okunamadı ya da bu Mac'te desteklenmiyor.")
        }
        return model
    }

    func loadMachineIdentifier() -> VZMacMachineIdentifier? {
        (try? Data(contentsOf: machineIdentifier)).flatMap(VZMacMachineIdentifier.init(dataRepresentation:))
    }
}

/// Builds and installs macOS guests with Virtualization.framework.
@MainActor
enum MacVM {
    struct Resources {
        let cpu: ClosedRange<Int>
        let ramGB: [Int]
    }

    /// What the host can give a guest, bounded by the framework's limits.
    static var hostResources: Resources {
        let hostCPU = ProcessInfo.processInfo.processorCount
        let hostRAM = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let maxCPU = max(2, min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, hostCPU - 2, 8))
        let maxRAM = max(4, min(hostRAM - 6, 16))
        let rams = [4, 6, 8, 12, 16].filter { $0 <= maxRAM }
        return Resources(cpu: min(4, maxCPU)...maxCPU, ramGB: rams.isEmpty ? [4] : rams)
    }

    // MARK: Install

    static func latestRestoreImageURL() async throws -> URL {
        let image = try await VZMacOSRestoreImage.latestSupported
        return image.url
    }

    /// Creates the golden bundle from an IPSW and runs the macOS installer.
    static func install(ipsw: URL, diskGB: Int, progress: @escaping (Double) -> Void) async throws {
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
            throw MahlasError("Bu macOS sürümü bu Mac'te sanallaştırılamıyor.")
        }
        let bundle = MacBundle.golden
        let fm = FileManager.default
        try? fm.removeItem(at: bundle.dir)
        try fm.createDirectory(at: bundle.dir, withIntermediateDirectories: true)

        try req.hardwareModel.dataRepresentation.write(to: bundle.hardwareModel)
        let machineID = VZMacMachineIdentifier()
        try machineID.dataRepresentation.write(to: bundle.machineIdentifier)
        let aux = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.aux, hardwareModel: req.hardwareModel, options: [])

        // Sparse disk: occupies only what macOS actually writes.
        fm.createFile(atPath: bundle.disk.path, contents: nil)
        let h = try FileHandle(forWritingTo: bundle.disk)
        try h.truncate(atOffset: UInt64(diskGB) * 1_073_741_824)
        try h.close()

        let config = try configuration(bundle: bundle, hardwareModel: req.hardwareModel, machineID: machineID, aux: aux,
                                       cpu: max(req.minimumSupportedCPUCount, 4),
                                       ramGB: max(Int(req.minimumSupportedMemorySize / 1_073_741_824), 8),
                                       display: .init(width: 1920, height: 1200, ppi: 110),
                                       network: nil, mac: nil, share: nil)
        let vm = VZVirtualMachine(configuration: config)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        let obs = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            let v = p.fractionCompleted
            Task { @MainActor in progress(v) }
        }
        defer { obs.invalidate() }
        try await installer.install()
    }

    // MARK: Configuration

    static func configuration(bundle: MacBundle, hardwareModel: VZMacHardwareModel, machineID: VZMacMachineIdentifier,
                              aux: VZMacAuxiliaryStorage, cpu: Int, ramGB: Int, display: MachineIdentity.Display,
                              network: FileHandle?, mac: String?, share: (url: URL, readOnly: Bool)?) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = aux

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = min(max(cpu, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        config.memorySize = min(max(UInt64(ramGB) * 1_073_741_824, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let gfx = VZMacGraphicsDeviceConfiguration()
        gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: display.width, heightInPixels: display.height,
                                                          pixelsPerInch: display.ppi)]
        config.graphicsDevices = [gfx]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.disk, readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .fsync)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        if let network {
            let nic = VZVirtioNetworkDeviceConfiguration()
            nic.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: network)
            if let mac, let addr = VZMACAddress(string: mac) { nic.macAddress = addr }
            config.networkDevices = [nic]
        }

        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Speakers only — the guest gets no microphone, camera or USB passthrough.
        let sound = VZVirtioSoundDeviceConfiguration()
        let out = VZVirtioSoundDeviceOutputStreamConfiguration()
        out.sink = VZHostAudioOutputStreamSink()
        sound.streams = [out]
        config.audioDevices = [sound]

        if let share {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share.url, readOnly: share.readOnly))
            config.directorySharingDevices = [fs]
        }

        try config.validate()
        return config
    }

    // MARK: Disk

    /// APFS clone: instant, and takes no space until the guest writes.
    static func cloneGoldenToSession() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.session)
        try fm.createDirectory(at: Paths.session, withIntermediateDirectories: true)
        for file in ["Disk.img", "AuxiliaryStorage", "HardwareModel"] {
            let src = Paths.golden.appendingPathComponent(file)
            let dst = Paths.session.appendingPathComponent(file)
            if clonefile(src.path, dst.path, 0) != 0 { try fm.copyItem(at: src, to: dst) }
        }
    }

    static func wipeSession() {
        try? FileManager.default.removeItem(at: Paths.session)
        try? FileManager.default.createDirectory(at: Paths.session, withIntermediateDirectories: true)
    }
}

/// A unix datagram socket pair: the virtual Ethernet cable between the macOS
/// guest and the gateway. Neither end touches the host's network.
enum VirtualCable {
    static func make() throws -> (FileHandle, FileHandle) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { throw MahlasError("Sanal ağ kablosu oluşturulamadı") }
        for fd in fds {
            var snd: Int32 = 1 << 20, rcv: Int32 = 4 << 20
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
                FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }
}

/// Scripts placed in the guest share. The user runs the installer once inside
/// the golden image (double-click in Finder → "My Shared Files").
enum GuestAgent {
    static let installerName = "Mahlas Kurulum.command"

    static let installerCommand = #"""
    #!/bin/sh
    clear
    echo "Mahlas ajanı kuruluyor. Bu Mac'in (sanal makinenin) parolası istenecek."
    echo
    DIR="$(cd "$(dirname "$0")" && pwd)"
    if sudo /bin/sh "$DIR/.mahlas/install-agent.sh" "$DIR"; then
      echo
      echo "Tamam. Sanal Mac kapanıyor; Mahlas imajı mühürleyecek."
      sleep 2
      sudo shutdown -h now
    else
      echo "Kurulum başarısız oldu."
    fi
    """#

    static let installAgent = #"""
    #!/bin/sh
    set -e
    SRC="$1/.mahlas"
    mkdir -p /usr/local/mahlas
    cp "$SRC/agent.sh" /usr/local/mahlas/agent.sh
    chmod 755 /usr/local/mahlas/agent.sh
    cp "$SRC/com.mahlas.agent.plist" /Library/LaunchDaemons/com.mahlas.agent.plist
    chown root:wheel /Library/LaunchDaemons/com.mahlas.agent.plist
    chmod 644 /Library/LaunchDaemons/com.mahlas.agent.plist

    # Hardening
    /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null
    /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on >/dev/null
    /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned off >/dev/null
    defaults write /Library/Preferences/com.apple.mDNSResponder.plist NoMulticastAdvertisements -bool true
    defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" AutoSubmit -bool false
    defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" ThirdPartyDataSubmit -bool false
    systemsetup -setremotelogin off >/dev/null 2>&1 || true
    systemsetup -setusingnetworktime on >/dev/null 2>&1 || true

    touch "$SRC/agent-installed"
    """#

    /// Runs at every boot (LaunchDaemon) and adopts the session identity.
    static let agent = #"""
    #!/bin/sh
    CFG=""
    i=0
    while [ $i -lt 90 ]; do
      for d in "/Volumes/My Shared Files/.mahlas" "/private/var/mahlas/.mahlas"; do
        if [ -f "$d/session.conf" ]; then CFG="$d/session.conf"; break 2; fi
      done
      if [ $i -eq 8 ]; then
        mkdir -p /private/var/mahlas
        mount_virtiofs com.apple.virtio-fs.automount /private/var/mahlas 2>/dev/null
      fi
      i=$((i+1)); sleep 1
    done
    [ -n "$CFG" ] || exit 0

    while IFS='=' read -r k v; do
      case "$k" in
        NAME) NAME="$v" ;;
        LOCALNAME) LOCALNAME=$(printf '%s' "$v" | tr -cd 'A-Za-z0-9-') ;;
        TZ) TZ_ID=$(printf '%s' "$v" | tr -cd 'A-Za-z0-9/_+-') ;;
      esac
    done < "$CFG"

    [ -n "$NAME" ] && scutil --set ComputerName "$NAME"
    if [ -n "$LOCALNAME" ]; then
      scutil --set LocalHostName "$LOCALNAME"
      scutil --set HostName "$LOCALNAME"
    fi
    [ -n "$TZ_ID" ] && systemsetup -settimezone "$TZ_ID" >/dev/null 2>&1
    dscacheutil -flushcache
    """#

    static let launchDaemon = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>com.mahlas.agent</string>
      <key>ProgramArguments</key><array><string>/bin/sh</string><string>/usr/local/mahlas/agent.sh</string></array>
      <key>RunAtLoad</key><true/>
    </dict>
    </plist>
    """

    static func writeShare(sessionConfig: String?) throws {
        Paths.ensure()
        let fm = FileManager.default
        func put(_ url: URL, _ s: String, _ mode: Int) throws {
            try s.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try put(Paths.share.appendingPathComponent(installerName), installerCommand, 0o755)
        try put(Paths.shareMeta.appendingPathComponent("install-agent.sh"), installAgent, 0o755)
        try put(Paths.shareMeta.appendingPathComponent("agent.sh"), agent, 0o755)
        try put(Paths.shareMeta.appendingPathComponent("com.mahlas.agent.plist"), launchDaemon, 0o644)
        let conf = Paths.shareMeta.appendingPathComponent("session.conf")
        if let sessionConfig { try put(conf, sessionConfig, 0o644) } else { try? fm.removeItem(at: conf) }
    }
}
