import Foundation
import Security

// MARK: - Paths

enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Mahlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Downloaded macOS restore image.
    static var ipsw: URL { root.appendingPathComponent("RestoreImage.ipsw") }
    /// The installed "golden" macOS. Only booted during first-time setup.
    static var golden: URL { root.appendingPathComponent("golden", isDirectory: true) }
    /// Per-session throwaway clone of the golden machine.
    static var session: URL { root.appendingPathComponent("session", isDirectory: true) }
    /// Alpine kernel/initramfs/modloop for the VPN gateway VM.
    static var gateway: URL { root.appendingPathComponent("gateway", isDirectory: true) }
    /// Folder shared into the guest (Finder: "My Shared Files").
    static var share: URL { root.appendingPathComponent("share", isDirectory: true) }
    static var shareMeta: URL { share.appendingPathComponent(".mahlas", isDirectory: true) }
    static var goldenMarker: URL { golden.appendingPathComponent(".mahlas-golden") }
    static var agentMarker: URL { shareMeta.appendingPathComponent("agent-installed") }

    static func ensure() {
        for dir in [golden, session, gateway, share, shareMeta] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Shell

struct ShellResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
}

enum Shell {
    static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPath + (env["PATH"]?.split(separator: ":").map(String.init) ?? [])).joined(separator: ":")
        return env
    }

    static func which(_ tool: String) -> String? {
        for dir in searchPath {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Blocking variant for short helper tools (tar, hdiutil, newfs_msdos…).
    @discardableResult
    static func runSync(_ launchPath: String, _ args: [String], env extra: [String: String] = [:]) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = environment.merging(extra) { $1 }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return ShellResult(status: -1, out: "", err: error.localizedDescription) }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus,
                           out: String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                           err: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 120) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                p.environment = environment
                if let cwd { p.currentDirectoryURL = cwd }
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(status: -1, out: "", err: error.localizedDescription)); return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                group.wait()
                cont.resume(returning: ShellResult(
                    status: p.terminationStatus,
                    out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.mahlas.app"

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Errors

struct MahlasError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
