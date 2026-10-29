import AppKit
import Foundation

enum Prefs {
    static let interval = "interval"
    static let cpuThreshold = "cpuThreshold"
    static let memThresholdGB = "memThresholdGB"
    static let gpuThreshold = "gpuThreshold"
    static let cleanWindowMin = "cleanWindowMin"
    static let unwanted = "unwanted"
    static let keep = "keep"
    static let showOthers = "showOthers"

    static func register() {
        UserDefaults.standard.register(defaults: [
            interval: 2.0, cpuThreshold: 80.0, memThresholdGB: 2.0,
            gpuThreshold: 50.0, cleanWindowMin: 5.0, unwanted: "", keep: "", showOthers: true,
        ])
    }
}

@MainActor
final class ProcessStore: ObservableObject {
    @Published private(set) var procs: [pid_t: ProcInfo] = [:]
    @Published var banner: String?
    @Published var scanning = false
    @Published private(set) var system = SystemMemory()

    private var cpuHistory: [pid_t: [Double]] = [:]
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "prune.sampler", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private let defaults = UserDefaults.standard

    init() {
        Prefs.register()
        Snapshot.scheduleIfRequested(self)
        tick()
        schedule()
        observeVisibility()
    }

    /// Full speed while Prune is in front or pinned; every 5 s in the background.
    func schedule() {
        timer?.invalidate()
        let base = max(defaults.double(forKey: Prefs.interval), 0.5)
        let watched = NSApp?.isActive ?? true || defaults.bool(forKey: "pinned")
        let interval = watched ? base : max(base, 5)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Nobody can see the window: minimized, hidden, or fully covered.
    private var isOffscreen: Bool {
        guard let app = NSApp, !app.windows.isEmpty else { return false }
        return app.isHidden || !app.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }

    private func observeVisibility() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
        // Catch up the moment the window is seen again.
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSApplication.didUnhideNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isOffscreen == false { self?.tick() } }
            }
        }
    }

    func tick() {
        guard !inFlight, !isOffscreen else { return }
        inFlight = true
        let sampler = sampler
        let includeOthers = defaults.bool(forKey: Prefs.showOthers)
        queue.async { [weak self] in
            let list = sampler.sample(includeOthers: includeOthers)
            let memory = SystemMemory.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.system = memory
                    self?.apply(list)
                }
            }
        }
    }

    private func apply(_ list: [ProcInfo]) {
        inFlight = false
        let apps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0.localizedName) })
        var next: [pid_t: ProcInfo] = [:]
        var history: [pid_t: [Double]] = [:]
        for var p in list {
            if let appName = apps[p.id] {
                p.isApp = true
                if let appName { p.name = appName }
            }
            next[p.id] = p
            history[p.id] = ((cpuHistory[p.id] ?? []) + [p.cpu]).suffix(3)
        }
        cpuHistory = history
        procs = next
    }

    func avgCPU(_ pid: pid_t) -> Double {
        guard let h = cpuHistory[pid], !h.isEmpty else { return 0 }
        return h.reduce(0, +) / Double(h.count)
    }

    // MARK: - Relationships

    /// Parent used for the tree: the real parent if we can see it, otherwise the app macOS
    /// holds responsible (so launchd-spawned XPC helpers nest under their app).
    func treeParent(of p: ProcInfo) -> pid_t? {
        if p.ppid > 1, procs[p.ppid] != nil { return p.ppid }
        if p.responsible != p.id, p.responsible > 1, procs[p.responsible] != nil { return p.responsible }
        return nil
    }

    private func parentMap() -> [pid_t: pid_t] {
        var map: [pid_t: pid_t] = [:]
        for p in procs.values { if let parent = treeParent(of: p) { map[p.id] = parent } }
        // Break any cycles so the tree stays finite.
        for pid in Array(map.keys) {
            var seen: Set<pid_t> = [pid]
            var cur = map[pid]
            while let c = cur {
                if seen.contains(c) { map[pid] = nil; break }
                seen.insert(c)
                cur = map[c]
            }
        }
        return map
    }

    /// A Do Not Prune process, or a helper of one. Hidden together by the Hide Protected toggle.
    func isProtectedFamily(_ p: ProcInfo) -> Bool {
        if isKept(p) { return true }
        guard p.responsible != p.id, let owner = procs[p.responsible] else { return false }
        return isKept(owner)
    }

    func rows(tree: Bool, filter: String, sort: [KeyPathComparator<ProcInfo>], hideKept: Bool = false) -> [ProcInfo] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ p: ProcInfo) -> Bool {
            q.isEmpty || p.name.lowercased().contains(q) || String(p.id) == q || p.path.lowercased().contains(q)
        }
        let keep = keepSet
        func visible(_ p: ProcInfo) -> Bool { !hideKept || keep.isEmpty || !isProtectedFamily(p) }
        guard tree else { return procs.values.filter { visible($0) && matches($0) }.sorted(using: sort) }

        let parents = parentMap()
        var kids: [pid_t: [pid_t]] = [:]
        for (child, parent) in parents { kids[parent, default: []].append(child) }

        func build(_ pid: pid_t) -> ProcInfo? {
            guard var node = procs[pid], visible(node) else { return nil }
            let children = (kids[pid] ?? []).compactMap(build).sorted(using: sort)
            guard matches(node) || !children.isEmpty else { return nil }
            node.children = children.isEmpty ? nil : children
            return node
        }
        return procs.keys.filter { parents[$0] == nil }.compactMap(build).sorted(using: sort)
    }

    func ancestors(of pid: pid_t) -> [(pid: pid_t, name: String, visible: Bool)] {
        var chain: [(pid_t, String, Bool)] = []
        var cur = procs[pid]?.ppid
        var seen: Set<pid_t> = [pid]
        while let c = cur, c > 0, !seen.contains(c) {
            seen.insert(c)
            if let p = procs[c] {
                chain.append((c, p.name, true))
                cur = p.ppid
            } else {
                chain.append((c, Sampler.name(of: c), false))
                break
            }
        }
        return chain
    }

    func children(of pid: pid_t) -> [ProcInfo] {
        procs.values.filter { $0.ppid == pid }.sorted { $0.realMem > $1.realMem }
    }

    /// Other processes macOS attributes to the same app.
    func appGroup(of pid: pid_t) -> [ProcInfo] {
        guard let p = procs[pid] else { return [] }
        return procs.values
            .filter { $0.id != pid && $0.responsible == p.responsible }
            .sorted { $0.realMem > $1.realMem }
    }

    func subtreeMemory(of pid: pid_t) -> UInt64 {
        let parents = parentMap()
        var kids: [pid_t: [pid_t]] = [:]
        for (child, parent) in parents { kids[parent, default: []].append(child) }
        func sum(_ p: pid_t) -> UInt64 { (procs[p]?.realMem ?? 0) + (kids[p] ?? []).reduce(0) { $0 + sum($1) } }
        return sum(pid)
    }

    // MARK: - Ending processes

    /// Quit gracefully (apps get a normal Quit, others SIGTERM) or force (SIGKILL).
    /// Other users' processes are signalled through one admin-password prompt.
    func end(_ pids: [pid_t], force: Bool) {
        let targets = pids.filter { $0 != getpid() }
        let others = targets.filter { procs[$0]?.isOtherUser == true }
        var failed: [String] = []
        for pid in targets where !others.contains(pid) {
            let name = procs[pid]?.name ?? "PID \(pid)"
            if !force, let app = NSRunningApplication(processIdentifier: pid), app.terminate() { continue }
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                failed.append("\(name) (\(String(cString: strerror(errno))))")
            }
        }
        guard !others.isEmpty else { return report(targets, force: force, failed: failed) }

        let cmd = "/bin/kill -\(force ? "KILL" : "TERM") \(others.map(String.init).joined(separator: " ")) || true"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(cmd)\" with administrator privileges"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.report(targets, force: force, failed: failed + (ok ? [] : ["other users' processes (admin access not granted)"]))
                }
            }
        }
    }

    private func report(_ attempted: [pid_t], force: Bool, failed: [String]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // EPERM means it exists but belongs to someone else, so it's still running.
                let alive = attempted.filter { kill($0, 0) == 0 || errno == EPERM }
                let ended = attempted.count - alive.count
                var msg = "Ended \(ended) of \(attempted.count) process\(attempted.count == 1 ? "" : "es")."
                if !alive.isEmpty && !force { msg += " \(alive.count) still running. Try Force Quit." }
                if !failed.isEmpty { msg += " Failed: " + failed.joined(separator: ", ") }
                self.banner = msg
                self.tick()
            }
        }
    }

    // MARK: - Unwanted list

    // Both lists are held in memory: the table checks them for every cell on every refresh.
    @Published var unwanted: [String] = ProcessStore.loadList(Prefs.unwanted) {
        didSet { unwantedSet = Set(unwanted); save(unwanted, Prefs.unwanted) }
    }
    private(set) lazy var unwantedSet = Set(unwanted)

    func isUnwanted(_ p: ProcInfo) -> Bool { unwantedSet.contains(p.name) }

    private static func loadList(_ key: String) -> [String] {
        Prefs.register()
        return UserDefaults.standard.string(forKey: key)?.split(separator: "\n").map(String.init) ?? []
    }

    private func save(_ list: [String], _ key: String) {
        let normalized = Array(Set(list)).sorted()
        defaults.set(normalized.joined(separator: "\n"), forKey: key)
    }

    func toggleUnwanted(_ name: String) {
        if unwanted.contains(name) {
            unwanted.removeAll { $0 == name }
        } else {
            unwanted.append(name)
            keep.removeAll { $0 == name }
        }
    }

    // MARK: - Do Not Prune list

    /// Names Quick Clean and Purge must never offer, shown highlighted green in the table.
    @Published var keep: [String] = ProcessStore.loadList(Prefs.keep) {
        didSet { keepSet = Set(keep); save(keep, Prefs.keep) }
    }
    private(set) lazy var keepSet = Set(keep)

    func isKept(_ p: ProcInfo) -> Bool { keepSet.contains(p.name) }

    /// Saves the Do Not Prune list as plain text, one process name per line.
    func exportKeep() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Do Not Prune.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (keep.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            banner = "Exported \(keep.count) names to \(url.lastPathComponent)."
        } catch {
            banner = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Merges names from a text file (one per line) into the Do Not Prune list.
    func importKeep() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let names = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let added = Set(names).subtracting(keep)
        keep += added
        unwanted.removeAll { added.contains($0) }
        banner = "Imported \(added.count) new name\(added.count == 1 ? "" : "s")."
    }

    func toggleKeep(_ name: String) {
        if keep.contains(name) {
            keep.removeAll { $0 == name }
        } else {
            keep.append(name)
            unwanted.removeAll { $0 == name }
        }
    }
}
