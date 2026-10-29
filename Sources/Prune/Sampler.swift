import Darwin
import Foundation
import IOKit

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Reads process stats straight from the kernel (libproc) and per-process GPU time from IOKit.
/// Not thread-safe: call `sample()` from one serial queue only.
final class Sampler: @unchecked Sendable {
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevGPU: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var paths: [pid_t: (start: UInt64, path: String)] = [:]
    private let numer: UInt64
    private let denom: UInt64
    private let uid = getuid()
    private let userName = NSUserName()

    init() {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer)
        denom = UInt64(tb.denom)
    }

    func sample(includeOthers: Bool) -> [ProcInfo] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = prevTime == 0 ? 0 : Double(now - prevTime)
        prevTime = now
        let gpuNow = GPU.accumulatedTimes()

        var count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        var out: [ProcInfo] = []
        var nextCPU: [pid_t: UInt64] = [:]
        var nextPaths: [pid_t: (UInt64, String)] = [:]
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)

        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
                  bsd.pbi_uid == uid else { continue }
            var task = proc_taskinfo()
            // Zombies and exiting processes have no task info; skip them.
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

            let cpuNs = (task.pti_total_user + task.pti_total_system) * numer / denom
            nextCPU[pid] = cpuNs
            var cpu = 0.0
            if elapsed > 0, let prev = prevCPU[pid], cpuNs >= prev {
                cpu = Double(cpuNs - prev) / elapsed * 100
            }
            var gpu = 0.0
            if elapsed > 0, let g = gpuNow[pid], let prev = prevGPU[pid], g >= prev {
                gpu = min(Double(g - prev) / elapsed * 100, 100)
            }

            let start = bsd.pbi_start_tvsec
            let path: String
            if let cached = paths[pid], cached.start == start {
                path = cached.path
            } else {
                path = Self.path(of: pid)
            }
            nextPaths[pid] = (start, path)

            let shortName = Self.string(bsd.pbi_name).isEmpty ? Self.string(bsd.pbi_comm) : Self.string(bsd.pbi_name)
            let responsible = responsibility_get_pid_responsible_for_pid(pid)

            out.append(ProcInfo(
                id: pid,
                ppid: pid_t(bsd.pbi_ppid),
                responsible: responsible > 0 ? responsible : pid,
                name: path.isEmpty ? shortName : (path as NSString).lastPathComponent,
                path: path,
                user: userName,
                realMem: task.pti_resident_size,
                threads: Int(task.pti_threadnum),
                cpuTime: Double(cpuNs) / 1e9,
                cpu: cpu,
                gpu: gpu,
                start: Date(timeIntervalSince1970: TimeInterval(start))
            ))
        }

        if includeOthers {
            let mine = Set(out.map(\.id))
            for var p in otherUsers(gpu: gpuNow, elapsed: elapsed) where !mine.contains(p.id) {
                nextCPU[p.id] = UInt64(p.cpuTime * 1e9)
                if elapsed > 0, let prev = prevCPU[p.id], nextCPU[p.id]! >= prev {
                    p.cpu = Double(nextCPU[p.id]! - prev) / elapsed * 100
                }
                nextPaths[p.id] = (0, p.path)
                out.append(p)
            }
        }

        prevCPU = nextCPU
        prevGPU = gpuNow
        paths = nextPaths
        return out
    }

    /// Processes owned by other non-root accounts. libproc can't read them, but /bin/ps is
    /// setuid root and reports their memory and CPU time. Thread counts aren't available.
    private func otherUsers(gpu: [pid_t: UInt64], elapsed: Double) -> [ProcInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,uid=,rss=,time=,lstart=,comm="]
        p.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        var out: [ProcInfo] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            // pid ppid uid rss time | lstart (5 words) | comm (may contain spaces)
            let f = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
            guard f.count == 11, let pid = pid_t(f[0]), let ppid = pid_t(f[1]),
                  let uid = uid_t(f[2]), uid != 0, uid != self.uid, let rss = UInt64(f[3]) else { continue }
            let cmd = String(f[10])
            let path = paths[pid]?.path ?? Self.path(of: pid)
            let responsible = responsibility_get_pid_responsible_for_pid(pid)
            var gpuPct = 0.0
            if elapsed > 0, let g = gpu[pid], let prev = prevGPU[pid], g >= prev {
                gpuPct = min(Double(g - prev) / elapsed * 100, 100)
            }
            out.append(ProcInfo(
                id: pid,
                ppid: ppid,
                responsible: responsible > 0 ? responsible : pid,
                name: ((path.isEmpty ? cmd : path) as NSString).lastPathComponent,
                path: path,
                user: Self.userName(uid),
                realMem: rss * 1024,
                threads: -1,
                cpuTime: Self.seconds(String(f[4])),
                cpu: 0,
                gpu: gpuPct,
                start: dateFmt.date(from: f[5...9].joined(separator: " ")) ?? .distantPast,
                isOtherUser: true
            ))
        }
        return out
    }

    private static var userNames: [uid_t: String] = [:]

    private static func userName(_ uid: uid_t) -> String {
        if let n = userNames[uid] { return n }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userNames[uid] = n
        return n
    }

    /// ps CPU time: "5:10.04", "123:45.67" or "1-02:03:04" (days-hours:min:sec).
    private static func seconds(_ s: String) -> Double {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let total = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86400 + total
    }

    static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    /// Name of any process, including ones we can't read stats for (e.g. launchd).
    static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "PID \(pid)"
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Per-process GPU time, read the same way Activity Monitor does: each GPU user client in the
/// IORegistry names its creator pid and carries an accumulated GPU time in nanoseconds.
enum GPU {
    static func accumulatedTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var devices: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &devices) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(devices) }

        var device = IOIteratorNext(devices)
        while device != 0 {
            var clients: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(device, kIOServicePlane, &clients) == KERN_SUCCESS {
                var client = IOIteratorNext(clients)
                while client != 0 {
                    if let creator = property(client, "IOUserClientCreator") as? String,
                       let pid = parsePid(creator),
                       let usage = property(client, "AppUsage") as? [[String: Any]] {
                        let total = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                        result[pid, default: 0] += total
                    }
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }
                IOObjectRelease(clients)
            }
            IOObjectRelease(device)
            device = IOIteratorNext(devices)
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// "pid 450, WindowServer" -> 450
    private static func parsePid(_ s: String) -> pid_t? {
        guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ",") else { return nil }
        return pid_t(s[s.index(s.startIndex, offsetBy: 4)..<comma])
    }
}

/// Network connections via lsof. Only run on demand (selected process, or a Purge scan).
enum Net {
    static func connections(pid: pid_t) async -> [NetConn] {
        await run(["-nP", "-i", "-a", "-p", "\(pid)", "-F", "pPnT"])
    }

    static func allUserConnections() async -> [NetConn] {
        await run(["-nP", "-i", "-a", "-u", "\(getuid())", "-F", "pPnT"])
    }

    private static func run(_ args: [String]) async -> [NetConn] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: []); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: parse(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// lsof -F output: one field per line, prefixed by a letter. 'p' starts a process, 'f' a file.
    private static func parse(_ text: String) -> [NetConn] {
        var out: [NetConn] = []
        var pid: pid_t = 0
        var proto = "", name = "", state = ""
        var open = false
        func flush() {
            guard open, !name.isEmpty else { return }
            let parts = name.components(separatedBy: "->")
            out.append(NetConn(pid: pid, proto: proto, local: parts[0],
                               remote: parts.count > 1 ? parts[1] : nil,
                               state: state.isEmpty ? (proto == "UDP" ? "UDP" : "") : state))
        }
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); open = false; pid = pid_t(value) ?? 0
            case "f": flush(); open = true; proto = ""; name = ""; state = ""
            case "P": proto = value
            case "n": name = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return out
    }
}

/// Whole-Mac memory, computed the way Activity Monitor's Memory tab does.
struct SystemMemory {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swap: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var pressure: Int32 = 1

    var used: UInt64 { app + wired + compressed }

    private static let host = mach_host_self()

    static func read() -> SystemMemory {
        var m = SystemMemory()
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &m.total, &size, nil, 0)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            m.app = UInt64(vm.internal_page_count &- vm.purgeable_count) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.cached = UInt64(vm.external_page_count + vm.purgeable_count) * page
        }

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swap = swap.xsu_used }

        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &m.pressure, &size, nil, 0)
        return m
    }
}
