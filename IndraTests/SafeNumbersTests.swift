import XCTest
@testable import Indra

final class SafeNumbersTests: XCTestCase {
    func testSleepNanosecondsNeverTraps() {
        XCTAssertEqual(Double.nan.sleepNanoseconds, 0)
        XCTAssertEqual((-3.0).sleepNanoseconds, 0)
        XCTAssertEqual(Double.infinity.sleepNanoseconds, 3_600_000_000_000)
        XCTAssertEqual(1.5.sleepNanoseconds, 1_500_000_000)
    }

    func testSanitizedSeconds() {
        XCTAssertEqual(Double.infinity.sanitizedSeconds, 0)
        XCTAssertEqual(Double.nan.sanitizedSeconds, 0)
        XCTAssertEqual((-1.0).sanitizedSeconds, 0)
        XCTAssertEqual(212.5.sanitizedSeconds, 212.5)
    }

    func testFiniteInt() {
        XCTAssertEqual(Double.nan.finiteInt, 0)
        XCTAssertEqual(Double.infinity.finiteInt, 0)
        XCTAssertEqual(41.9.finiteInt, 41)
    }

    func testRetryDelayIgnoresNaN() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 10)
        XCTAssertEqual(policy.delay(afterAttempt: 0, retryAfter: .nan), 1)
        XCTAssertNil(Net.retryAfter(from: "nan"))
        XCTAssertNil(Net.retryAfter(from: "inf"))
    }
}
