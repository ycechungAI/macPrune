import SwiftUI

/// Review checklist shown before Quick Clean or Purge ends anything.
struct CleanSheet: View {
    @Local var plan: CleanPlan
    let onConfirm: ([pid_t]) -> Void
    @Environment(\.dismiss) private var dismiss

    private var checked: [pid_t] { plan.items.filter(\.checked).map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: plan.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(plan.kind.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.kind.title).font(.title3.bold())
                    Text(plan.kind.summary)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if plan.items.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: "checkmark.circle",
                                       description: Text(plan.kind.emptyHint))
                    .frame(height: 220)
            } else {
                List($plan.items) { $item in
                    Toggle(isOn: $item.checked) {
                        HStack(spacing: 8) {
                            Image(nsImage: Icons.icon(for: item.proc)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.proc.name).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.bytes(item.proc.realMem)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                HStack(spacing: 4) {
                                    ForEach(item.reasons, id: \.self) { r in
                                        Text(r)
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 240)
            }

            HStack {
                if !plan.items.isEmpty {
                    Button(checked.count == plan.items.count ? "Select None" : "Select All") {
                        let all = checked.count != plan.items.count
                        for i in plan.items.indices { plan.items[i].checked = all }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(plan.kind == .purge ? "Force Quit" : "Quit") \(checked.count)") {
                    onConfirm(checked)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

extension CleanPlan.Kind {
    var title: String {
        switch self {
        case .quick: "Quick Clean"
        case .purge: "Purge"
        case .fresh: "Fresh Start"
        }
    }

    var symbol: String {
        switch self {
        case .quick: "sparkles"
        case .purge: "flame"
        case .fresh: "leaf.arrow.triangle.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .quick: .accentColor
        case .purge: .orange
        case .fresh: .green
        }
    }

    var summary: String {
        switch self {
        case .quick: "Idle items that started with your login, plus your unwanted list. They'll be asked to quit."
        case .purge: "Heavy or suspicious processes. Checked items will be force-quit."
        case .fresh: "Like a restart without restarting: every app and background process is asked to quit. Your Do Not Prune list, Prune itself and the core parts of macOS stay. Apps with unsaved work will ask first."
        }
    }

    var emptyHint: String {
        switch self {
        case .quick: "Right-click a process and choose Add to Quick Clean List."
        case .purge: "No process crossed your thresholds. Adjust them in Settings (⌘,)."
        case .fresh: "Everything running is on your Do Not Prune list or part of macOS."
        }
    }
}
