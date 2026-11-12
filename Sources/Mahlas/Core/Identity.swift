import Foundation

/// A Mullvad exit location paired with the matching IANA time zone, so the
/// machine's clock agrees with where its traffic appears to come from.
struct ExitLocation: Hashable, Codable {
    let code: String         // Mullvad location code, e.g. "nl-ams"
    let flag: String
    let displayName: String  // Turkish UI label
    let timeZone: String     // IANA time zone
}

enum Locations {
    /// Always exit in Turkey. Istanbul is Mullvad's only Turkish location;
    /// each session picks one of its relays at random.
    static let istanbul = ExitLocation(code: "tr-ist", flag: "🇹🇷", displayName: "İstanbul, Türkiye", timeZone: "Europe/Istanbul")
    static let all: [ExitLocation] = [istanbul]
}

/// Everything that makes one session look like a different physical Mac.
struct MachineIdentity: Codable, Equatable {
    var computerName: String     // "Elif's MacBook Pro"
    var localHostName: String    // "Elifs-MacBook-Pro"
    var model: String
    var macAddress: String
    var machineID: String        // short fingerprint of the VZ machine identifier
    var cpuCores: Int
    var ramGB: Int
    var display: Display
    var location: ExitLocation
    var relay: String?           // Mullvad relay hostname
    var createdAt: Date

    struct Display: Codable, Equatable {
        let width: Int, height: Int, ppi: Int
        var label: String { "\(width)×\(height)" }
    }

    /// Real Apple OUIs — a random-but-plausible MAC, not a "locally administered" VM one.
    private static let ouis = ["F0:18:98", "3C:22:FB", "A4:83:E7", "88:66:5A", "14:7D:DA", "BC:D0:74",
                               "F4:D4:88", "AC:BC:32", "8C:85:90", "D0:81:7A", "60:3E:5F", "1C:91:80"]
    private static let names = ["Elif", "Can", "Deniz", "Emma", "Liam", "Noah", "Mia", "Lukas", "Sofia", "Mateo",
                                "Yuki", "Hana", "Olivia", "Leo", "Nora", "Jonas", "Ava", "Elias", "Zoe", "Daniel",
                                "Sara", "Max", "Lena", "Omar", "Ines", "Arjun", "Maya", "Felix", "Clara", "Aiden"]
    private static let models = ["MacBook Pro", "MacBook Air", "Mac mini", "iMac", "MacBook Pro", "MacBook Air"]
    private static let displays = [Display(width: 1440, height: 900, ppi: 110), Display(width: 1680, height: 1050, ppi: 110),
                                   Display(width: 1920, height: 1080, ppi: 100), Display(width: 1920, height: 1200, ppi: 110),
                                   Display(width: 2560, height: 1440, ppi: 110), Display(width: 1512, height: 982, ppi: 110)]

    static func random(location fixed: ExitLocation? = nil, cores: ClosedRange<Int>, ramGB: [Int]) -> MachineIdentity {
        let name = names.randomElement()!
        let model = models.randomElement()!
        let possessive = name + "’s"
        let hex = Array("0123456789ABCDEF")
        let mac = ouis.randomElement()! + ":" + (0..<3).map { _ in String((0..<2).map { _ in hex.randomElement()! }) }.joined(separator: ":")
        return MachineIdentity(
            computerName: "\(possessive) \(model)",
            localHostName: "\(name)s-\(model.replacingOccurrences(of: " ", with: "-"))",
            model: model,
            macAddress: mac,
            machineID: "",
            cpuCores: Int.random(in: cores),
            ramGB: ramGB.randomElement() ?? 4,
            display: displays.randomElement()!,
            location: fixed ?? Locations.all.randomElement()!,
            relay: nil,
            createdAt: Date()
        )
    }

    /// Plain key=value file the in-guest agent reads at boot (never sourced as code).
    var guestConfig: String {
        "NAME=\(computerName)\nLOCALNAME=\(localHostName)\nTZ=\(location.timeZone)\n"
    }
}
