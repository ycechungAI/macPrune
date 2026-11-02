import Foundation
import Testing
@testable import Prune

@Suite struct BlockAddressTests {
    static let blockable = [
        "203.0.113.9", "8.8.8.8", "198.51.100.0/24", "11.0.0.0/8", "2606:4700:4700::1111", "2001:db8::/32",
        "1.1.1.1/32", "223.255.255.255",
    ]
    static let refused = [
        "10.1.2.3", "192.168.1.1", "172.20.0.0/16", "127.0.0.1", "169.254.1.1", "100.64.0.1", "224.0.0.1",
        "0.0.0.0/0", "1.0.0.0/7", "192.0.0.0/8", "172.0.0.0/8", "8.8.8.0/16", "256.1.1.1", "1.2.3", "01.2.3.4",
        "1.2.3.4/33", "1.2.3.4/", "fe80::1", "fd00::1", "::1", "ff02::1", "2001:db8::/8", "2001:db8::/129",
        "1.2.3.4; rm -rf /", "$(reboot)", "example.com", "２.２.２.２", "1.2.3.4/0x8", "2:::1:::",
    ]

    @Test(arguments: blockable) func blockable(_ a: String) { #expect(BlockAddress.normalize(a) == a) }
    @Test(arguments: refused) func refused(_ a: String) { #expect(BlockAddress.normalize(a) == nil) }

    @Test func commentsSpacesAndCase() {
        #expect(BlockAddress.normalize("  8.8.8.8   # Google DNS") == "8.8.8.8")
        #expect(BlockAddress.normalize("2606:4700::ABCD") == "2606:4700::abcd")
        #expect(BlockAddress.normalize("# only a comment") == nil)
    }

    @Test func hostsFromLsofEndpoints() {
        #expect(BlockAddress.host(fromRemote: "203.0.113.9:443") == "203.0.113.9")
        #expect(BlockAddress.host(fromRemote: "[2606:4700::1111]:443") == "2606:4700::1111")
        #expect(BlockAddress.host(fromRemote: "[broken") == nil)
    }

    /// The app and the root helper must agree on every address, so the app never offers to block
    /// something the helper would refuse (and the helper never takes what the app wouldn't).
    @Test func agreesWithTheHelper() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/firewall-helper.sh").standardized.path
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for a in Self.blockable + Self.refused {
            let file = dir.appendingPathComponent("in.txt")
            try (a + "\n").write(to: file, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [helper, "apply", file.path]
            p.environment = ["MACPRUNE_HELPER_DRYRUN": dir.appendingPathComponent("state").path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect((p.terminationStatus == 0) == (BlockAddress.normalize(a) != nil), "disagree on \(a)")
        }
    }

    /// The helper's status must carry the same boot time the app reads, or the app would show
    /// "paused" while the rules are live.
    @Test func helperStatusMatchesTheAppsBootTime() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/firewall-helper.sh").standardized.path
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("in.txt")
        try "8.8.8.8\n".write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [helper, "apply", file.path]
        p.environment = ["MACPRUNE_HELPER_DRYRUN": dir.appendingPathComponent("state").path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let status = try String(contentsOf: dir.appendingPathComponent("state/status"), encoding: .utf8)
        #expect(FirewallStatus.from(statusFile: status, bootTime: FirewallStatus.bootTime(), enabled: true) == .on(1))
    }
}

@Suite struct BlockListTests {
    @Test func fireholStyleListSkipsPrivateRanges() {
        let text = """
            #
            # firehol_level1
            #
            0.0.0.0/8
            1.10.16.0/20
            10.0.0.0/8
            5.188.10.0/23
            192.168.0.0/16
            224.0.0.0/3
            5.188.10.0/23
            """
        let (entries, skipped) = BlockList.parse(text)
        #expect(entries == ["1.10.16.0/20", "5.188.10.0/23"])
        #expect(skipped == 4)
    }

    @Test func threatListCatalog() {
        let ids = BlockList.threats.map(\.id)
        #expect(ids == ["firehol1", "feodo", "et-compromised"])
        #expect(Set(ids).count == ids.count)
        for l in BlockList.threats { #expect(l.url.scheme == "https" && !l.detail.isEmpty) }
    }

    @Test func plainIPListsParse() {
        // Feodo Tracker and Emerging Threats: one address per line, comments start with #
        let text = "# Feodo Tracker\n# Generated 2026-11-02\n162.243.103.246\n50.16.16.211\n\n10.0.0.5\n"
        #expect(BlockList.parse(text) == (entries: ["162.243.103.246", "50.16.16.211"], skipped: 1))
    }

    @Test func everyCountryHasANameAndAppearsOnce() {
        let codes = BlockList.allCountries.map(\.code)
        #expect(codes.count > 200 && Set(codes).count == codes.count)
        #expect(codes.contains("KP") && codes.contains("US"))
        let names = BlockList.allCountries.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func listsGoStaleAfterAWeek() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(FirewallStore.isStale(nil, now: now))
        #expect(!FirewallStore.isStale(now.addingTimeInterval(-6 * 24 * 3600), now: now))
        #expect(FirewallStore.isStale(now.addingTimeInterval(-7 * 24 * 3600), now: now))
    }

    @Test func countryCodes() {
        #expect(BlockList.countryCodes(in: "kp, IR  cn kp usa x") == ["KP", "IR", "CN"])
        #expect(BlockList.country("kp").url.absoluteString == "https://www.ipdeny.com/ipblocks/data/aggregated/kp-aggregated.zone")
        #expect(BlockList.country("KP").id == "country-kp")
    }
}

@Suite struct FirewallConfigTests {
    @Test func entriesAreHostsThenListsWithoutDuplicates() {
        var c = FirewallConfig()
        c.hosts = [BlockedHost(address: "8.8.8.8", note: "", added: .now), BlockedHost(address: "1.1.1.1", note: "", added: .now)]
        c.lists = [BlockList.firehol.id, "unknown-list"]
        c.countries = ["KP"]
        let lists = ["firehol1": ["5.188.10.0/23", "8.8.8.8"], "country-kp": ["175.45.176.0/22"]]
        #expect(c.entries { lists[$0.id] ?? [] } == ["8.8.8.8", "1.1.1.1", "5.188.10.0/23", "175.45.176.0/22"])
        #expect(c.listsInUse.map(\.id) == ["firehol1", "country-kp"])
    }

    @Test func roundTrips() throws {
        var c = FirewallConfig()
        c.enabled = true
        c.hosts = [BlockedHost(address: "8.8.8.8", note: "Safari → 8.8.8.8:443", added: Date(timeIntervalSince1970: 1_000))]
        c.countries = ["IR"]
        #expect(try JSONDecoder().decode(FirewallConfig.self, from: JSONEncoder().encode(c)) == c)
    }
}

@Suite struct BlockedAppTests {
    @Test func helpersCountAsTheirApp() {
        #expect(AppIdentity.of(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
                == "/Applications/Google Chrome.app")
        #expect(AppIdentity.of(path: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        #expect(AppIdentity.of(path: "/usr/local/bin/ollama") == "/usr/local/bin/ollama")
    }

    /// A firewall.json from before blocked apps existed must keep every setting it has.
    @Test func olderSettingsFilesStillLoad() throws {
        let json = #"{"enabled":true,"hosts":[{"address":"8.8.8.8","note":"x","added":0}],"lists":["feodo","firehol1"],"countries":["CN","RU"]}"#
        let c = try JSONDecoder().decode(FirewallConfig.self, from: Data(json.utf8))
        #expect(c.enabled && c.lists == ["feodo", "firehol1"] && c.countries == ["CN", "RU"])
        #expect(c.hosts.map(\.address) == ["8.8.8.8"] && c.hosts[0].app == nil && c.apps.isEmpty)
    }

    @Test func followingFindsOnlyNewOutsideAddressesOfFollowedApps() {
        var c = FirewallConfig()
        c.apps = [FollowedApp(id: "/Applications/Chat.app", name: "Chat", added: .now)]
        c.hosts = [BlockedHost(address: "203.0.113.9", note: "", added: .now, app: "/Applications/Chat.app")]
        let appOf: (pid_t) -> String? = { [10: "/Applications/Chat.app", 11: "/Applications/Chat.app", 20: "/Applications/Other.app"][$0] }
        let conns: [(pid: pid_t, remote: String)] = [
            (10, "203.0.113.9:443"),      // already blocked
            (10, "198.51.100.7:443"),     // new
            (11, "198.51.100.7:5228"),    // same address from a helper: once
            (11, "[2606:4700::1111]:443"),// new, IPv6
            (11, "192.168.1.20:8009"),    // the LAN: never
            (20, "192.0.2.99:443"),       // another app: not followed
            (99, "198.51.100.8:443"),     // unknown process
        ]
        let found = c.newFollowedHosts(conns, appOf: appOf)
        #expect(found.map(\.address) == ["198.51.100.7", "2606:4700::1111"])
        #expect(found.allSatisfy { $0.app == "/Applications/Chat.app" })
    }
}

@Suite struct FirewallStatusTests {
    @Test func loadedThisBoot() {
        #expect(FirewallStatus.from(statusFile: "rules 12\nboot 500\n", bootTime: 500, enabled: true) == .on(12))
    }

    @Test func restartedSinceMeansPaused() {
        #expect(FirewallStatus.from(statusFile: "rules 12\nboot 400\n", bootTime: 500, enabled: true) == .paused)
        #expect(FirewallStatus.from(statusFile: nil, bootTime: 500, enabled: true) == .paused)
    }

    @Test func off() {
        #expect(FirewallStatus.from(statusFile: "rules 0\nboot 500\n", bootTime: 500, enabled: false) == .off)
        #expect(FirewallStatus.from(statusFile: nil, bootTime: 500, enabled: false) == .off)
        #expect(FirewallStatus.bootTime() > 0)
    }
}

@Suite struct FirewallHelperTests {
    @Test func scriptQuotesPathsAndArguments() {
        let s = FirewallHelper.appleScript(helper: "/Applications/My \"Prune\".app/x.sh", args: ["apply", "/Users/o'brien/req.txt"])
        #expect(s.hasPrefix(#"do shell script "'/bin/sh' '/Applications/My \"Prune\".app/x.sh' 'apply' '/Users/o'\\''brien/req.txt'""#))
        #expect(s.hasSuffix("with administrator privileges"))
    }

    @Test func cancelling() {
        #expect(FirewallHelper.Failure(message: "execution error: User canceled. (-128)").cancelled)
        #expect(!FirewallHelper.Failure(message: "error: pf rejected the new rules").cancelled)
    }
}
