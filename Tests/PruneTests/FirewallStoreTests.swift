import Foundation
import Testing
@testable import Prune

/// The firewall end to end, without root: FirewallStore drives the real Resources/firewall-helper.sh
/// in dry-run mode (its own checks and `pfctl -n` run for real; only loading into pf is skipped),
/// with downloads served from memory and the password prompt simulated.
@MainActor
final class Harness {
    let dir: URL
    let state: URL
    var calls: [[String]] = []
    var cancelNext = false
    var failNext: String?
    var bodies: [String: String] = [:]
    var downloadsFail = false
    private(set) var downloads = 0
    private static let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/firewall-helper.sh").standardized.path

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)")
        state = dir.appendingPathComponent("helper-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func makeStore() -> FirewallStore {
        FirewallStore(dir: dir.appendingPathComponent("app"), statusPath: state.appendingPathComponent("status").path,
                      runHelper: { [unowned self] args in self.run(args) },
                      download: { [unowned self] url in try self.fetch(url) })
    }

    private func run(_ args: [String]) -> Result<String, FirewallHelper.Failure> {
        calls.append(args)
        if cancelNext { cancelNext = false; return .failure(.init(message: "execution error: User canceled. (-128)")) }
        if let f = failNext { failNext = nil; return .failure(.init(message: f)) }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [Self.helper] + args
        p.environment = ["MACPRUNE_HELPER_DRYRUN": state.path]
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(.init(message: "\(error)")) }
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return p.terminationStatus == 0 ? .success(o) : .failure(.init(message: e))
    }

    private func fetch(_ url: URL) throws -> (Data, Int) {
        downloads += 1
        if downloadsFail { throw URLError(.notConnectedToInternet) }
        guard let body = bodies[url.absoluteString] else { return (Data(), 404) }
        return (Data(body.utf8), 200)
    }

    /// What the helper would have loaded into pf.
    var blocked: [String] {
        ((try? String(contentsOf: state.appendingPathComponent("blocked.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func age(_ list: BlockList, days: Double) throws {
        let file = dir.appendingPathComponent("app/lists/\(list.id).txt")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)],
                                              ofItemAtPath: file.path)
    }
}

let fireholSample = """
    # firehol_level1
    0.0.0.0/8
    5.188.10.0/23
    10.0.0.0/8
    31.184.192.0/19
    192.168.0.0/16
    """

@MainActor
@Suite(.serialized) struct FirewallStoreTests {
    // MARK: Hosts

    @Test func blockingAHostAppliesAndIsRemembered() async throws {
        let h = try Harness()
        let s = h.makeStore()
        await s.block("203.0.113.9", note: "Safari → 203.0.113.9:443")
        #expect(s.status == .on(1) && h.blocked == ["203.0.113.9"])
        #expect(h.calls.last?.first == "apply" && s.message == nil)
        let again = h.makeStore()  // a new launch reads the saved settings
        #expect(again.isBlocked("203.0.113.9") && again.config.enabled && again.status == .on(1))
    }

    @Test func theLocalNetworkCanNeverBeBlocked() async throws {
        let h = try Harness()
        let s = h.makeStore()
        for a in ["192.168.1.5", "10.0.0.1", "127.0.0.1", "fe80::1", "not an address"] { await s.block(a, note: "") }
        #expect(h.calls.isEmpty && s.config.hosts.isEmpty && s.status == .off)
    }

    @Test func cancellingThePasswordPromptChangesNothing() async throws {
        let h = try Harness()
        let s = h.makeStore()
        h.cancelNext = true
        await s.block("203.0.113.9", note: "")
        #expect(s.config.hosts.isEmpty && s.message == nil && s.status == .off && h.blocked.isEmpty)
        #expect(h.makeStore().config.hosts.isEmpty)  // nothing was saved
    }

    @Test func aHelperErrorIsShownAndChangesNothing() async throws {
        let h = try Harness()
        let s = h.makeStore()
        h.failNext = "error: pf rejected the new rules; nothing changed"
        await s.block("203.0.113.9", note: "")
        #expect(s.message?.contains("pf rejected") == true && s.config.hosts.isEmpty && s.status == .off)
    }

    @Test func unblockingTheLastHostTurnsTheRulesOff() async throws {
        let h = try Harness()
        let s = h.makeStore()
        await s.block("203.0.113.9", note: "")
        await s.unblock("203.0.113.9")
        #expect(h.calls.last == ["off"] && s.status == .off && h.blocked.isEmpty)
    }

    @Test func turningOffKeepsTheSettingsAndTurningOnRestoresThem() async throws {
        let h = try Harness()
        let s = h.makeStore()
        await s.block("203.0.113.9", note: "")
        await s.setEnabled(false)
        #expect(s.status == .off && s.config.hosts.count == 1 && h.calls.last == ["off"])
        await s.setEnabled(true)
        #expect(s.status == .on(1) && h.blocked == ["203.0.113.9"])
    }

    @Test func afterARestartItShowsPausedUntilTurnedBackOn() async throws {
        let h = try Harness()
        let s = h.makeStore()
        await s.block("203.0.113.9", note: "")
        try "rules 1\nboot 1\n".write(to: h.state.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        s.refreshStatus()
        #expect(s.status == .paused)
        await s.reapply()
        #expect(s.status == .on(1))
    }

    // MARK: Lists and countries

    @Test func aThreatListIsDownloadedFilteredAndCached() async throws {
        let h = try Harness()
        h.bodies[BlockList.firehol.url.absoluteString] = fireholSample
        let s = h.makeStore()
        await s.setList(.firehol, on: true)
        #expect(h.blocked == ["5.188.10.0/23", "31.184.192.0/19"])  // private ranges in the list are left out
        #expect(s.updated(.firehol) != nil && !s.listsNeedUpdate && s.status == .on(2))
        await s.block("203.0.113.9", note: "")  // a fresh cache isn't downloaded again
        #expect(h.downloads == 1 && h.blocked.count == 3)
    }

    @Test func aFailedDownloadChangesNothingAndSaysWhich() async throws {
        let h = try Harness()
        h.downloadsFail = true
        let s = h.makeStore()
        await s.setList(.feodo, on: true)
        #expect(s.message?.contains("Couldn't download “\(BlockList.feodo.name)”") == true)
        #expect(s.config.lists.isEmpty && h.calls.isEmpty)
    }

    @Test func aWeekOldListIsFlaggedAndUpdateNowFetchesIt() async throws {
        let h = try Harness()
        h.bodies[BlockList.firehol.url.absoluteString] = fireholSample
        let s = h.makeStore()
        await s.setList(.firehol, on: true)
        try h.age(.firehol, days: 8)
        #expect(s.listsNeedUpdate)
        h.bodies[BlockList.firehol.url.absoluteString] = fireholSample + "\n45.95.147.0/24\n"
        await s.updateLists()
        #expect(h.blocked.contains("45.95.147.0/24") && !s.listsNeedUpdate && s.message == nil)
    }

    @Test func updateNowReportsAFailedDownloadAndKeepsTheRules() async throws {
        let h = try Harness()
        h.bodies[BlockList.firehol.url.absoluteString] = fireholSample
        let s = h.makeStore()
        await s.setList(.firehol, on: true)
        let before = h.blocked
        h.downloadsFail = true
        await s.updateLists()
        #expect(s.message?.contains("Couldn't download") == true && h.blocked == before)
    }

    @Test func otherChangesUseTheOldCopyWhenADownloadFails() async throws {
        let h = try Harness()
        h.bodies[BlockList.firehol.url.absoluteString] = fireholSample
        let s = h.makeStore()
        await s.setList(.firehol, on: true)
        try h.age(.firehol, days: 8)
        h.downloadsFail = true
        await s.block("203.0.113.9", note: "")
        #expect(s.message == nil && h.blocked.contains("5.188.10.0/23") && h.blocked.contains("203.0.113.9"))
    }

    @Test func countriesAreAddedAndRemoved() async throws {
        let h = try Harness()
        h.bodies[BlockList.country("KP").url.absoluteString] = "175.45.176.0/22\n"
        h.bodies[BlockList.country("IR").url.absoluteString] = "2.144.0.0/14\n5.22.0.0/17\n"
        let s = h.makeStore()
        await s.addCountry("KP")
        await s.addCountry("IR")
        await s.addCountry("KP")  // already there: no change
        #expect(s.config.countries == ["KP", "IR"] && h.blocked.count == 3)
        await s.removeCountry("KP")
        #expect(s.config.countries == ["IR"] && h.blocked == ["2.144.0.0/14", "5.22.0.0/17"])
        await s.removeCountry("IR")
        #expect(s.status == .off)
    }

    // MARK: Blocked apps

    @Test func blockingAnAppTagsItsAddressesAndUnblockingRemovesOnlyThose() async throws {
        let h = try Harness()
        let s = h.makeStore()
        await s.block("198.51.100.1", note: "mine")
        await s.blockApp(id: "/Applications/Chat.app", name: "Chat", addresses: ["203.0.113.5", "198.51.100.1", "10.0.0.9"])
        #expect(s.isFollowed("/Applications/Chat.app") && s.hostCount(for: "/Applications/Chat.app") == 1)
        #expect(Set(h.blocked) == ["198.51.100.1", "203.0.113.5"])  // the LAN address is skipped
        await s.unblockApp("/Applications/Chat.app")
        #expect(!s.isFollowed("/Applications/Chat.app") && h.blocked == ["198.51.100.1"])
    }

    @Test func followingBlocksNewAddressesAtMostEveryTwoMinutes() async throws {
        let h = try Harness()
        let s = h.makeStore()
        let chat = "/Applications/Chat.app"
        await s.blockApp(id: chat, name: "Chat", addresses: [])
        let appOf: (pid_t) -> String? = { $0 == 7 ? chat : nil }
        let t0 = Date()
        await s.follow([(7, "203.0.113.20:443")], appOf: appOf, now: t0)
        #expect(h.blocked.contains("203.0.113.20"))
        await s.follow([(7, "203.0.113.21:443")], appOf: appOf, now: t0 + 30)
        #expect(!h.blocked.contains("203.0.113.21"))  // too soon for another password prompt
        await s.follow([(7, "203.0.113.21:443")], appOf: appOf, now: t0 + 121)
        #expect(h.blocked.contains("203.0.113.21") && s.hostCount(for: chat) == 2)
        await s.follow([(8, "203.0.113.30:443")], appOf: appOf, now: t0 + 300)  // another app: ignored
        #expect(!h.blocked.contains("203.0.113.30"))
    }

    @Test func cancellingFollowingsPromptPausesItUntilResumed() async throws {
        let h = try Harness()
        let s = h.makeStore()
        let chat = "/Applications/Chat.app"
        await s.blockApp(id: chat, name: "Chat", addresses: ["203.0.113.5"])
        let appOf: (pid_t) -> String? = { _ in chat }
        let t0 = Date()
        h.cancelNext = true
        await s.follow([(1, "203.0.113.40:443")], appOf: appOf, now: t0)
        #expect(s.followPaused && s.message?.contains("paused") == true && !h.blocked.contains("203.0.113.40"))
        let calls = h.calls.count
        await s.follow([(1, "203.0.113.40:443")], appOf: appOf, now: t0 + 600)
        #expect(h.calls.count == calls)  // no new prompt while paused
        s.resumeFollowing()
        await s.follow([(1, "203.0.113.40:443")], appOf: appOf, now: t0 + 700)
        #expect(!s.followPaused && h.blocked.contains("203.0.113.40"))
    }

    // MARK: Which app a process belongs to

    @Test func helpersBelongToTheAppMacOSHoldsResponsible() {
        func proc(_ pid: pid_t, _ responsible: pid_t, _ name: String, _ path: String) -> ProcInfo {
            ProcInfo(id: pid, ppid: 1, responsible: responsible, name: name, path: path, user: "me", realMem: 0,
                     threads: 1, cpuTime: 0, cpu: 0, gpu: 0, start: .now)
        }
        let browser = proc(100, 100, "Brave Browser", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
        let helper = proc(101, 100, "Brave Browser Helper", "/Applications/Brave Browser.app/Contents/Frameworks/x.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper")
        let tool = proc(200, 200, "ollama", "/usr/local/bin/ollama")
        let unknown = proc(300, 300, "ghost", "")
        let procs = Dictionary(uniqueKeysWithValues: [browser, helper, tool, unknown].map { ($0.id, $0) })
        #expect(AppIdentity.owner(of: helper, in: procs)! == ("/Applications/Brave Browser.app", "Brave Browser"))
        #expect(AppIdentity.owner(of: tool, in: procs)! == ("/usr/local/bin/ollama", "ollama"))
        #expect(AppIdentity.owner(of: unknown, in: procs) == nil)
    }
}
