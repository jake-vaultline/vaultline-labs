import Foundation

/// Persists access to folders the user picked, across launches.
///
/// In a sandbox, a saved *path* is worthless — permission comes from the user
/// choosing the folder, and it evaporates on quit. Security-scoped bookmarks are
/// what make "remember my destinations" possible without asking someone to
/// re-pick two folders before every card.
enum Bookmarks {

    private static let key = "destination-bookmarks"

    static func save(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        var all = stored()
        all[url.path] = data
        UserDefaults.standard.set(all, forKey: key)
    }

    static func remove(path: String) {
        var all = stored()
        all.removeValue(forKey: path)
        UserDefaults.standard.set(all, forKey: key)
    }

    static func has(path: String) -> Bool { stored()[path] != nil }

    /// Resolves and starts access. Caller must `stopAccessing` when finished.
    static func resolve(path: String) -> URL? {
        guard let data = stored()[path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { save(url) }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}

/// Holds security scopes open for the duration of an ingest and releases them
/// afterwards, so a long offload can't lose write access halfway through.
final class ScopeHolder {
    private var urls: [URL] = []

    func open(paths: [String]) -> [String] {
        var ok: [String] = []
        for p in paths {
            if let u = Bookmarks.resolve(path: p) {
                urls.append(u)
                ok.append(p)
            }
        }
        return ok
    }

    func releaseAll() {
        for u in urls { u.stopAccessingSecurityScopedResource() }
        urls.removeAll()
    }

    deinit { releaseAll() }
}
