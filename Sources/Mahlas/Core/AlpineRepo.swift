import Foundation

/// Mirrors a minimal, dependency-complete subset of Alpine's `main` repository
/// onto local disk. The original, Alpine-signed APKINDEX is kept unmodified, so
/// apk inside the gateway still verifies every package signature.
enum AlpineRepo {
    private struct Package {
        let name: String
        let version: String
        let deps: [String]
        let provides: [String]
        let installIf: [String]
        let priority: Int
    }

    static func mirror(packages wanted: [String], release: String, into dir: URL) async throws -> Int {
        let base = URL(string: "https://dl-cdn.alpinelinux.org/alpine/\(release)/main/aarch64/")!
        let arch = dir.appendingPathComponent("aarch64", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: arch, withIntermediateDirectories: true)

        let indexFile = arch.appendingPathComponent("APKINDEX.tar.gz")
        try await fetch(base.appendingPathComponent("APKINDEX.tar.gz"), to: indexFile)
        let r = Shell.runSync("/usr/bin/tar", ["-xzOf", indexFile.path, "APKINDEX"])
        guard r.ok, !r.out.isEmpty else { throw MahlasError("Alpine paket dizini okunamadı") }

        let index = parse(r.out)
        let selected = try resolve(wanted, in: index)
        for pkg in selected {
            let file = "\(pkg.name)-\(pkg.version).apk"
            try await fetch(base.appendingPathComponent(file), to: arch.appendingPathComponent(file))
        }
        return selected.count
    }

    private static func fetch(_ url: URL, to dst: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MahlasError("İndirilemedi: \(url.lastPathComponent)") }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private static func parse(_ text: String) -> [String: Package] {
        var out: [String: Package] = [:]
        for block in text.components(separatedBy: "\n\n") {
            var f: [Character: String] = [:]
            for line in block.split(separator: "\n") where line.count > 2 && line[line.index(after: line.startIndex)] == ":" {
                f[line.first!] = String(line.dropFirst(2))
            }
            guard let name = f["P"], let version = f["V"] else { continue }
            func list(_ k: Character) -> [String] { f[k]?.split(separator: " ").map(String.init) ?? [] }
            out[name] = Package(name: name, version: version, deps: list("D"), provides: list("p"),
                                installIf: list("i"), priority: Int(f["k"] ?? "0") ?? 0)
        }
        return out
    }

    /// "so:libc.musl-aarch64.so.1>=1.2" → "so:libc.musl-aarch64.so.1"
    private static func bare(_ token: String) -> String {
        String(token.prefix { !"<>=~".contains($0) })
    }

    private static func resolve(_ wanted: [String], in index: [String: Package]) throws -> [Package] {
        var providers: [String: [Package]] = [:]
        for p in index.values {
            providers[p.name, default: []].append(p)
            for token in p.provides { providers[bare(token), default: []].append(p) }
        }
        func pick(_ token: String) -> Package? {
            if let exact = index[token] { return exact }
            return providers[token]?.max { $0.priority < $1.priority }
        }

        var selected: [String: Package] = [:]
        var queue = wanted
        func drain() throws {
            while let token = queue.popLast() {
                guard let p = pick(token) else { throw MahlasError("Alpine paketi bulunamadı: \(token)") }
                guard selected[p.name] == nil else { continue }
                selected[p.name] = p
                queue += p.deps.filter { !$0.hasPrefix("!") }.map(bare)
            }
        }
        try drain()
        // apk auto-installs "install_if" packages once their conditions hold
        // (e.g. dnsmasq-openrc); they must be present on disk too.
        var changed = true
        while changed {
            changed = false
            for p in index.values where selected[p.name] == nil && !p.installIf.isEmpty {
                let conditions = p.installIf.filter { !$0.hasPrefix("!") }.map(bare)
                if conditions.allSatisfy({ c in pick(c).map { selected[$0.name] != nil } ?? false }) {
                    queue.append(p.name)
                    changed = true
                }
            }
            try drain()
        }
        return Array(selected.values)
    }
}
