import AppKit
import SwiftUI

@main
struct PruneApp: App {
    @StateObject private var store = ProcessStore()

    var body: some Scene {
        Window("Prune", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1040, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .importExport) {
                Button("Import Do Not Prune List…") { store.importKeep() }
                Button("Export Do Not Prune List…") { store.exportKeep() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// App icons for processes. Helpers inside an .app bundle get their app's icon.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(for p: ProcInfo) -> NSImage {
        guard let r = p.path.range(of: ".app/") else { return generic }
        let bundle = String(p.path[..<r.lowerBound]) + ".app"
        if let cached = cache[bundle] { return cached }
        let img = NSWorkspace.shared.icon(forFile: bundle)
        cache[bundle] = img
        return img
    }
}

/// Gives SwiftUI views access to their hosting NSWindow (for pinning and compact resizing).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Drop-in for `@State`. The macOS 27 SDK turns `@State` into a macro whose plugin ships only
/// with Xcode, so Command Line Tools builds can't expand it. This wraps the `State` type directly.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

/// `PRUNE_SNAPSHOT=/path/file.png` renders the main window to a PNG after launch, and `PRUNE_DRYRUN=1`
/// prints the clean plans. Used to check the app without Screen Recording permission.
enum Snapshot {
    @MainActor
    static func scheduleIfRequested(_ store: ProcessStore) {
        if ProcessInfo.processInfo.environment["PRUNE_DRYRUN"] != nil {
            // Prints what each clean would offer, then exits. Ends nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                for plan in [Cleaner.quickClean(store), Cleaner.freshStart(store)] {
                    print("== \(plan.kind.title): \(plan.items.count)")
                    for i in plan.items { print("  \(i.proc.name) [\(i.reasons.joined(separator: ", "))]") }
                }
                exit(0)
            }
        }
        guard let path = ProcessInfo.processInfo.environment["PRUNE_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
