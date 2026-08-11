import Foundation

/// Streaming xxHash64.
///
/// Implemented here because macOS ships no xxHash, and because xxHash64 is what
/// the offload world actually uses — Hedge, Silverstack and ASC MHL all default
/// to it. At several GB/s it keeps the checksum off the critical path; MD5 would
/// make hashing slower than the disk and turn verification into the bottleneck.
///
/// Streaming rather than one-shot so a 60 GB master never lands in memory.
struct XXHash64 {

    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261

    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var buffered = 0
    private var total: UInt64 = 0
    private let seed: UInt64

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    // MARK: Update

    mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        total &+= UInt64(data.count)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            let count = raw.count

            // Top up a partial stripe first.
            if buffered > 0 {
                let need = min(32 - buffered, count)
                for i in 0..<need { buffer[buffered + i] = raw[i] }
                buffered += need
                offset += need
                if buffered == 32 {
                    buffer.withUnsafeBytes { consumeStripe($0, at: 0) }
                    buffered = 0
                }
            }

            // Whole 32-byte stripes straight from the input.
            while offset + 32 <= count {
                consumeStripe(raw, at: offset)
                offset += 32
            }

            // Keep the remainder for next time.
            if offset < count {
                let rest = count - offset
                for i in 0..<rest { buffer[i] = raw[offset + i] }
                buffered = rest
            }
        }
    }

    private mutating func consumeStripe(_ p: UnsafeRawBufferPointer, at offset: Int) {
        v1 = Self.round(v1, le64(p, offset))
        v2 = Self.round(v2, le64(p, offset + 8))
        v3 = Self.round(v3, le64(p, offset + 16))
        v4 = Self.round(v4, le64(p, offset + 24))
    }

    // MARK: Finalize

    func finalize() -> UInt64 {
        var h: UInt64

        if total >= 32 {
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = Self.mergeRound(h, v1)
            h = Self.mergeRound(h, v2)
            h = Self.mergeRound(h, v3)
            h = Self.mergeRound(h, v4)
        } else {
            h = seed &+ Self.p5
        }

        h &+= total

        var i = 0
        buffer.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            while i + 8 <= buffered {
                let k = Self.round(0, le64(p, i))
                h ^= k
                h = rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= buffered {
                h ^= UInt64(le32(p, i)) &* Self.p1
                h = rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < buffered {
                h ^= UInt64(p[i]) &* Self.p5
                h = rotl(h, 11) &* Self.p1
                i += 1
            }
        }

        // Avalanche
        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    /// Lowercase 16-character hex, which is how MHL writes it.
    func hexDigest() -> String { String(format: "%016llx", finalize()) }

    // MARK: Primitives

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* p2)
        a = rotl(a, 31)
        return a &* p1
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let v = round(0, val)
        var a = acc ^ v
        a = a &* p1 &+ p4
        return a
    }
}

@inline(__always) private func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
    (x << r) | (x >> (64 - r))
}

@inline(__always) private func le64(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(p[o + i]) << (8 * UInt64(i)) }
    return v
}

@inline(__always) private func le32(_ p: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(p[o + i]) << (8 * UInt32(i)) }
    return v
}

// MARK: - Algorithm selection

enum ChecksumAlgorithm: String, CaseIterable, Identifiable, Codable {
    case xxhash64, md5, sha1
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xxhash64: return "xxHash64 (fast, recommended)"
        case .md5:      return "MD5 (slow, widely required)"
        case .sha1:     return "SHA-1 (slow)"
        }
    }
    /// The string ASC MHL expects.
    var mhlName: String {
        switch self {
        case .xxhash64: return "xxh64"
        case .md5:      return "md5"
        case .sha1:     return "sha1"
        }
    }
}

/// One interface over the three algorithms so the offload engine doesn't branch.
struct StreamingHasher {
    private var xx: XXHash64?
    private var cc: CCHasher?

    init(_ algorithm: ChecksumAlgorithm) {
        switch algorithm {
        case .xxhash64: xx = XXHash64()
        case .md5:      cc = CCHasher(.md5)
        case .sha1:     cc = CCHasher(.sha1)
        }
    }

    mutating func update(_ data: Data) {
        xx?.update(data)
        cc?.update(data)
    }

    func hexDigest() -> String {
        if let xx { return xx.hexDigest() }
        if let cc { return cc.hexDigest() }
        return ""
    }
}
