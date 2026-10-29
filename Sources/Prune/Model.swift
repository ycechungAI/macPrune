import Foundation

/// One sampled process. `children` is only filled when rows are built as a tree.
struct ProcInfo: Identifiable {
    let id: pid_t
    var ppid: pid_t
    /// The app macOS holds responsible for this process (e.g. Safari for its WebKit XPC services).
    var responsible: pid_t
    var name: String
    var path: String
    var user: String
    var realMem: UInt64
    /// -1 when unknown (other users' processes, which only `ps` can read).
    var threads: Int
    /// Total CPU seconds consumed since launch.
    var cpuTime: Double
    var cpu: Double
    var gpu: Double
    var start: Date
    var isApp = false
    /// Owned by another account (e.g. _windowserver). Read-only stats; ending needs admin.
    var isOtherUser = false
    var children: [ProcInfo]? = nil

    var pid: pid_t { id }
}

struct NetConn: Identifiable, Hashable {
    let id = UUID()
    let pid: pid_t
    let proto: String
    let local: String
    let remote: String?
    let state: String

    var isExternal: Bool {
        guard let remote else { return false }
        return !(remote.hasPrefix("127.") || remote.hasPrefix("[::1]") || remote.hasPrefix("localhost"))
    }
}

struct CleanCandidate: Identifiable {
    var id: pid_t { proc.id }
    let proc: ProcInfo
    let reasons: [String]
    var checked: Bool
}

struct CleanPlan: Identifiable {
    enum Kind { case quick, purge, fresh }
    let id = UUID()
    let kind: Kind
    var items: [CleanCandidate]
}

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= 1_073_741_824 { return String(format: "%.2f GB", d / 1_073_741_824) }
        if d >= 1_048_576 { return String(format: "%.1f MB", d / 1_048_576) }
        return String(format: "%.0f KB", d / 1024)
    }

    /// Matches Activity Monitor's CPU Time style: 1:02:03.45, 2:03.45, 3.45
    static func cpuTime(_ s: Double) -> String {
        let h = Int(s) / 3600, m = Int(s) / 60 % 60
        let sec = s.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, sec) }
        if m > 0 { return String(format: "%d:%05.2f", m, sec) }
        return String(format: "%.2f", sec)
    }

    static func percent(_ v: Double) -> String { String(format: "%.1f", v) }
}
