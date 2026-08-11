import XCTest
@testable import VaultlineIngest

final class KeychainTests: XCTestCase {
    func testCredentialRoundTripsAndDeletes() {
        let key = "test-device-only-\(UUID().uuidString)"
        defer { Keychain.delete(key) }

        XCTAssertEqual(Keychain.set("temporary-secret", for: key), errSecSuccess)
        XCTAssertEqual(Keychain.get(key), "temporary-secret")
        Keychain.delete(key)
        XCTAssertNil(Keychain.get(key))
    }
}
