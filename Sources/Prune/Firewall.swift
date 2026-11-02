import Foundation

// macPrune's firewall, a gentle version of NanoWall's: everything stays allowed, and only the
// addresses you choose are blocked: hosts from the connection map, and opt-in lists. The rules are
// loaded by Resources/firewall-helper.sh, which runs as root through macOS's password prompt and
// checks every address again itself.

/// Which addresses can be blocked: public IPv4 and global IPv6 (2000::/3) addresses and ranges,
/// IPv4 no wider than /8 and IPv6 no wider than /16, and no IPv4 range that overlaps private, local
/// or reserved space. The helper applies the same rules, so blocking can never cut off the LAN.
enum BlockAddress {
    /// The address in an lsof endpoint: "1.2.3.4:443" or "[2606:4700::1]:443".
    static func host(fromRemote remote: String) -> String? {
        if remote.hasPrefix("[") {
            guard let end = remote.firstIndex(of: "]") else { return nil }
            return String(remote[remote.index(after: remote.startIndex)..<end])
        }
        guard let colon = remote.lastIndex(of: ":") else { return remote }
        return String(remote[..<colon])
    }

    /// The canonical form of a blockable address or range (comments and spaces dropped), or nil.
    static func normalize(_ raw: String) -> String? {
        var s = raw.lowercased()
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        s.removeAll { $0 == " " || $0 == "\t" || $0 == "\r" }
        guard !s.isEmpty else { return nil }
        return isPublicV4(s) || isGlobalV6(s) ? s : nil
    }

    /// This network, private, CGNAT, loopback, link-local, private, IETF, private, benchmarking,
    /// multicast and reserved space.
    private static let reservedV4: [ClosedRange<UInt64>] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
    ].map { v4Range($0, widest: 0)! }

    static func isPublicV4(_ s: String) -> Bool {
        guard let r = v4Range(s) else { return false }
        return !reservedV4.contains { $0.overlaps(r) }
    }

    /// The addresses an IPv4 address or range covers; nil if it's malformed, wider than /`widest`,
    /// or has bits set past its prefix.
    private static func v4Range(_ s: String, widest: UInt64 = 8) -> ClosedRange<UInt64>? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        var prefix: UInt64 = 32
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let p = UInt64(parts[1]), (widest...32).contains(p) else { return nil }
            prefix = p
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt64 = 0
        for o in octets {
            guard (1...3).contains(o.count), o.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(o.count > 1 && o.first == "0"), let n = UInt64(o), n <= 255 else { return nil }
            value = value << 8 | n
        }
        let size: UInt64 = 1 << (32 - prefix)
        guard value % size == 0 else { return nil }
        return value...(value + size - 1)
    }

    static func isGlobalV6(_ s: String) -> Bool {
        guard s.range(of: #"^[23][0-9a-f]{0,3}(:[0-9a-f]{0,4}){2,7}(/[0-9]+)?$"#, options: .regularExpression) != nil
        else { return false }
        let parts = s.split(separator: "/")
        if parts.count == 2 {
            guard let p = Int(parts[1]), (16...128).contains(p) else { return false }
        }
        var addr = in6_addr()
        return inet_pton(AF_INET6, String(parts[0]), &addr) == 1
    }
}

/// An opt-in list of addresses, downloaded when it's turned on and refreshed weekly.
struct BlockList: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    var detail = ""

    static let firehol = BlockList(
        id: "firehol1", name: "Known attackers and malware (FireHOL Level 1)",
        url: URL(string: "https://iplists.firehol.org/files/firehol_level1.netset")!,
        detail: "About 4,500 ranges known for attacks and malware, picked to avoid false alarms. From iplists.firehol.org.")
    static let feodo = BlockList(
        id: "feodo", name: "Botnet control servers (abuse.ch Feodo Tracker)",
        url: URL(string: "https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt")!,
        detail: "Servers that run banking trojans and ransomware loaders such as Emotet and QakBot. Small and checked daily. From feodotracker.abuse.ch.")
    static let compromised = BlockList(
        id: "et-compromised", name: "Compromised hosts (Emerging Threats)",
        url: URL(string: "https://rules.emergingthreats.net/blockrules/compromised-ips.txt")!,
        detail: "Machines seen attacking others recently. Busier than the other two, so a shared server is occasionally caught. From rules.emergingthreats.net.")

    /// The threat lists you can turn on, in the order they're shown.
    static let threats = [firehol, feodo, compromised]

    /// A country's IPv4 ranges, from ipdeny.com. `code` is a two-letter ISO code.
    static func country(_ code: String) -> BlockList {
        let c = code.lowercased()
        return BlockList(id: "country-\(c)", name: countryName(code),
                         url: URL(string: "https://www.ipdeny.com/ipblocks/data/aggregated/\(c)-aggregated.zone")!)
    }

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    /// Every country, as (code, name), sorted by name, for the country picker.
    static let allCountries: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .map { ($0, countryName($0)) }
        .filter { $0.1 != $0.0 }
        .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }

    /// Two-letter country codes in free text ("KP, ir cn"), uppercased, deduplicated, in order.
    static func countryCodes(in text: String) -> [String] {
        var seen = Set<String>()
        return text.uppercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count == 2 && $0.allSatisfy(\.isASCII) && seen.insert($0).inserted }
    }

    /// The blockable entries of a downloaded list. Lists such as FireHOL Level 1 include private
    /// ranges on purpose (they never belong on the internet); those are skipped here, never blocked.
    static func parse(_ text: String) -> (entries: [String], skipped: Int) {
        var entries: [String] = [], seen = Set<String>(), skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if let e = BlockAddress.normalize(trimmed) {
                if seen.insert(e).inserted { entries.append(e) }
            } else {
                skipped += 1
            }
        }
        return (entries, skipped)
    }
}

struct BlockedHost: Codable, Hashable, Identifiable {
    var address: String
    /// Where it came from, e.g. "Safari → 203.0.113.9:443".
    var note: String
    var added: Date
    /// The followed app it was added for (FollowedApp.id); nil when you blocked it yourself.
    var app: String? = nil
    var id: String { address }
}

/// An app whose network is blocked. pf can only block addresses, so macPrune blocks every outside
/// address the app uses, and keeps adding new ones while it's open ("following").
struct FollowedApp: Codable, Hashable, Identifiable {
    /// The app's bundle path, or the program's path for a process outside an app.
    var id: String
    var name: String
    var added: Date
}

enum AppIdentity {
    /// The outermost .app around `path`, so helpers inside an app count as the app itself; a
    /// program outside any app is its own identity.
    static func of(path: String) -> String {
        guard let r = path.range(of: ".app/") else { return path }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

struct FirewallConfig: Codable, Equatable {
    var enabled = false
    var hosts: [BlockedHost] = []
    var lists: [String] = []
    var countries: [String] = []
    var apps: [FollowedApp] = []

    init() {}

    // A key that's missing (a file from an older version) keeps its default, so adding a setting
    // never throws away the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        hosts = try c.decodeIfPresent([BlockedHost].self, forKey: .hosts) ?? []
        lists = try c.decodeIfPresent([String].self, forKey: .lists) ?? []
        countries = try c.decodeIfPresent([String].self, forKey: .countries) ?? []
        apps = try c.decodeIfPresent([FollowedApp].self, forKey: .apps) ?? []
    }

    /// Outside addresses that followed apps are using and that aren't blocked yet, each once.
    /// `conns` are (pid, lsof remote endpoint); `appOf` maps a pid to its FollowedApp id.
    func newFollowedHosts(_ conns: [(pid: pid_t, remote: String)], appOf: (pid_t) -> String?) -> [(app: String, address: String)] {
        let followed = Set(apps.map(\.id))
        var seen = Set(hosts.map(\.address)), out: [(app: String, address: String)] = []
        for c in conns {
            guard let app = appOf(c.pid), followed.contains(app),
                  let host = BlockAddress.host(fromRemote: c.remote), let a = BlockAddress.normalize(host),
                  seen.insert(a).inserted else { continue }
            out.append((app, a))
        }
        return out
    }

    var listsInUse: [BlockList] {
        BlockList.threats.filter { lists.contains($0.id) } + countries.map(BlockList.country)
    }

    /// Every address to block: your hosts, then each list's, without duplicates.
    func entries(listEntries: (BlockList) -> [String]) -> [String] {
        var seen = Set<String>()
        let all = hosts.map(\.address) + listsInUse.flatMap(listEntries)
        return all.filter { seen.insert($0).inserted }
    }
}

enum FirewallStatus: Equatable {
    case off
    case on(Int)
    /// Turned on, but the rules aren't loaded: the Mac restarted since (pf forgets them).
    case paused

    /// From the helper's world-readable status file ("rules N", "boot SECONDS").
    static func from(statusFile: String?, bootTime: Int, enabled: Bool) -> FirewallStatus {
        var rules = 0, boot = 0
        for line in (statusFile ?? "").split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 2, let n = Int(f[1]) else { continue }
            if f[0] == "rules" { rules = n } else if f[0] == "boot" { boot = n }
        }
        if rules > 0 && boot == bootTime { return .on(rules) }
        return enabled ? .paused : .off
    }

    static func bootTime() -> Int {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }
}

/// Runs Resources/firewall-helper.sh as root through macOS's admin password prompt.
enum FirewallHelper {
    static let statusPath = "/var/db/macprune/status"

    struct Failure: Error, Equatable {
        let message: String
        var cancelled: Bool { message.contains("User canceled") || message.contains("(-128)") }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// The AppleScript that runs the helper with `args` as root.
    static func appleScript(helper: String, args: [String]) -> String {
        let command = (["/bin/sh", helper] + args).map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with prompt \"macPrune needs your password to change its firewall.\" "
            + "with administrator privileges"
    }

    static func run(_ args: [String]) async -> Result<String, Failure> {
        guard let helper = Bundle.main.path(forResource: "firewall-helper", ofType: "sh") else {
            return .failure(Failure(message: "The firewall helper is missing from the app. Rebuild it with scripts/build-app.sh."))
        }
        let script = appleScript(helper: helper, args: args)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: .failure(Failure(message: error.localizedDescription)))
                    return
                }
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? .success(o)
                            : .failure(Failure(message: e.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
        }
    }
}

/// The firewall settings, and applying them. A change takes effect only once the helper has
/// loaded it; if you cancel the password prompt or it fails, nothing changes.
@MainActor
final class FirewallStore: ObservableObject {
    @Published private(set) var config = FirewallConfig()
    @Published private(set) var status = FirewallStatus.off
    @Published private(set) var busy = false
    @Published var message: String?

    private let dir: URL
    private var configURL: URL { dir.appendingPathComponent("firewall.json") }
    nonisolated static let refreshAfter: TimeInterval = 7 * 24 * 3600

    /// True when a list downloaded at `updated` is due for a refresh.
    nonisolated static func isStale(_ updated: Date?, now: Date = Date()) -> Bool {
        guard let updated else { return true }
        return now.timeIntervalSince(updated) >= refreshAfter
    }

    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macPrune")) {
        self.dir = dir
        if let data = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(FirewallConfig.self, from: data) {
            config = c
        }
        refreshStatus()
    }

    func refreshStatus() {
        status = FirewallStatus.from(statusFile: try? String(contentsOfFile: FirewallHelper.statusPath, encoding: .utf8),
                                     bootTime: FirewallStatus.bootTime(), enabled: config.enabled)
    }

    func isBlocked(_ address: String) -> Bool { config.hosts.contains { $0.address == address } }

    // MARK: Apps

    /// Following is paused after you cancel its password prompt, until you block or resume an app.
    @Published private(set) var followPaused = false
    private var lastFollowPrompt = Date.distantPast
    /// At most one password prompt this often for addresses found by following.
    static let followPromptInterval: TimeInterval = 120

    func isFollowed(_ appID: String) -> Bool { config.apps.contains { $0.id == appID } }

    func hostCount(for appID: String) -> Int { config.hosts.filter { $0.app == appID }.count }

    /// Blocks `addresses` (the app's current outside addresses) and follows the app from now on.
    func blockApp(id: String, name: String, addresses: [String]) async {
        var c = config
        if !c.apps.contains(where: { $0.id == id }) { c.apps.append(FollowedApp(id: id, name: name, added: Date())) }
        let have = Set(c.hosts.map(\.address))
        for a in Set(addresses.compactMap(BlockAddress.normalize)).subtracting(have).sorted() {
            c.hosts.append(BlockedHost(address: a, note: "\(name) (blocked app)", added: Date(), app: id))
        }
        c.enabled = true
        if await commit(c) { followPaused = false }
    }

    /// Stops following an app and unblocks the addresses that were added for it.
    func unblockApp(_ id: String) async {
        var c = config
        c.apps.removeAll { $0.id == id }
        c.hosts.removeAll { $0.app == id }
        await commit(c)
    }

    func resumeFollowing() {
        followPaused = false
        lastFollowPrompt = .distantPast
    }

    /// One round of following: block the new addresses followed apps use, in one batch, at most
    /// one password prompt per `followPromptInterval`. A cancelled prompt pauses following.
    func follow(_ conns: [(pid: pid_t, remote: String)], appOf: (pid_t) -> String?, now: Date = Date()) async {
        guard config.enabled, !config.apps.isEmpty, !followPaused, !busy,
              now.timeIntervalSince(lastFollowPrompt) >= Self.followPromptInterval else { return }
        let found = config.newFollowedHosts(conns, appOf: appOf)
        guard !found.isEmpty else { return }
        lastFollowPrompt = now
        let names = Dictionary(config.apps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var c = config
        for f in found {
            c.hosts.append(BlockedHost(address: f.address, note: "\(names[f.app] ?? "App") (blocked app)", added: now, app: f.app))
        }
        if !(await commit(c)), lastCancelled {
            followPaused = true
            message = "Following blocked apps is paused because the password prompt was cancelled."
        }
    }

    func block(_ address: String, note: String) async {
        guard let a = BlockAddress.normalize(address), !isBlocked(a) else { return }
        var c = config
        c.hosts.append(BlockedHost(address: a, note: note, added: Date()))
        c.enabled = true
        await commit(c)
    }

    func unblock(_ address: String) async {
        var c = config
        c.hosts.removeAll { $0.address == address }
        await commit(c)
    }

    func setEnabled(_ on: Bool) async {
        var c = config
        c.enabled = on
        await commit(c)
    }

    func setList(_ list: BlockList, on: Bool) async {
        var c = config
        c.lists.removeAll { $0 == list.id }
        if on { c.lists.append(list.id); c.enabled = true }
        await commit(c)
    }

    func setCountries(_ text: String) async {
        var c = config
        c.countries = BlockList.countryCodes(in: text)
        if !c.countries.isEmpty { c.enabled = true }
        await commit(c)
    }

    func addCountry(_ code: String) async {
        guard !config.countries.contains(code) else { return }
        await setCountries((config.countries + [code]).joined(separator: " "))
    }

    func removeCountry(_ code: String) async {
        await setCountries(config.countries.filter { $0 != code }.joined(separator: " "))
    }

    /// When a list in use was last downloaded, or nil if it never was.
    func updated(_ list: BlockList) -> Date? {
        try? cacheURL(list).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The oldest download among the lists in use (nil: no lists, or one never downloaded).
    var oldestListUpdate: Date? {
        let dates = config.listsInUse.map(updated)
        return dates.contains(nil) ? nil : dates.compactMap { $0 }.min()
    }

    /// Lists are on and at least one is a week old: worth an Update.
    var listsNeedUpdate: Bool {
        config.enabled && !config.listsInUse.isEmpty && config.listsInUse.contains { Self.isStale(updated($0)) }
    }

    /// Downloads every list in use again and reloads the rules (one password prompt).
    func updateLists() async { await commit(config, force: true, redownload: true) }

    /// Loads the rules again, e.g. after a restart.
    func reapply() async { await commit(config, force: true) }

    private var lastCancelled = false

    /// Applies `new`; true if it took effect.
    @discardableResult
    private func commit(_ new: FirewallConfig, force: Bool = false, redownload: Bool = false) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false; refreshStatus() }
        message = nil
        do {
            var lists: [String: [String]] = [:]
            if new.enabled { for l in new.listsInUse { lists[l.id] = try await loadedList(l, redownload: redownload) } }
            let entries = new.enabled ? new.entries { lists[$0.id] ?? [] } : []
            if entries.isEmpty {
                // Nothing to block: remove the rules, unless they're already gone.
                if status != .off || force {
                    if case .failure(let f) = await FirewallHelper.run(["off"]) { fail(f); return false }
                }
            } else {
                let request = dir.appendingPathComponent("firewall-request.txt")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try (entries.joined(separator: "\n") + "\n").write(to: request, atomically: true, encoding: .utf8)
                if case .failure(let f) = await FirewallHelper.run(["apply", request.path]) { fail(f); return false }
            }
            config = new
            try JSONEncoder().encode(new).write(to: configURL, options: .atomic)
            lastCancelled = false
            return true
        } catch {
            message = error.localizedDescription
            lastCancelled = false
            return false
        }
    }

    private func fail(_ f: FirewallHelper.Failure) {
        lastCancelled = f.cancelled
        message = f.cancelled ? nil : f.message
    }

    // MARK: Lists

    private func cacheURL(_ list: BlockList) -> URL { dir.appendingPathComponent("lists/\(list.id).txt") }

    /// A list's entries from the cache, downloading it first if it's missing or a week old.
    private func loadedList(_ list: BlockList, redownload: Bool) async throws -> [String] {
        let url = cacheURL(list)
        if !redownload, !Self.isStale(updated(list)), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.split(separator: "\n").map(String.init)
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: list.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let entries = BlockList.parse(String(decoding: data, as: UTF8.self)).entries
            guard !entries.isEmpty else { throw URLError(.cannotParseResponse) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entries.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return entries
        } catch {
            // An old copy is better than nothing, except when you asked for an update; with no copy
            // at all, say which list failed.
            if !redownload, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.split(separator: "\n").map(String.init)
            }
            throw ListError(name: list.name, underlying: error.localizedDescription)
        }
    }

    struct ListError: LocalizedError {
        let name: String, underlying: String
        var errorDescription: String? { "Couldn't download “\(name)”: \(underlying)" }
    }
}
