import AppKit
import SwiftUI

/// Settings ▸ Firewall: what's blocked, the opt-in lists, and the on/off switch.
struct FirewallSection: View {
    @EnvironmentObject private var firewall: FirewallStore

    var body: some View {
        Section {
            Toggle("Block the addresses below", isOn: Binding(
                get: { firewall.config.enabled },
                set: { on in Task { await firewall.setEnabled(on) } }))
                .disabled(firewall.busy)
            statusLine
            if !firewall.config.apps.isEmpty {
                ForEach(firewall.config.apps) { app in
                    HStack {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text("Blocked app: \(firewall.hostCount(for: app.id)) address\(firewall.hostCount(for: app.id) == 1 ? "" : "es") so far")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await firewall.unblockApp(app.id) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Unblock \(app.name)")
                            .disabled(firewall.busy)
                    }
                }
                if firewall.followPaused {
                    HStack {
                        Label("Following blocked apps is paused", systemImage: "pause.circle").foregroundStyle(.orange)
                        Spacer()
                        Button("Resume") { firewall.resumeFollowing() }
                    }
                    .font(.callout)
                }
            }
            let manual = firewall.config.hosts.filter { $0.app == nil }
            if manual.isEmpty {
                Text("To block an app, click \(Image(systemName: "hand.raised")) next to it in the process list. To block one host, select a process and click \(Image(systemName: "hand.raised")) next to one of its connections.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(manual) { h in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(h.address).font(.body.monospaced())
                            Text(h.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await firewall.unblock(h.address) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Unblock")
                            .disabled(firewall.busy)
                    }
                }
            }
            ForEach(BlockList.threats) { list in
                Toggle(isOn: Binding(
                    get: { firewall.config.lists.contains(list.id) },
                    set: { on in Task { await firewall.setList(list, on: on) } })) {
                    Text(list.name)
                    Text(list.detail + updatedText(list))
                }
                .disabled(firewall.busy)
            }
            countries
            if !firewall.config.listsInUse.isEmpty {
                HStack {
                    if firewall.listsNeedUpdate {
                        Label("Some lists are more than a week old", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    } else if let d = firewall.oldestListUpdate {
                        Text("Lists updated \(d.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Update Lists Now") { Task { await firewall.updateLists() } }
                        .disabled(firewall.busy || !firewall.config.enabled)
                }
                .font(.callout)
            }
            if let m = firewall.message {
                Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Firewall")
        } footer: {
            Text("Everything stays allowed except what's listed here. Your local network is never blocked. Each change asks for your password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func updatedText(_ list: BlockList) -> String {
        guard firewall.config.lists.contains(list.id), let d = firewall.updated(list) else { return "" }
        return " Updated \(d.formatted(.relative(presentation: .named)))."
    }

    @ViewBuilder private var countries: some View {
        LabeledContent {
            Menu("Add Country") {
                ForEach(BlockList.allCountries.filter { !firewall.config.countries.contains($0.code) }, id: \.code) { c in
                    Button("\(c.name) (\(c.code))") { Task { await firewall.addCountry(c.code) } }
                }
            }
            .fixedSize()
            .disabled(firewall.busy)
        } label: {
            Text("Block countries")
            Text("All traffic to and from a country's address ranges, from ipdeny.com.")
        }
        ForEach(firewall.config.countries, id: \.self) { code in
            HStack {
                Text("\(BlockList.countryName(code)) (\(code))")
                if let d = firewall.updated(BlockList.country(code)) {
                    Text("updated \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await firewall.removeCountry(code) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Stop blocking \(BlockList.countryName(code))")
                    .disabled(firewall.busy)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        HStack {
            switch firewall.status {
            case .on(let n):
                Label("On: blocking \(n.formatted()) address\(n == 1 ? "" : "es and ranges")", systemImage: "hand.raised.fill")
                    .foregroundStyle(.green)
            case .paused:
                Label("Paused since your Mac restarted", systemImage: "pause.circle").foregroundStyle(.orange)
                Spacer()
                Button("Turn Back On") { Task { await firewall.reapply() } }.disabled(firewall.busy)
            case .off:
                Label("Off", systemImage: "hand.raised.slash").foregroundStyle(.secondary)
            }
            if firewall.busy { Spacer(); ProgressView().controlSize(.small) }
        }
        .font(.callout)
    }
}

/// The hand button next to an outside connection in the inspector.
struct BlockHostButton: View {
    @EnvironmentObject private var firewall: FirewallStore
    let conn: NetConn
    let processName: String

    var body: some View {
        if let remote = conn.remote, conn.isExternal, let host = BlockAddress.host(fromRemote: remote) {
            if firewall.isBlocked(host) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.red).help("\(host) is blocked")
            } else if BlockAddress.normalize(host) != nil {
                Button { confirm(host, remote) } label: { Image(systemName: "hand.raised") }
                    .buttonStyle(.borderless)
                    .help("Block \(host)")
                    .disabled(firewall.busy)
            }
        }
    }

    private func confirm(_ host: String, _ remote: String) {
        let alert = NSAlert()
        alert.messageText = "Block \(host)?"
        alert.informativeText = "\(processName) is connected to it. No app on this Mac will be able to reach it until you unblock it in Settings ▸ Firewall. macPrune will ask for your password."
        alert.addButton(withTitle: "Block")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await firewall.block(host, note: "\(processName) → \(remote)") }
    }
}

extension Notification.Name {
    /// Opens the Firewall sheet in the main window (from the menu).
    static let showFirewall = Notification.Name("macPrune.showFirewall")
}

/// The Firewall sheet, opened from the toolbar's hand button.
struct FirewallSheet: View {
    @EnvironmentObject private var firewall: FirewallStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form { FirewallSection() }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { firewall.refreshStatus() }
    }
}

extension ProcessStore {
    /// The app a process belongs to, for blocking: the app macOS holds responsible for it, so a
    /// browser's helpers count as the browser. nil when its path is unknown.
    func blockIdentity(of p: ProcInfo) -> (id: String, name: String)? {
        let owner = procs[p.responsible] ?? p
        guard !owner.path.isEmpty else { return nil }
        let id = AppIdentity.of(path: owner.path)
        let name = id.hasSuffix(".app") ? ((id as NSString).lastPathComponent as NSString).deletingPathExtension : owner.name
        return (id, name)
    }

    func appID(of pid: pid_t) -> String? { procs[pid].flatMap { blockIdentity(of: $0)?.id } }
}

/// The hand next to each process in the table: blocks the app's network, or unblocks it.
struct AppBlockButton: View {
    @EnvironmentObject private var store: ProcessStore
    @EnvironmentObject private var firewall: FirewallStore
    let proc: ProcInfo

    var body: some View {
        if !proc.isOtherUser, !Cleaner.isCritical(proc), let app = store.blockIdentity(of: proc) {
            if firewall.isFollowed(app.id) {
                Button { confirmUnblock(app) } label: { Image(systemName: "hand.raised.fill").foregroundStyle(.red) }
                    .buttonStyle(.borderless)
                    .help("\(app.name)'s network is blocked. Click to unblock it.")
                    .disabled(firewall.busy)
            } else {
                Button { Task { await confirmBlock(app) } } label: { Image(systemName: "hand.raised").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Block \(app.name)'s network")
                    .disabled(firewall.busy)
            }
        }
    }

    private func confirmBlock(_ app: (id: String, name: String)) async {
        let pids = Set(store.procs.values.filter { store.blockIdentity(of: $0)?.id == app.id }.map(\.id))
        let addresses = Set((await Net.allUserConnections())
            .filter { pids.contains($0.pid) && $0.isExternal }
            .compactMap { $0.remote.flatMap(BlockAddress.host(fromRemote:)).flatMap(BlockAddress.normalize) })
        let alert = NSAlert()
        alert.messageText = "Block \(app.name)'s network?"
        alert.informativeText = """
            \(app.name) is connected to \(addresses.count) outside address\(addresses.count == 1 ? "" : "es") right now. \
            macPrune blocks them, and keeps blocking new ones \(app.name) opens while macPrune is open, asking \
            for your password at most every 2 minutes.

            macOS's firewall can only block addresses, not apps, so these addresses are blocked for every app \
            on this Mac. Click the red hand to undo it.
            """
        alert.addButton(withTitle: "Block")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await firewall.blockApp(id: app.id, name: app.name, addresses: Array(addresses))
    }

    private func confirmUnblock(_ app: (id: String, name: String)) {
        let alert = NSAlert()
        alert.messageText = "Unblock \(app.name)?"
        alert.informativeText = "macPrune stops following \(app.name) and unblocks the \(firewall.hostCount(for: app.id)) addresses it blocked for it."
        alert.addButton(withTitle: "Unblock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await firewall.unblockApp(app.id) }
    }
}
