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
    static let all: [ExitLocation] = [
        .init(code: "nl-ams", flag: "🇳🇱", displayName: "Amsterdam, Hollanda", timeZone: "Europe/Amsterdam"),
        .init(code: "de-fra", flag: "🇩🇪", displayName: "Frankfurt, Almanya", timeZone: "Europe/Berlin"),
        .init(code: "de-ber", flag: "🇩🇪", displayName: "Berlin, Almanya", timeZone: "Europe/Berlin"),
        .init(code: "se-sto", flag: "🇸🇪", displayName: "Stockholm, İsveç", timeZone: "Europe/Stockholm"),
        .init(code: "ch-zrh", flag: "🇨🇭", displayName: "Zürih, İsviçre", timeZone: "Europe/Zurich"),
        .init(code: "fr-par", flag: "🇫🇷", displayName: "Paris, Fransa", timeZone: "Europe/Paris"),
        .init(code: "es-mad", flag: "🇪🇸", displayName: "Madrid, İspanya", timeZone: "Europe/Madrid"),
        .init(code: "gb-lon", flag: "🇬🇧", displayName: "Londra, Birleşik Krallık", timeZone: "Europe/London"),
        .init(code: "ie-dub", flag: "🇮🇪", displayName: "Dublin, İrlanda", timeZone: "Europe/Dublin"),
        .init(code: "fi-hel", flag: "🇫🇮", displayName: "Helsinki, Finlandiya", timeZone: "Europe/Helsinki"),
        .init(code: "no-osl", flag: "🇳🇴", displayName: "Oslo, Norveç", timeZone: "Europe/Oslo"),
        .init(code: "dk-cph", flag: "🇩🇰", displayName: "Kopenhag, Danimarka", timeZone: "Europe/Copenhagen"),
        .init(code: "at-vie", flag: "🇦🇹", displayName: "Viyana, Avusturya", timeZone: "Europe/Vienna"),
        .init(code: "it-mil", flag: "🇮🇹", displayName: "Milano, İtalya", timeZone: "Europe/Rome"),
        .init(code: "pl-waw", flag: "🇵🇱", displayName: "Varşova, Polonya", timeZone: "Europe/Warsaw"),
        .init(code: "ro-buh", flag: "🇷🇴", displayName: "Bükreş, Romanya", timeZone: "Europe/Bucharest"),
        .init(code: "us-nyc", flag: "🇺🇸", displayName: "New York, ABD", timeZone: "America/New_York"),
        .init(code: "us-chi", flag: "🇺🇸", displayName: "Chicago, ABD", timeZone: "America/Chicago"),
        .init(code: "us-lax", flag: "🇺🇸", displayName: "Los Angeles, ABD", timeZone: "America/Los_Angeles"),
        .init(code: "ca-tor", flag: "🇨🇦", displayName: "Toronto, Kanada", timeZone: "America/Toronto"),
        .init(code: "jp-tyo", flag: "🇯🇵", displayName: "Tokyo, Japonya", timeZone: "Asia/Tokyo"),
        .init(code: "sg-sin", flag: "🇸🇬", displayName: "Singapur", timeZone: "Asia/Singapore"),
        .init(code: "au-syd", flag: "🇦🇺", displayName: "Sidney, Avustralya", timeZone: "Australia/Sydney"),
        .init(code: "br-sao", flag: "🇧🇷", displayName: "São Paulo, Brezilya", timeZone: "America/Sao_Paulo")
    ]
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
