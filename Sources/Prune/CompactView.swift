import SwiftUI

/// Small always-glanceable overview: top processes by memory or CPU.
struct CompactView: View {
    @EnvironmentObject private var store: ProcessStore
    @Binding var selection: Set<pid_t>
    @Binding var plan: CleanPlan?
    @Binding var compact: Bool
    @AppStorage("compactMetric") private var byCPU = false

    var body: some View {
        let top = store.procs.values
            .sorted { byCPU ? $0.cpu > $1.cpu : $0.realMem > $1.realMem }
            .prefix(10)
        let maxValue = max(top.map { byCPU ? $0.cpu : Double($0.realMem) }.max() ?? 1, 1)

        VStack(spacing: 8) {
            Picker("", selection: $byCPU) {
                Text("Memory").tag(false)
                Text("CPU").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 6) {
                ForEach(Array(top)) { p in
                    let value = byCPU ? p.cpu : Double(p.realMem)
                    HStack(spacing: 8) {
                        Image(nsImage: Icons.icon(for: p)).resizable().frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text(byCPU ? "\(Fmt.percent(p.cpu))%" : Fmt.bytes(p.realMem))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.caption)
                            GeometryReader { g in
                                Capsule().fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.accentColor.opacity(0.7))
                                            .frame(width: g.size.width * CGFloat(value / maxValue))
                                    }
                            }
                            .frame(height: 3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selection = [p.id]
                        compact = false
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .animation(.easeOut(duration: 0.25), value: top.map(\.id))
    }
}
