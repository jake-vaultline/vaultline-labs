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
        let dir = URL(fileURLWithPath: destination.root, isDirectory: true)
        let baseName = "\(safe(sourceName))_\(fileStamp)"
        var url = dir.appendingPathComponent("\(baseName).mhl")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(baseName)-\(suffix).mhl")
            suffix += 1
        }

        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += "<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">\n"
        xml += "  <creatorinfo>\n"
        xml += "    <creationdate>\(stamp)</creationdate>\n"
        xml += "    <hostname>\(esc(Host.current().localizedName ?? "unknown"))</hostname>\n"
        xml += "    <tool version=\"\(appVersion)\">Vaultline Ingest</tool>\n"
        xml += "  </creatorinfo>\n"
        xml += "  <processinfo>\n"
        xml += "    <process>transfer</process>\n"
        xml += "  </processinfo>\n"
        xml += "  <hashes>\n"

        for f in verified {
            guard let hash = verifiedHash(f.destinations[destination.root]) else { continue }
            xml += "    <hash>\n"
            xml += "      <path size=\"\(f.size)\">\(esc(f.destinationRelativePath))</path>\n"
            xml += "      <\(algorithm.mhlName) action=\"original\">\(hash)</\(algorithm.mhlName)>\n"
            xml += "    </hash>\n"
        }

        xml += "  </hashes>\n</hashlist>\n"

        try AtomicNoReplaceWriter.write(Data(xml.utf8), to: url)
        return url
    }

    private static func verifiedHash(_ state: DestinationState?) -> String? {
        switch state {
        case .verified(let hash), .alreadyVerified(let hash): return hash
        default: return nil
        }
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

/// Writes small records atomically without ever replacing an existing file.
/// Foundation's `.atomic` and `.withoutOverwriting` options cannot safely be
/// combined on every supported macOS release, so publish a unique same-folder
/// temporary file with a no-replace move instead.
enum AtomicNoReplaceWriter {
    static func write(_ data: Data, to finalURL: URL,
                      fileManager: FileManager = .default) throws {
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".vaultline-record-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
    }
}
