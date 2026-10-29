import AppKit
import SwiftUI

/// Right-hand panel: the selected process's family, app group and network connections.
struct InspectorView: View {
    @EnvironmentObject private var store: ProcessStore
    @Binding var selection: Set<pid_t>
    @Local private var conns: [NetConn] = []

    var body: some View {
        if selection.count == 1, let pid = selection.first, let p = store.procs[pid] {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(p)
                    ConnectionGraph(proc: p, conns: conns, selection: $selection)
                    lineage(p)
                    related("Launched", store.children(of: pid), icon: "arrow.turn.down.right")
                    if p.responsible != pid, let owner = store.procs[p.responsible] {
                        related("Belongs to app", [owner], icon: "app.badge")
                    }
                    related("Same app group", store.appGroup(of: pid), icon: "square.stack.3d.up", collapsed: true)
                    network
                    details(p)
                }
                .padding()
            }
            .task(id: pid) {
                conns = []
                while !Task.isCancelled {
                    conns = await Net.connections(pid: pid)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else if selection.count > 1 {
            ContentUnavailableView("\(selection.count) Processes Selected", systemImage: "square.stack.3d.up",
                                   description: Text("Total \(Fmt.bytes(selection.compactMap { store.procs[$0]?.realMem }.reduce(0, +)))"))
        } else {
            ContentUnavailableView("No Selection", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Select a process to see its family and connections."))
        }
    }

    private func header(_ p: ProcInfo) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: Icons.icon(for: p)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.headline).lineLimit(1)
                Text("PID \(String(p.id)) · \(Fmt.bytes(p.realMem)) · \(Fmt.percent(p.cpu))% CPU")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func lineage(_ p: ProcInfo) -> some View {
        Section {
            let chain = store.ancestors(of: p.id).reversed()
            HStack(spacing: 4) {
                ForEach(Array(chain), id: \.pid) { a in
                    Button(a.name) { if a.visible { selection = [a.pid] } }
                        .buttonStyle(.link)
                        .disabled(!a.visible)
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(p.name).bold().lineLimit(1)
            }
            .font(.caption)
        } header: { sectionHeader("Launched by", icon: "arrow.turn.up.left") }
    }

    @ViewBuilder
    private func related(_ title: String, _ list: [ProcInfo], icon: String, collapsed: Bool = false) -> some View {
        if !list.isEmpty {
            DisclosureGroup {
                VStack(spacing: 2) {
                    ForEach(list.prefix(30)) { c in
                        Button { selection = [c.id] } label: {
                            HStack(spacing: 6) {
                                Image(nsImage: Icons.icon(for: c)).resizable().frame(width: 14, height: 14)
                                Text(c.name).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(c.realMem)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if list.count > 30 { Text("+\(list.count - 30) more").foregroundStyle(.secondary) }
                }
                .font(.caption)
                .padding(.top, 4)
            } label: {
                sectionHeader("\(title) (\(list.count))", icon: icon)
            }
            .disclosureGroupStyle(Expanding(initiallyExpanded: !collapsed))
        }
    }

    @ViewBuilder
    private var network: some View {
        if !conns.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(conns.prefix(40)) { c in
                        HStack(spacing: 6) {
                            Text(c.proto).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                            Text(c.remote ?? c.local).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(c.state.isEmpty ? "LISTEN" : c.state).foregroundStyle(c.isExternal ? .blue : .secondary)
                        }
                    }
                }
                .font(.caption.monospaced())
            } header: { sectionHeader("Network (\(conns.count))", icon: "network") }
        }
    }

    private func details(_ p: ProcInfo) -> some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("Started").foregroundStyle(.secondary); Text(p.start.formatted(date: .abbreviated, time: .shortened)) }
                GridRow { Text("With children").foregroundStyle(.secondary); Text(Fmt.bytes(store.subtreeMemory(of: p.id))) }
                GridRow { Text("Threads").foregroundStyle(.secondary); Text("\(p.threads)") }
                GridRow { Text("GPU").foregroundStyle(.secondary); Text("\(Fmt.percent(p.gpu))%") }
            }
            .font(.caption)
            if !p.path.isEmpty {
                HStack(alignment: .top) {
                    Text(p.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    Spacer()
                    Button { NSWorkspace.shared.selectFile(p.path, inFileViewerRootedAtPath: "") } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
            }
        } header: { sectionHeader("Details", icon: "info.circle") }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
    }
}

private struct Expanding: DisclosureGroupStyle {
    let initiallyExpanded: Bool
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, expanded: initiallyExpanded)
    }

    private struct Inner: View {
        let configuration: DisclosureGroupStyleConfiguration
        @Local var expanded: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack {
                        configuration.label
                        Spacer()
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded { configuration.content }
            }
        }
    }
}

/// A small node map: parent above, children below, owning app, app group and network to the sides.
struct ConnectionGraph: View {
    @EnvironmentObject private var store: ProcessStore
    let proc: ProcInfo
    let conns: [NetConn]
    @Binding var selection: Set<pid_t>

    private enum Style { case solid, dashed, dotted }
    private struct Node: Identifiable {
        let id: String
        let pid: pid_t?
        let label: String
        var image: NSImage? = nil
        var symbol: String? = nil
        let pos: CGPoint
        var isCenter = false
        var style: Style = .solid
    }

    var body: some View {
        GeometryReader { geo in
            let nodes = layout(width: geo.size.width)
            let center = nodes.first { $0.isCenter }!.pos
            ZStack {
                Canvas { ctx, _ in
                    for n in nodes where !n.isCenter {
                        var path = Path()
                        path.move(to: center)
                        path.addLine(to: n.pos)
                        let dash: [CGFloat] = n.style == .solid ? [] : n.style == .dashed ? [5, 4] : [1.5, 3]
                        ctx.stroke(path, with: .color(.secondary.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: dash))
                    }
                }
                ForEach(nodes) { n in
                    nodeView(n).position(n.pos)
                }
            }
        }
        .frame(height: 230)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 10) {
                legend("launched", [])
                legend("app", [4, 3])
                legend("network", [1.5, 3])
            }
            .padding(6)
        }
    }

    private func legend(_ text: String, _ dash: [CGFloat]) -> some View {
        HStack(spacing: 3) {
            Path { $0.move(to: .init(x: 0, y: 4)); $0.addLine(to: .init(x: 14, y: 4)) }
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.2, dash: dash))
                .frame(width: 14, height: 8)
            Text(text)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private func layout(width w: CGFloat) -> [Node] {
        let mid = w / 2
        var nodes = [Node(id: "self", pid: proc.id, label: proc.name, image: Icons.icon(for: proc),
                          pos: CGPoint(x: mid, y: 105), isCenter: true)]

        if let parent = store.procs[proc.ppid] {
            nodes.append(Node(id: "parent", pid: parent.id, label: parent.name, image: Icons.icon(for: parent),
                              pos: CGPoint(x: mid, y: 28)))
        } else if proc.ppid > 0 {
            nodes.append(Node(id: "parent", pid: nil, label: Sampler.name(of: proc.ppid), symbol: "gearshape",
                              pos: CGPoint(x: mid, y: 28)))
        }
        if proc.responsible != proc.id, proc.responsible != proc.ppid, let owner = store.procs[proc.responsible] {
            nodes.append(Node(id: "owner", pid: owner.id, label: owner.name, image: Icons.icon(for: owner),
                              pos: CGPoint(x: w * 0.83, y: 32), style: .dashed))
        }
        let group = store.appGroup(of: proc.id).count
        if group > 0 {
            nodes.append(Node(id: "group", pid: nil, label: "\(group) in app", symbol: "square.stack.3d.up",
                              pos: CGPoint(x: w * 0.85, y: 112), style: .dashed))
        }
        if !conns.isEmpty {
            let ext = conns.filter(\.isExternal).count
            nodes.append(Node(id: "net", pid: nil, label: ext > 0 ? "\(ext) remote" : "\(conns.count) local",
                              symbol: "network", pos: CGPoint(x: w * 0.15, y: 112), style: .dotted))
        }

        let kids = store.children(of: proc.id)
        let shown = kids.count > 4 ? Array(kids.prefix(3)) : kids
        let slots = shown.count + (kids.count > 4 ? 1 : 0)
        for (i, k) in shown.enumerated() {
            nodes.append(Node(id: "c\(k.id)", pid: k.id, label: k.name, image: Icons.icon(for: k),
                              pos: CGPoint(x: w * CGFloat(i + 1) / CGFloat(slots + 1), y: 192)))
        }
        if kids.count > 4 {
            nodes.append(Node(id: "more", pid: nil, label: "+\(kids.count - 3) more", symbol: "ellipsis.circle",
                              pos: CGPoint(x: w * CGFloat(slots) / CGFloat(slots + 1), y: 192)))
        }
        return nodes
    }

    private func nodeView(_ n: Node) -> some View {
        let size: CGFloat = n.isCenter ? 34 : 24
        return VStack(spacing: 3) {
            ZStack {
                Circle().fill(.background).frame(width: size + 8, height: size + 8)
                    .overlay(Circle().stroke(n.isCenter ? Color.accentColor : .secondary.opacity(0.35), lineWidth: n.isCenter ? 2 : 1))
                if let img = n.image {
                    Image(nsImage: img).resizable().frame(width: size, height: size)
                } else if let s = n.symbol {
                    Image(systemName: s).font(.system(size: size * 0.55)).foregroundStyle(.secondary)
                }
            }
            Text(n.label)
                .font(.system(size: 10, weight: n.isCenter ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 84)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let pid = n.pid, store.procs[pid] != nil { selection = [pid] } }
        .help(n.pid.map { "\(n.label) — PID \($0)" } ?? n.label)
    }
}
