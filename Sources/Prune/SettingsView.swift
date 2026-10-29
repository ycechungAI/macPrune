import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ProcessStore
    @AppStorage(Prefs.interval) private var interval = 2.0
    @AppStorage(Prefs.cpuThreshold) private var cpu = 80.0
    @AppStorage(Prefs.memThresholdGB) private var memGB = 2.0
    @AppStorage(Prefs.gpuThreshold) private var gpu = 50.0
    @AppStorage(Prefs.cleanWindowMin) private var cleanWindow = 5.0

    var body: some View {
        Form {
            Section("Monitoring") {
                Picker("Refresh every", selection: $interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
            Section("Purge flags processes using more than") {
                LabeledContent("CPU") {
                    Stepper("\(Int(cpu))%", value: $cpu, in: 10...800, step: 10)
                }
                LabeledContent("Memory") {
                    Stepper(String(format: "%.1f GB", memGB), value: $memGB, in: 0.5...32, step: 0.5)
                }
                LabeledContent("GPU") {
                    Stepper("\(Int(gpu))%", value: $gpu, in: 10...100, step: 5)
                }
            }
            Section("Quick Clean") {
                LabeledContent("Counts as “started at login”") {
                    Stepper("first \(Int(cleanWindow)) min", value: $cleanWindow, in: 1...30)
                }
                if store.unwanted.isEmpty {
                    Text("No unwanted processes yet. Right-click a process and choose Add to Quick Clean List.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.unwanted, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button { store.toggleUnwanted(name) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section {
                if store.keep.isEmpty {
                    Text("Nothing protected yet. Right-click a process and choose Add to Do Not Prune List. Quick Clean and Purge will never offer it.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.keep, id: \.self) { name in
                        HStack {
                            Image(systemName: "leaf.fill").foregroundStyle(.green)
                            Text(name)
                            Spacer()
                            Button { store.toggleKeep(name) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove from Do Not Prune list")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Do Not Prune (\(store.keep.count))")
                    Spacer()
                    Button("Import…") { store.importKeep() }
                    Button("Export…") { store.exportKeep() }
                        .disabled(store.keep.isEmpty)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: interval) { store.schedule() }
    }
}
