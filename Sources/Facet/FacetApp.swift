import SwiftUI
import AppKit

@main
struct FacetApp: App {
    @StateObject private var model = ReconstructionModel()

    init() {
        // Also allows launching via `swift run` without an app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Facet") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
