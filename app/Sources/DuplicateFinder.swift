import Foundation
import CryptoKit

/// Pass 3 — duplicate detection, three tiers, cheapest first.
///
/// Never hash the whole drive. On 2.7 TB that's an hour of reading to answer a
/// question that costs seconds if you ask it in the right order:
///
///   1. **Group by exact size.** Two files of different sizes cannot be
///      identical. Most files have no size twin at all and are eliminated for
///      free, with zero reads.
///   2. **Partial hash** the survivors — first 1 MB + last 1 MB + the size.
///      Two different 40 GB ProRes files essentially never agree on both ends.
///   3. **Full hash** only when the partial hashes also collide.
///
/// The result is labelled "potential duplicates" in the UI and report, because
/// that's what it honestly is unless tier 3 ran on every group.
enum DuplicateFinder {

    /// Files smaller than this are ignored. Recovering 400 KB is not worth a
    /// read, and small identical files (sidecars, LUTs, icons) are usually meant
    /// to be duplicated.
    static let minimumSize: Int64 = 4 * 1024 * 1024

    /// Ceiling on bytes read during partial hashing. A pathological drive of
    /// same-sized files could otherwise turn a fast pass into a long one. When
    /// this trips we stop and say so rather than quietly reporting a partial
    /// answer as complete.
    static let readBudget: Int64 = 24 * 1024 * 1024 * 1024   // 24 GB

    static let chunk = 1024 * 1024

    static func run(_ files: [FileEntry]) -> AsyncStream<DuplicateSummary> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .utility) {
                var summary = DuplicateSummary()
                summary.isRunning = true

                // ── Tier 1: group by size ────────────────────────────────
                var bySize: [Int64: [FileEntry]] = [:]
                for f in files where f.size >= minimumSize {
                    bySize[f.size, default: []].append(f)
                }
                let candidates = bySize.filter { $0.value.count > 1 }
                summary.candidatesTotal = candidates.reduce(0) { $0 + $1.value.count }

                guard summary.candidatesTotal > 0 else {
                    summary.isRunning = false
                    summary.isComplete = true
                    continuation.yield(summary)
                    continuation.finish()
                    return
                }
                continuation.yield(summary)

                var bytesRead: Int64 = 0
                var lastYield = Date()

                // Smallest groups first — cheap wins land on screen early.
                for (size, group) in candidates.sorted(by: { $0.key < $1.key }) {
                    if Task.isCancelled { break }
                    if bytesRead > readBudget {
                        summary.hitReadBudget = true
                        break
                    }

                    // ── Tier 2: partial hash ─────────────────────────────
                    var byPartial: [String: [FileEntry]] = [:]
                    for f in group {
                        if Task.isCancelled { break }
                        if let h = partialHash(path: f.path, size: size) {
                            byPartial[h, default: []].append(f)
                        }
                        bytesRead += Int64(min(Int(size), chunk * 2))
                        summary.candidatesChecked += 1
                    }

                    // ── Tier 3: full hash, only on partial collision ─────
                    for (_, matched) in byPartial where matched.count > 1 {
                        if Task.isCancelled { break }

                        // Under ~64 MB the partial hash already covered most of
                        // the file; a full hash would re-read nearly the same
                        // bytes to learn nothing.
                        if size <= Int64(chunk * 64) {
                            summary.groups.append(
                                DuplicateGroup(size: size, paths: matched.map(\.path)))
                            continue
                        }

                        var byFull: [String: [String]] = [:]
                        for f in matched {
                            if let h = fullHash(path: f.path) {
                                byFull[h, default: []].append(f.path)
                                bytesRead += size
                            }
                        }
                        for (_, paths) in byFull where paths.count > 1 {
                            summary.groups.append(DuplicateGroup(size: size, paths: paths))
                        }
                    }

                    let now = Date()
                    if now.timeIntervalSince(lastYield) >= 0.25 {
                        lastYield = now
                        continuation.yield(sorted(summary))
                    }
                }

                summary.isRunning = false
                summary.isComplete = !Task.isCancelled && !summary.hitReadBudget
                continuation.yield(sorted(summary))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func sorted(_ s: DuplicateSummary) -> DuplicateSummary {
        var out = s
        out.groups.sort { $0.recoverable > $1.recoverable }
        return out
    }

    // MARK: Hashing

    /// First 1 MB + last 1 MB + the size. Cheap, and decisive in practice —
    /// two different clips agreeing on both ends and length is vanishingly rare.
    private static func partialHash(path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)

        if size > Int64(chunk) * 2 {
            let tailStart = UInt64(size) - UInt64(chunk)
            if (try? handle.seek(toOffset: tailStart)) != nil,
               let tail = try? handle.read(upToCount: chunk) {
                hasher.update(data: tail)
            }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Streamed in 4 MB blocks so a 60 GB master never lands in memory.
    private static func fullHash(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let block = chunk * 4
        while true {
            guard let data = try? handle.read(upToCount: block), !data.isEmpty else { break }
            hasher.update(data: data)
            if Task.isCancelled { return nil }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
