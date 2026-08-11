import Foundation

/// Writes an ASC MHL (Media Hash List) sidecar.
///
/// A standard format rather than a bespoke one, on purpose: MHL is what the
/// offload world already reads, so a manifest from a free tool can be handed to
/// a facility, an archivist, or a competing product and simply work. A
/// proprietary `.json` would make the app an island, and nobody trusts an island
/// with their only copy.
///
/// **Only verified files are listed.** A manifest that includes files whose
/// checksums were never confirmed is worse than no manifest — it launders a
/// guess into a record.
enum MHLWriter {

    static func write(files: [IngestFile],
                      destination: Destination,
                      algorithm: ChecksumAlgorithm,
                      sourceName: String) throws -> URL {

        let verified = files.filter { $0.destinations[destination.root]?.isVerified == true }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let fileStamp = stamp.replacingOccurrences(of: ":", with: "-")
        let dir = URL(fileURLWithPath: destination.root).appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("\(safe(sourceName))_\(fileStamp).mhl")

        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += "<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">\n"
        xml += "  <creatorinfo>\n"
        xml += "    <creationdate>\(stamp)</creationdate>\n"
        xml += "    <hostname>\(esc(Host.current().localizedName ?? "unknown"))</hostname>\n"
        xml += "    <tool version=\"\(appVersion)\">Vaultline Ingest</tool>\n"
        xml += "  </creatorinfo>\n"
        xml += "  <processinfo>\n"
        xml += "    <process>in-place</process>\n"
        xml += "    <roothash><\(algorithm.mhlName)>\(rootHash(verified, destination: destination))</\(algorithm.mhlName)></roothash>\n"
        xml += "  </processinfo>\n"
        xml += "  <hashes>\n"

        for f in verified {
            guard case .verified(let hash)? = f.destinations[destination.root] else { continue }
            xml += "    <hash>\n"
            xml += "      <path size=\"\(f.size)\">\(esc(f.relativePath))</path>\n"
            xml += "      <\(algorithm.mhlName) action=\"verified\">\(hash)</\(algorithm.mhlName)>\n"
            xml += "    </hash>\n"
        }

        xml += "  </hashes>\n</hashlist>\n"

        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A hash over the per-file hashes, so the manifest as a whole can be
    /// checked without re-reading the media.
    private static func rootHash(_ files: [IngestFile], destination: Destination) -> String {
        var hasher = XXHash64()
        for f in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard case .verified(let hash)? = f.destinations[destination.root] else { continue }
            if let d = (f.relativePath + hash).data(using: .utf8) { hasher.update(d) }
        }
        return hasher.hexDigest()
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static func safe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
         .joined(separator: "-")
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
