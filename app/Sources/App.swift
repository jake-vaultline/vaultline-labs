import SwiftUI

@main
struct VaultlineIngestApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            IngestView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 640)
                // Dark only, on purpose. Every tool this sits beside — Resolve,
                // Premiere, Hedge — is dark, because people cut and grade in
                // dark rooms and a white window in the middle of that is an
                // intrusion. It's also the brand's own direction.
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Shared formatting

enum F {
    static func bytes(_ v: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB, .useMB, .useKB]
        return f.string(fromByteCount: v)
    }
    static func count(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func quantity(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(self.count(count)) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
    static func rate(_ mbps: Double) -> String {
        mbps <= 0 ? "—" : String(format: "%.0f MB/s", mbps)
    }
    static func eta(_ p: OffloadProgress) -> String {
        let remaining = p.totalBytes - p.bytesCopied
        let rate = p.throughputMBps * 1_000_000
        guard rate > 0, remaining > 0 else { return "—" }
        let s = Double(remaining) / rate
        if s < 90   { return "\(Int(s))s left" }
        if s < 5400 { return "\(Int(s / 60))m left" }
        return String(format: "%.1fh left", s / 3600)
    }
}
