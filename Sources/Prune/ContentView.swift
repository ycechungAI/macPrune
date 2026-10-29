import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProcessStore
    @AppStorage("treeMode") private var treeMode = true
    @AppStorage("pinned") private var pinned = false
    @AppStorage("compact") private var compact = false
    @AppStorage("hideKept") private var hideKept = false
    @AppStorage(Prefs.showOthers) private var showOthers = true
    @Local private var selection = Set<pid_t>()
    @Local private var sortOrder = [KeyPathComparator(\ProcInfo.realMem, order: .reverse)]
    @Local private var search = ""
    @Local private var showInspector = true
    @Local private var killTargets: [pid_t] = []
    @Local private var plan: CleanPlan?
    @Local private var window: NSWindow?
    @Local private var fullFrame: NSRect?

    var body: some View {
        Group {
            if compact {
                CompactView(selection: $selection, plan: $plan, compact: $compact)
                    .frame(minWidth: 280, minHeight: 320)
            } else {
                mainTable
                    .frame(minWidth: 720, minHeight: 400)
                    .inspector(isPresented: $showInspector) {
                        InspectorView(selection: $selection)
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                    }
            }
        }
        .toolbar { toolbar }
        .background(WindowAccessor { w in
            window = w
            applyPin()
            if compact { applyCompact() }
        })
        .onChange(of: pinned) { applyPin(); store.schedule() }
        .onChange(of: showOthers) { store.tick() }
        .onChange(of: compact) { applyCompact() }
        .confirmationDialog(killTitle, isPresented: Binding(get: { !killTargets.isEmpty }, set: { if !$0 { killTargets = [] } })) {
            Button("Quit") { store.end(killTargets, force: false) }
            Button("Force Quit", role: .destructive) { store.end(killTargets, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if killTargets.contains(where: { store.procs[$0]?.isOtherUser == true }) {
                Text("Some of these belong to other users or to macOS itself, so you'll be asked for an admin password. Ending system services can break features until you restart.")
            } else {
                Text("Quit lets the process clean up. Force Quit ends it immediately and may lose unsaved work.")
            }
        }
        .sheet(item: $plan) { p in
            CleanSheet(plan: p) { pids in
                store.end(pids, force: p.kind == .purge)
                selection.subtract(pids)
            }
        }
        .overlay(alignment: .bottom) { bannerView }
    }

    // MARK: Table

    private var mainTable: some View {
        VStack(spacing: 0) {
            Table(store.rows(tree: treeMode, filter: search, sort: sortOrder, hideKept: hideKept),
                  children: \.children, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process Name", value: \.name) { p in
                    cell(p) {
                        HStack(spacing: 6) {
                            Image(nsImage: Icons.icon(for: p)).resizable().frame(width: 16, height: 16)
                            Text(p.name).lineLimit(1)
                                .foregroundStyle(p.isOtherUser ? .secondary : .primary)
                            if store.isKept(p) {
                                Image(systemName: "leaf.fill").foregroundStyle(.green).help("On your Do Not Prune list")
                            } else if store.isUnwanted(p) {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary).help("On your unwanted list")
                            }
                        }
                    }
                }
                .width(min: 180, ideal: 280)
                TableColumn("Real Memory", value: \.realMem) { p in cell(p) { Text(Fmt.bytes(p.realMem)).monospacedDigit() } }
                    .width(min: 80, ideal: 90)
                TableColumn("% CPU", value: \.cpu) { p in cell(p) { Text(Fmt.percent(p.cpu)).monospacedDigit() } }
                    .width(min: 50, ideal: 60)
                TableColumn("Threads", value: \.threads) { p in cell(p) { Text(p.threads < 0 ? "–" : "\(p.threads)").monospacedDigit() } }
                    .width(min: 50, ideal: 60)
                TableColumn("PID", value: \.pid) { p in cell(p) { Text(String(p.pid)).monospacedDigit() } }
                    .width(min: 50, ideal: 60)
                TableColumn("User", value: \.user) { p in
                    cell(p) {
                        if p.isOtherUser {
                            Label(p.user, systemImage: "person.2").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                        } else {
                            Text(p.user)
                        }
                    }
                }
                    .width(min: 70, ideal: 115)
                TableColumn("CPU Time", value: \.cpuTime) { p in cell(p) { Text(Fmt.cpuTime(p.cpuTime)).monospacedDigit() } }
                    .width(min: 70, ideal: 80)
                TableColumn("% GPU", value: \.gpu) { p in cell(p) { Text(Fmt.percent(p.gpu)).monospacedDigit() } }
                    .width(min: 50, ideal: 60)
            }
            .contextMenu(forSelectionType: pid_t.self) { pids in
                contextMenu(for: pids)
            } primaryAction: { _ in
                showInspector = true
            }
            .onDeleteCommand { if !selection.isEmpty { killTargets = Array(selection) } }
            .searchable(text: $search, placement: .toolbar, prompt: "Name, PID or path")

            statusBar
        }
    }

    /// Wraps a table cell, tinting it green when the process is on the Do Not Prune list.
    private func cell<Content: View>(_ p: ProcInfo, @ViewBuilder _ content: () -> Content) -> some View {
        let kept = store.isKept(p)
        // The fill bleeds past the cell into the column gaps so the row reads as one green band.
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if kept { Rectangle().fill(Color.green.opacity(0.2)).padding(.horizontal, -8).padding(.vertical, -4) }
            }
    }

    @ViewBuilder
    private func contextMenu(for pids: Set<pid_t>) -> some View {
        Button("Quit…") { killTargets = Array(pids) }
        Button("Force Quit") { store.end(Array(pids), force: true) }
        Divider()
        if pids.count == 1, let pid = pids.first, let p = store.procs[pid] {
            Button(store.isKept(p) ? "Remove from Do Not Prune List" : "Add to Do Not Prune List") {
                store.toggleKeep(p.name)
            }
            Button(store.unwanted.contains(p.name) ? "Remove from Quick Clean List" : "Add to Quick Clean List") {
                store.toggleUnwanted(p.name)
            }
            if !p.path.isEmpty {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(p.path, inFileViewerRootedAtPath: "") }
            }
        } else {
            let names = Set(pids.compactMap { store.procs[$0]?.name })
            if names.allSatisfy(store.keep.contains) {
                Button("Remove All from Do Not Prune List") { for n in names { store.toggleKeep(n) } }
            } else {
                Button("Add All to Do Not Prune List") {
                    for n in names where !store.keep.contains(n) { store.toggleKeep(n) }
                }
            }
            Button("Add All to Quick Clean List") {
                for pid in pids { if let n = store.procs[pid]?.name, !store.unwanted.contains(n) { store.toggleUnwanted(n) } }
            }
        }
    }

    private var statusBar: some View {
        let all = store.procs.values
        let mem = all.reduce(UInt64(0)) { $0 + $1.realMem }
        let cpu = all.reduce(0.0) { $0 + $1.cpu }
        return HStack(spacing: 16) {
            Label("\(all.count) processes", systemImage: "square.stack.3d.up")
            if hideKept {
                let hidden = all.filter(store.isProtectedFamily).count
                if hidden > 0 { Label("\(hidden) protected hidden", systemImage: "eye.slash").foregroundStyle(.green) }
            }
            Label(Fmt.bytes(mem), systemImage: "memorychip")
            Label("\(Fmt.percent(cpu))% CPU", systemImage: "cpu")
            Spacer()
            if !selection.isEmpty { Text("\(selection.count) selected") }
            MemoryBar(memory: store.system)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { killTargets = Array(selection) } label: { Label("End Process", systemImage: "xmark.octagon") }
                .help("Quit the selected processes (⌫)")
                .disabled(selection.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { plan = Cleaner.quickClean(store) } label: { Label("Quick Clean", systemImage: "sparkles") }
                .help("End idle login leftovers and your unwanted list")
            Button { plan = Cleaner.freshStart(store) } label: {
                Label("Fresh Start", systemImage: "leaf.arrow.triangle.circlepath")
            }
            .help("Quit everything except your Do Not Prune list and macOS itself, like a restart")
            Button {
                store.scanning = true
                Task {
                    plan = await Cleaner.purge(store)
                    store.scanning = false
                }
            } label: {
                if store.scanning { ProgressView().controlSize(.small) } else { Label("Purge", systemImage: "flame") }
            }
            .help("Find heavy or suspicious processes")
            .disabled(store.scanning)

            if !compact {
                Toggle(isOn: $showOthers) {
                    Label("Other Users", systemImage: showOthers ? "person.2.fill" : "person.2")
                }
                .help(showOthers ? "Hide processes owned by other users and system accounts" : "Show processes owned by other users and system accounts (not root)")
                Toggle(isOn: $hideKept) {
                    Label("Hide Protected", systemImage: hideKept ? "eye.slash" : "leaf")
                }
                .help(hideKept ? "Show Do Not Prune processes" : "Hide Do Not Prune processes and their helpers")
                Picker("View", selection: $treeMode) {
                    Label("Tree", systemImage: "list.bullet.indent").tag(true)
                    Label("List", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Show processes as a family tree or a flat list")
            }
            Toggle(isOn: $pinned) { Label("Keep on Top", systemImage: pinned ? "pin.fill" : "pin") }
                .help("Keep this window above all other windows")
            Toggle(isOn: $compact) {
                Label("Compact", systemImage: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .help("Switch to a small overview")
            if !compact {
                Button { showInspector.toggle() } label: { Label("Connections", systemImage: "sidebar.right") }
                    .help("Show the process family and connections")
            }
        }
    }

    // MARK: Window behaviour

    private func applyPin() {
        guard let window else { return }
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func applyCompact() {
        guard let window else { return }
        var frame = window.frame
        if compact {
            if frame.width > 400 { fullFrame = frame }
            let size = NSSize(width: 320, height: 440)
            frame.origin.y += frame.height - size.height
            frame.size = size
        } else {
            let target = fullFrame?.size ?? NSSize(width: 1040, height: 640)
            frame.origin.y += frame.height - target.height
            frame.size = target
        }
        window.setFrame(frame, display: true, animate: true)
    }

    private var killTitle: String {
        let names = killTargets.compactMap { store.procs[$0]?.name }
        if names.count == 1 { return "Quit “\(names[0])”?" }
        return "Quit \(killTargets.count) processes?"
    }

    @ViewBuilder
    private var bannerView: some View {
        if let msg = store.banner {
            Text(msg)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 36)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation { store.banner = nil }
                }
                .onTapGesture { store.banner = nil }
        }
    }
}

/// Whole-Mac memory in the status bar: pressure dot, a used-memory bar, and swap.
struct MemoryBar: View {
    let memory: SystemMemory

    private var pressure: (String, Color) {
        switch memory.pressure {
        case 4: ("Critical", .red)
        case 2: ("Warning", .yellow)
        default: ("Normal", .green)
        }
    }

    var body: some View {
        let total = Double(max(memory.total, 1))
        HStack(spacing: 6) {
            Circle().fill(pressure.1).frame(width: 7, height: 7)
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 90 * Double(memory.app) / total)
                Rectangle().fill(Color.orange).frame(width: 90 * Double(memory.wired) / total)
                Rectangle().fill(Color.purple).frame(width: 90 * Double(memory.compressed) / total)
                Spacer(minLength: 0)
            }
            .frame(width: 90, height: 6)
            .background(.quaternary)
            .clipShape(Capsule())
            Text("\(Fmt.bytes(memory.used)) of \(Fmt.bytes(memory.total))")
                .monospacedDigit()
            if memory.swap > 0 {
                Text("Swap \(Fmt.bytes(memory.swap))").monospacedDigit()
            }
        }
        .help("""
        Memory pressure: \(pressure.0)
        App memory: \(Fmt.bytes(memory.app)) (blue)
        Wired: \(Fmt.bytes(memory.wired)) (orange)
        Compressed: \(Fmt.bytes(memory.compressed)) (purple)
        Cached files: \(Fmt.bytes(memory.cached))
        Swap used: \(Fmt.bytes(memory.swap))
        """)
    }
}
