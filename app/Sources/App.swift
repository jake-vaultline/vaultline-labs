import SwiftUI

@main
struct VaultlineLabsDriveInspectorApp: App {
    @StateObject private var engine = ScanEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 900, minHeight: 640)
                // Dark only, matching Vaultline Ingest — the two ship together
                // and every tool they sit beside is dark.
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
