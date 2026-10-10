import XCTest
import Foundation
@testable import VaultlineLabsDriveInspector

@MainActor
final class ExporterTimeoutTests: XCTestCase {

    /// Test that a fast work closure returns its value before timing out.
    func testFastWorkReturnsValue() async throws {
        let result = try await Exporter.withTimeout(.seconds(10)) {
            return Data(bytes: [1, 2, 3], count: 3)
        }
        XCTAssertEqual(result, Data(bytes: [1, 2, 3], count: 3))
    }

    /// Test that a slow work closure that never completes eventually times out.
    func testSlowWorkTimesOut() async throws {
        let clock = ContinuousClock()
        let startTime = clock.now

        do {
            _ = try await Exporter.withTimeout(.milliseconds(200)) {
                // Hang forever by creating a continuation and never resuming it
                enum Holder {
                    static var leak: CheckedContinuation<Data, Error>?
                }
                return try await withCheckedThrowingContinuation { c in
                    Holder.leak = c
                }
            }
            XCTFail("Expected timeout error but got success")
        } catch Exporter.ExportError.pdfTimedOut {
            // Expected
            let elapsed = clock.now - startTime
            // Should complete within ~1-2 seconds (200ms timeout + overhead)
            // Be generous with the bound to avoid flakiness
            XCTAssertLessThan(elapsed.timeInterval, 3.0,
                            "timeout took too long: \(elapsed.timeInterval)s")
        }
    }

    /// Test that an error in the work closure is propagated properly.
    func testWorkErrorIsPropagated() async throws {
        enum TestError: Error {
            case testFailed
        }

        do {
            _ = try await Exporter.withTimeout(.seconds(10)) {
                throw TestError.testFailed
            }
            XCTFail("Expected error to be thrown")
        } catch TestError.testFailed {
            // Expected
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
