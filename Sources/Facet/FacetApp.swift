import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ReconstructionModel()

    /// Double-clicked .facet files (also when Facet is launched by them).
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.pathExtension.lowercased() == "facet" }) {
            model.openProject(at: url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.confirmDiscardIfNeeded("quitting") ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct FacetCommands: Commands {
    @ObservedObject var model: ReconstructionModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") { model.openProjectPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { model.save() }
                .keyboardShortcut("s")
                .disabled(model.result == nil)
            Button("Save Project As…") { model.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.result == nil)
        }
    }
}

@main
struct FacetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Also allows launching via `swift run` without an app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Facet") {
            ContentView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands { FacetCommands(model: appDelegate.model) }
    }
}
