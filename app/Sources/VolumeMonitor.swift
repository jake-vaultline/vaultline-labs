import Foundation
import AppKit
import Darwin

// MARK: - Model

/// A drive the app has seen. Identified by volume UUID where macOS provides one,
/// so a drive keeps its history across renames and remounts — a registry keyed
/// on `/Volumes/Untitled` would merge three different cards into one entry.
struct KnownVolume: Codable, Identifiable {
    var id: String            // volume UUID, or a name+size fallback
    var name: String
    var lastPath: String
    var totalBytes: Int64
    var freeBytes: Int64
    var isRemovable: Bool
    var firstSeen: Date
    var lastSeen: Date
    var sightings: Int

    /// Snapshot from the most recent scan, kept for diffing against the next one.
    var snapshot: VolumeSnapshot?
    /// What changed between the previous scan and the current one.
    var lastChange: VolumeChange?

    /// Hosted Drive Passport identity. The physical tag remains a separate
    /// server-side record and can be reassigned without changing this drive.
    var passportDriveID: String? = nil
    var passportLastSyncedAt: Date? = nil
    var passportSyncState: String? = nil

    /// The actual filesystem UUID is separate from `id`, whose legacy fallback
    /// is name+capacity when macOS exposes no UUID. Never promote that fallback
    /// to a strong hosted identity signal.
    var volumeUUID: String? = nil
    var hardwareIdentity: VolumeHardwareIdentity? = nil

    var isMounted: Bool = false
}

/// A cheap fingerprint of a volume's contents. Deliberately *not* a full file
/// list — a 500k-file drive would make the registry enormous and the diff slow.
/// Path + size + mtime hashed per file, folded into a per-folder digest.
struct VolumeSnapshot: Codable {
    var takenAt: Date
    var fileCount: Int
    var totalBytes: Int64
    /// relative path → digest of (size, mtime) for the files directly inside
    var folders: [String: String]
    /// relative path → size, for top-level entries only (used to describe changes)
    var topLevel: [String: Int64]
    /// Asset-bearing folders selected by the user's local scan rule. Optional
    /// so snapshots from older app versions remain readable.
    var collections: [String: ScannedCollection]? = nil
}

/// A bounded inventory for one tracked folder. This is intentionally not a
/// content checksum: it compares relative paths and sizes without reading every
/// media byte. Ingest verification remains the authority for byte identity.
struct ScannedCollection: Codable, Equatable {
    var relativePath: String
    var name: String
    var fileCount: Int
    var totalBytes: Int64
    var inventoryFingerprint: String
}

struct DriveCopyFinding: Identifiable {
    enum Health: Equatable {
        case singleCopy, discrepancy, matchingCopies
    }

    struct Copy: Identifiable {
        var id: String { volumeID + "::" + relativePath }
        let volumeID: String
        let volumeName: String
        let relativePath: String
        let fileCount: Int
        let totalBytes: Int64
        let fingerprint: String
    }

    var id: String { name.folding(options: [.caseInsensitive], locale: .current) }
    let name: String
    let copies: [Copy]
    let health: Health
}

enum DriveCopyAnalyzer {
    static func findings(in volumes: [KnownVolume]) -> [DriveCopyFinding] {
        var grouped: [String: (name: String, copies: [DriveCopyFinding.Copy])] = [:]
        for volume in volumes {
            for collection in (volume.snapshot?.collections ?? [:]).values {
                let key = collection.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let copy = DriveCopyFinding.Copy(
                    volumeID: volume.id, volumeName: volume.name,
                    relativePath: collection.relativePath,
                    fileCount: collection.fileCount, totalBytes: collection.totalBytes,
                    fingerprint: collection.inventoryFingerprint)
                grouped[key, default: (collection.name, [])].copies.append(copy)
            }
        }

        return grouped.values.map { item in
            let fingerprints = Set(item.copies.map(\.fingerprint))
            let health: DriveCopyFinding.Health
            if item.copies.count == 1 { health = .singleCopy }
            else if fingerprints.count == 1 { health = .matchingCopies }
            else { health = .discrepancy }
            return DriveCopyFinding(
                name: item.name,
                copies: item.copies.sorted { ($0.volumeName, $0.relativePath) < ($1.volumeName, $1.relativePath) },
                health: health)
        }.sorted { lhs, rhs in
            func rank(_ health: DriveCopyFinding.Health) -> Int {
                switch health {
                case .discrepancy: return 0
                case .singleCopy: return 1
                case .matchingCopies: return 2
                }
            }
            return (rank(lhs.health), lhs.name) < (rank(rhs.health), rhs.name)
        }
    }
}

struct VolumeChange: Codable {
    var comparedAt: Date
    var previousAt: Date
    var filesAdded: Int
    var filesRemoved: Int
    var bytesDelta: Int64
    var foldersChanged: [String]

    var isEmpty: Bool { filesAdded == 0 && filesRemoved == 0 && foldersChanged.isEmpty }

    var summary: String {
        if isEmpty { return "Nothing changed since last time" }
        var bits: [String] = []
        if filesAdded > 0   { bits.append("+\(filesAdded) files") }
        if filesRemoved > 0 { bits.append("−\(filesRemoved) files") }
        if bytesDelta != 0 {
            let f = ByteCountFormatter(); f.countStyle = .file
            bits.append((bytesDelta > 0 ? "+" : "−") + f.string(fromByteCount: abs(bytesDelta)))
        }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Monitor

/// Watches for drives being plugged in, scans them, and remembers what they
/// looked like — so the next time the same drive appears the app can say what
/// changed.
///
/// This is the free app's standing value: even for someone who never ingests
/// anything, "here are your drives, here's when you last saw each one, here's
/// what moved" is a question nothing else answers.
///
/// **Local only.** One copy of this app cannot see another's drives — there is
/// no peer discovery or shared index. It knows only what has been plugged into
/// *this* Mac.
@MainActor
final class VolumeMonitor: ObservableObject {

    @Published private(set) var volumes: [KnownVolume] = []
    @Published private(set) var scanning: Set<String> = []

    private var scanRules: DriveScanRules
    var onScanCompleted: ((KnownVolume) -> Void)?

    /// Skip system and network volumes — the registry is about media drives.
    private let skipPaths = ["/", "/System/Volumes/Data", "/private/var/vm"]

    private var store: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaultline Ingest", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("volumes.json")
    }

    private var observers: [NSObjectProtocol] = []

    init(rules: DriveScanRules = DriveScanRules()) {
        scanRules = rules
        load()
        let nc = NSWorkspace.shared.notificationCenter
        // Hold the tokens — a block observer whose token is discarded can be
        // released, and the app would silently stop noticing drives.
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.didMount(url) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.didUnmount(url) }
        })
        refreshMounted()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
    }

    // MARK: Mount events

    private func didMount(_ url: URL) {
        guard let v = describe(url) else { return }
        upsert(v)
        // Automatic reading remains an explicit setting in the portable team
        // configuration; merely mounting a drive never opts it into scanning.
        if scanRules.automaticOnMount,
           let mounted = volumes.first(where: { $0.id == v.id }) {
            scan(mounted)
        }
    }

    private func didUnmount(_ url: URL) {
        if let i = volumes.firstIndex(where: { $0.lastPath == url.path }) {
            volumes[i].isMounted = false
            save()
        }
    }

    func refreshMounted() {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for i in volumes.indices { volumes[i].isMounted = false }
        for url in mounted where !skipPaths.contains(url.path) {
            if let v = describe(url) { upsert(v) }
        }
        save()
    }

    func updateScanRules(_ rules: DriveScanRules) {
        scanRules = rules
    }

    private func describe(_ url: URL) -> KnownVolume? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsInternalKey
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let name = v.volumeName ?? url.lastPathComponent
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let id = v.volumeUUIDString ?? "\(name)-\(total)"

        return KnownVolume(
            id: id, name: name, lastPath: url.path,
            totalBytes: total, freeBytes: Int64(v.volumeAvailableCapacity ?? 0),
            isRemovable: (v.volumeIsRemovable ?? false) || !(v.volumeIsInternal ?? true),
            firstSeen: Date(), lastSeen: Date(), sightings: 1,
            volumeUUID: v.volumeUUIDString,
            hardwareIdentity: VolumeHardwareIdentity.read(from: url),
            isMounted: true)
    }

    private func upsert(_ incoming: KnownVolume) {
        if let i = volumes.firstIndex(where: { $0.id == incoming.id }) {
            let wasMounted = volumes[i].isMounted
            volumes[i].name = incoming.name
            volumes[i].lastPath = incoming.lastPath
            volumes[i].freeBytes = incoming.freeBytes
            volumes[i].totalBytes = incoming.totalBytes
            if let uuid = incoming.volumeUUID { volumes[i].volumeUUID = uuid }
            if let identity = incoming.hardwareIdentity {
                volumes[i].hardwareIdentity = volumes[i].hardwareIdentity?.merging(identity) ?? identity
            }
            volumes[i].isMounted = true
            if !wasMounted {
                volumes[i].lastSeen = Date()
                volumes[i].sightings += 1
            }
        } else {
            volumes.append(incoming)
        }
        volumes.sort { ($0.isMounted ? 0 : 1, $0.name) < ($1.isMounted ? 0 : 1, $1.name) }
        save()
    }

    // MARK: Scanning + diffing

    /// Scans a mounted volume and, if it's been scanned before, works out what
    /// changed since. Explicit — never automatic on mount.
    func scan(_ volume: KnownVolume) {
        guard volume.isMounted, !scanning.contains(volume.id) else { return }
        scanning.insert(volume.id)
        let path = volume.lastPath
        let previous = volume.snapshot
        let id = volume.id
        let rules = scanRules

        Task.detached(priority: .utility) {
            let snap = VolumeScanner.snapshot(of: URL(fileURLWithPath: path), rules: rules)
            let change = previous.map { VolumeScanner.diff(from: $0, to: snap) }
            await MainActor.run {
                if let i = self.volumes.firstIndex(where: { $0.id == id }) {
                    self.volumes[i].snapshot = snap
                    if let change { self.volumes[i].lastChange = change }
                }
                self.scanning.remove(id)
                self.save()
                if let completed = self.volumes.first(where: { $0.id == id }) {
                    self.onScanCompleted?(completed)
                }
            }
        }
    }

    func forget(_ id: String) {
        volumes.removeAll { $0.id == id }
        save()
    }

    func recordPassport(volumeID: String, driveID: String, syncedAt: Date?, state: String) {
        guard let i = volumes.firstIndex(where: { $0.id == volumeID }) else { return }
        volumes[i].passportDriveID = driveID
        if let syncedAt { volumes[i].passportLastSyncedAt = syncedAt }
        volumes[i].passportSyncState = state
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: store),
              let decoded = try? JSONDecoder().decode([KnownVolume].self, from: data) else { return }
        volumes = decoded.map { var v = $0; v.isMounted = false; return v }
    }

    private func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(volumes) { try? data.write(to: store, options: .atomic) }
    }
}

// MARK: - Scanner

enum VolumeScanner {

    /// Folder-level fingerprint rather than a full file index.
    ///
    /// A per-file record of a 500k-file drive would be tens of megabytes of JSON
    /// per drive per scan, and the registry would outgrow the media it describes.
    /// Hashing (name, size, mtime) per folder catches every practical change —
    /// files added, removed, resized, replaced — at a fraction of the size.
    static func snapshot(of root: URL, rules: DriveScanRules = DriveScanRules()) -> VolumeSnapshot {
        var folders: [String: [UInt64]] = [:]
        var topLevel: [String: Int64] = [:]
        var collections: [String: CollectionAccumulator] = [:]
        var fileCount = 0
        var totalBytes: Int64 = 0
        let collectionPattern = rules.trimmedPattern
        let collectionRegex = collectionPattern.isEmpty ? nil : try? NSRegularExpression(
            pattern: collectionPattern, options: [.caseInsensitive])
        // FileManager may return canonical `/private/var/...` URLs while the
        // caller supplied the `/var/...` symlink. Canonicalize both the
        // enumeration root and prefix or relative paths become accidentally
        // rooted and all totals collapse under a bogus `private` folder.
        let canonicalRoot = canonicalURL(root)
        let base = canonicalRoot.path

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let e = FileManager.default.enumerator(
            at: canonicalRoot, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) {
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true else { continue }

                let size = Int64(v.fileSize ?? 0)
                let mtime = UInt64((v.contentModificationDate ?? .distantPast).timeIntervalSince1970)
                fileCount += 1
                totalBytes += size

                var rel = url.path
                if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
                rel = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel

                let dir = (rel as NSString).deletingLastPathComponent
                let name = (rel as NSString).lastPathComponent

                // FNV-1a over (name, size, mtime). Parenthesised deliberately —
                // `&*` binds tighter than `^` in Swift, so the unbracketed form
                // means something different from what it looks like.
                var h: UInt64 = 14695981039346656037
                for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
                h = (h ^ UInt64(bitPattern: size)) &* 1099511628211
                h = (h ^ mtime) &* 1099511628211
                folders[dir, default: []].append(h)

                // Every descendant contributes to its first path component.
                // Restricting this to files only one directory deep silently
                // understated normal Project/Day/Card media layouts.
                if let firstComponent = rel.split(separator: "/").first {
                    let top = String(firstComponent)
                    topLevel[top, default: 0] += size
                }

                let components = rel.split(separator: "/").map(String.init)
                guard components.count > 1 else { continue }
                let directoryComponents = Array(components.dropLast())
                for collectionPath in matchingCollectionPaths(
                    directoryComponents: directoryComponents,
                    patternIsEmpty: collectionPattern.isEmpty,
                    regex: collectionRegex) {
                    let prefixCount = collectionPath.split(separator: "/").count
                    let within = components.dropFirst(prefixCount).joined(separator: "/")
                    var itemHash: UInt64 = 14695981039346656037
                    for b in within.utf8 {
                        itemHash = (itemHash ^ UInt64(b)) &* 1099511628211
                    }
                    itemHash = (itemHash ^ UInt64(bitPattern: size)) &* 1099511628211
                    var item = collections[collectionPath] ?? CollectionAccumulator()
                    item.fileCount += 1
                    item.totalBytes += size
                    item.hashes.append(itemHash)
                    collections[collectionPath] = item
                }
            }
        }

        // Sorted before folding so the digest doesn't depend on directory
        // enumeration order — otherwise two identical drives could "differ".
        var digests: [String: String] = [:]
        for (dir, hashes) in folders {
            var folded: UInt64 = 14695981039346656037
            for h in hashes.sorted() { folded = (folded ^ h) &* 1099511628211 }
            digests[dir] = String(format: "%016llx-%d", folded, hashes.count)
        }

        var scannedCollections: [String: ScannedCollection] = [:]
        for (path, accumulator) in collections {
            var folded: UInt64 = 14695981039346656037
            for hash in accumulator.hashes.sorted() {
                folded = (folded ^ hash) &* 1099511628211
            }
            scannedCollections[path] = ScannedCollection(
                relativePath: path,
                name: (path as NSString).lastPathComponent,
                fileCount: accumulator.fileCount,
                totalBytes: accumulator.totalBytes,
                inventoryFingerprint: String(format: "%016llx-%d", folded, accumulator.fileCount))
        }

        return VolumeSnapshot(takenAt: Date(), fileCount: fileCount,
                              totalBytes: totalBytes, folders: digests, topLevel: topLevel,
                              collections: scannedCollections)
    }

    private struct CollectionAccumulator {
        var fileCount = 0
        var totalBytes: Int64 = 0
        var hashes: [UInt64] = []
    }

    private static func matchingCollectionPaths(
        directoryComponents: [String], patternIsEmpty: Bool,
        regex: NSRegularExpression?
    ) -> [String] {
        if patternIsEmpty {
            return directoryComponents.first.map { [$0] } ?? []
        }
        guard let regex else { return [] }

        var matches: [String] = []
        for index in directoryComponents.indices {
            let name = directoryComponents[index]
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, range: range)?.range == range {
                matches.append(directoryComponents[...index].joined(separator: "/"))
            }
        }
        return matches
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else {
                return url.standardizedFileURL
            }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved,
                       isDirectory: true, relativeTo: nil)
        }
    }

    static func diff(from old: VolumeSnapshot, to new: VolumeSnapshot) -> VolumeChange {
        var changed: [String] = []

        let allDirs = Set(old.folders.keys).union(new.folders.keys)
        for dir in allDirs where old.folders[dir] != new.folders[dir] {
            changed.append(dir.isEmpty ? "(root)" : dir)
        }
        changed.sort()

        let delta = new.fileCount - old.fileCount
        return VolumeChange(
            comparedAt: new.takenAt,
            previousAt: old.takenAt,
            filesAdded: max(0, delta),
            filesRemoved: max(0, -delta),
            bytesDelta: new.totalBytes - old.totalBytes,
            foldersChanged: Array(changed.prefix(50)))
    }
}
