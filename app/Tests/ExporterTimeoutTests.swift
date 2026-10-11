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

    /// Test that a zero timeout fires immediately, even if work sleeps.
    /// This tests the race condition where the timer fires before wait() registers
    /// the continuation. With zero timeout, the timer should fire almost instantly
    /// and interrupt any work, even if it's trying to sleep.
    func testZeroTimeoutFiresImmediately() async throws {
        let clock = ContinuousClock()
        let startTime = clock.now

        do {
            _ = try await Exporter.withTimeout(.zero) {
                // Try to sleep for 1 second, but should be interrupted by timeout
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return Data()
            }
            XCTFail("Expected timeout error but got success")
        } catch Exporter.ExportError.pdfTimedOut {
            // Expected
            let elapsed = clock.now - startTime
            XCTAssertLessThan(elapsed.timeInterval, 2.0,
                            "zero timeout took too long: \(elapsed.timeInterval)s")
        }
    }

    /// Test that an immediate work error propagates with a reasonable timeout.
    /// With immediate error (synchronous throw at the closure's entry), the work
    /// error should propagate before the timeout fires.
    func testImmediateWorkErrorPropagates() async throws {
        enum TestError: Error {
            case immediate
        }

        do {
            _ = try await Exporter.withTimeout(.seconds(1)) {
                throw TestError.immediate
            }
            XCTFail("Expected error to be thrown")
        } catch TestError.immediate {
            // Expected - the work error propagates
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
