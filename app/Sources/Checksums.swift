import Foundation
import CryptoKit

/// MD5 / SHA-1 wrapper. Both are cryptographically dead — they're here purely
/// because some facilities and delivery specs still mandate them for offload
/// manifests, and refusing would just mean the tool doesn't get used there.
/// xxHash64 is the default for everything else.
struct CCHasher {
    enum Kind { case md5, sha1 }

    private var md5: Insecure.MD5?
    private var sha1: Insecure.SHA1?

    init(_ kind: Kind) {
        switch kind {
        case .md5:  md5 = Insecure.MD5()
        case .sha1: sha1 = Insecure.SHA1()
        }
    }

    mutating func update(_ data: Data) {
        md5?.update(data: data)
        sha1?.update(data: data)
    }

    func hexDigest() -> String {
        if let md5  { return md5.finalize().map  { String(format: "%02x", $0) }.joined() }
        if let sha1 { return sha1.finalize().map { String(format: "%02x", $0) }.joined() }
        return ""
    }
}
