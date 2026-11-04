import Foundation
import CryptoKit

/// Talks to Mullvad's public account API to register / rotate WireGuard keys,
/// so the user only has to type their account number.
enum Mullvad {
    struct Device: Decodable {
        let id: String
        let name: String?
        let pubkey: String
        let ipv4_address: String
        let ipv6_address: String?
    }

    struct Account: Decodable {
        let expiry: String
    }

    struct ExitCheck: Decodable {
        let ip: String
        let country: String?
        let city: String?
        let mullvad_exit_ip: Bool?
        let mullvad_exit_ip_hostname: String?
        let organization: String?
    }

    struct Relay: Decodable {
        let hostname: String
        let location: String
        let active: Bool
        let ipv4_addr_in: String
        let public_key: String
        let owned: Bool?
    }

    private struct RelayList: Decodable {
        struct WG: Decodable { let relays: [Relay] }
        let wireguard: WG
    }

    /// Active WireGuard relays for a location code (e.g. "nl-ams").
    static func relays(in location: String) async throws -> [Relay] {
        var req = URLRequest(url: api.appendingPathComponent("public/relays/wireguard/v2/"))
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        let list = try JSONDecoder().decode(RelayList.self, from: data)
        return list.wireguard.relays.filter { $0.active && $0.location == location }
    }

    private struct APIError: Decodable { let code: String?; let detail: String? }

    private static let api = URL(string: "https://api.mullvad.net")!

    // MARK: Keys

    /// WireGuard keys are plain Curve25519 (X25519) keys, base64 encoded.
    static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    static func publicKey(for privateKey: String) -> String? {
        guard let raw = Data(base64Encoded: privateKey),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    static func normalize(account: String) -> String {
        account.filter(\.isNumber)
    }

    // MARK: API

    static func token(account: String) async throws -> String {
        struct R: Decodable { let access_token: String }
        let r: R = try await request("auth/v1/token", method: "POST", body: ["account_number": normalize(account: account)])
        return r.access_token
    }

    static func account(token: String) async throws -> Account {
        try await request("accounts/v1/accounts/me", token: token)
    }

    static func createDevice(token: String, publicKey: String) async throws -> Device {
        try await request("accounts/v1/devices", method: "POST", token: token,
                          body: ["pubkey": publicKey, "hijack_dns": false])
    }

    static func rotate(token: String, deviceID: String, publicKey: String) async throws -> Device {
        try await request("accounts/v1/devices/\(deviceID)/pubkey", method: "PUT", token: token,
                          body: ["pubkey": publicKey])
    }

    private static func request<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil,
                                               body: [String: Any]? = nil) async throws -> T {
        var req = URLRequest(url: api.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let e = try? JSONDecoder().decode(APIError.self, from: data)
            switch e?.code {
            case "INVALID_ACCOUNT": throw MahlasError("Mullvad hesap numarası geçersiz.")
            case "MAX_DEVICES_REACHED": throw MahlasError("Mullvad hesabında cihaz sınırına (5) ulaşıldı. mullvad.net üzerinden bir cihazı kaldırın.")
            default: throw MahlasError("Mullvad API hatası (\(code)): \(e?.detail ?? e?.code ?? "bilinmeyen")")
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Persistent WireGuard credentials. The private key lives only in the Keychain.
struct WireGuardCredentials {
    var privateKey: String
    var address: String
    var deviceID: String?

    static func load() -> WireGuardCredentials? {
        guard let key = Keychain.get("wg.private"), let addr = Keychain.get("wg.address") else { return nil }
        return .init(privateKey: key, address: addr, deviceID: Keychain.get("wg.device"))
    }

    func save() {
        Keychain.set(privateKey, for: "wg.private")
        Keychain.set(address, for: "wg.address")
        Keychain.set(deviceID, for: "wg.device")
    }

    static func clear() {
        for k in ["wg.private", "wg.address", "wg.device", "mullvad.account"] { Keychain.set(nil, for: k) }
    }
}
