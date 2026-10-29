import AppKit
import Foundation

/// Builds the candidate lists for Quick Clean and Purge. Nothing is ended here: the
/// user always reviews a checklist first.
@MainActor
enum Cleaner {
    /// Never offered by Quick Clean or Purge: ending these breaks the login session.
    static let protectedNames: Set<String> = [
        "loginwindow", "Finder", "Dock", "SystemUIServer", "WindowServer", "ControlCenter",
        "NotificationCenter", "launchd", "cfprefsd", "distnoted", "Spotlight", "secd", "trustd",
        "usernoted", "pboard", "UserEventAgent", "coreauthd", "lsd", "WindowManager", "TextInputMenuAgent",
    ]

    /// Names of macOS system processes. One running from outside a system folder is a disguise.
    static let systemNames: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "mds", "mds_stores", "mdworker",
        "mdworker_shared", "sshd", "syslogd", "coreaudiod", "cfprefsd", "distnoted", "trustd", "securityd",
        "finder", "dock", "systemuiserver", "softwareupdated", "nsurlsessiond", "rapportd", "sharingd",
        "bluetoothd", "airportd", "configd", "notifyd", "powerd", "diskarbitrationd", "fseventsd",
        "opendirectoryd", "coreservicesd", "spotlight", "xprotect", "mrt", "controlcenter",
    ]

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/"].contains { path.hasPrefix($0) }
    }

    static func isProtected(_ p: ProcInfo) -> Bool {
        p.id == getpid() || p.id <= 1 || p.isOtherUser || protectedNames.contains(p.name)
            || protectedNames.contains((p.path as NSString).lastPathComponent)
    }

    // MARK: Quick Clean

    /// Third-party background processes that started with the login session and are idle,
    /// plus anything on the user's unwanted list.
    static func quickClean(_ store: ProcessStore) -> CleanPlan {
        let all = Array(store.procs.values)
        let sessionStart = all.filter { !$0.isOtherUser }.map(\.start).min() ?? .distantPast
        let window = UserDefaults.standard.double(forKey: Prefs.cleanWindowMin) * 60
        let unwanted = Set(store.unwanted)

        let items: [CleanCandidate] = all.compactMap { p in
            guard !isProtected(p), !store.isKept(p) else { return nil }
            var reasons: [String] = []
            if unwanted.contains(p.name) { reasons.append("On your unwanted list") }
            if !isSystemPath(p.path), !p.path.isEmpty,
               p.start.timeIntervalSince(sessionStart) < window,
               store.avgCPU(p.id) < 1 {
                reasons.append(p.isApp ? "Opened at login, idle" : "Background item from login, idle")
            }
            return reasons.isEmpty ? nil : CleanCandidate(proc: p, reasons: reasons, checked: true)
        }
        return CleanPlan(kind: .quick, items: items.sorted { $0.proc.realMem > $1.proc.realMem })
    }

    // MARK: Fresh Start

    /// Everything you'd lose by restarting, without restarting: every app and third-party
    /// background process, except your Do Not Prune list and what Prune knows must stay.
    static func freshStart(_ store: ProcessStore) -> CleanPlan {
        let procs = store.procs
        let me = getpid()
        // Prune itself, and whatever launched it (e.g. the Terminal it was started from).
        var spared: Set<pid_t> = [me]
        if let self_ = procs[me] { spared.insert(self_.responsible) }
        for a in store.ancestors(of: me) { spared.insert(a.pid) }

        func keeps(_ p: ProcInfo) -> Bool {
            if isProtected(p) || store.isKept(p) || spared.contains(p.id) { return true }
            // Helpers belong to their app: spare them when the app is spared.
            if p.responsible != p.id, let owner = procs[p.responsible] {
                return isProtected(owner) || store.isKept(owner) || spared.contains(owner.id)
            }
            return false
        }

        var items: [CleanCandidate] = []
        for p in procs.values where !keeps(p) {
            if p.isApp {
                let helpers = procs.values.filter { $0.id != p.id && $0.responsible == p.id }.count
                items.append(CleanCandidate(proc: p, reasons: helpers > 0 ? ["App + \(helpers) helpers"] : ["App"], checked: true))
            } else if let owner = procs[p.responsible], owner.id != p.id, owner.isApp {
                continue  // quits along with its app
            } else if !isSystemPath(p.path), !p.path.isEmpty {
                items.append(CleanCandidate(proc: p, reasons: ["Background process"], checked: true))
            }
            // Background parts of macOS itself are left alone: they relaunch on demand anyway.
        }
        return CleanPlan(kind: .fresh, items: items.sorted {
            ($0.proc.isApp ? 0 : 1, $1.proc.realMem) < ($1.proc.isApp ? 0 : 1, $0.proc.realMem)
        })
    }

    // MARK: Purge

    static func purge(_ store: ProcessStore) async -> CleanPlan {
        let d = UserDefaults.standard
        let cpuLimit = d.double(forKey: Prefs.cpuThreshold)
        let memLimit = UInt64(d.double(forKey: Prefs.memThresholdGB) * Double(1 << 30))
        let gpuLimit = d.double(forKey: Prefs.gpuThreshold)
        let home = NSHomeDirectory()

        let conns = await Net.allUserConnections()
        var external: [pid_t: Int] = [:]
        for c in conns where c.isExternal && c.state == "ESTABLISHED" { external[c.pid, default: 0] += 1 }

        // Leave the app the user is working in (and its helpers) unchecked by default.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let items: [CleanCandidate] = store.procs.values.compactMap { p in
            guard !isProtected(p), !store.isKept(p) else { return nil }
            var strong: [String] = [], weak: [String] = []

            let avg = store.avgCPU(p.id)
            if avg > cpuLimit { strong.append("CPU \(Int(avg))%") }
            if p.realMem > memLimit { strong.append("Memory \(Fmt.bytes(p.realMem))") }
            if p.gpu > gpuLimit { strong.append("GPU \(Int(p.gpu))%") }

            let path = p.path
            if !path.isEmpty {
                if !FileManager.default.fileExists(atPath: path) { strong.append("Executable was deleted") }
                if ["/tmp/", "/private/tmp/", "/private/var/tmp/"].contains(where: path.hasPrefix) {
                    strong.append("Runs from a temp folder")
                }
                if path.hasPrefix(home + "/Downloads/") { strong.append("Runs from Downloads") }
                if path.contains("/AppTranslocation/") { weak.append("Quarantined app run in place") }
                if systemNames.contains((path as NSString).lastPathComponent.lowercased()), !isSystemPath(path) {
                    strong.append("System name at a non-system path")
                }
                let rel = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
                if rel.split(separator: "/").dropLast().contains(where: { $0.hasPrefix(".") }) {
                    weak.append("Runs from a hidden folder")
                }
            }

            if let n = external[p.id], !p.isApp, NSRunningApplication(processIdentifier: p.responsible)?.activationPolicy != .regular {
                weak.append("Background, \(n) internet connection\(n == 1 ? "" : "s")")
            }

            guard !strong.isEmpty || !weak.isEmpty else { return nil }
            let isFront = front != nil && (p.id == front || p.responsible == front)
            return CleanCandidate(proc: p, reasons: strong + weak, checked: !strong.isEmpty && !isFront)
        }
        return CleanPlan(kind: .purge, items: items.sorted {
            ($0.checked ? 0 : 1, $1.proc.realMem) < ($1.checked ? 0 : 1, $0.proc.realMem)
        })
    }
}
