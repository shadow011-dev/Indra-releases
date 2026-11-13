import AppKit
import XCTest
@testable import Indra

final class RetryPolicyTests: XCTestCase {
    func testRetriesOnlyBusyAnswers() {
        let policy = RetryPolicy()
        for code in [429, 500, 502, 503, 504] { XCTAssertTrue(policy.shouldRetry(status: code), "\(code)") }
        for code in [200, 204, 400, 401, 403, 404] { XCTAssertFalse(policy.shouldRetry(status: code), "\(code)") }
    }

    func testRetriesPassingNetworkErrorsOnly() {
        let policy = RetryPolicy()
        XCTAssertTrue(policy.shouldRetry(error: URLError(.timedOut)))
        XCTAssertTrue(policy.shouldRetry(error: URLError(.networkConnectionLost)))
        XCTAssertFalse(policy.shouldRetry(error: URLError(.cancelled)))
        XCTAssertFalse(policy.shouldRetry(error: URLError(.badURL)))
        XCTAssertFalse(policy.shouldRetry(error: NSError(domain: "other", code: 1)))
    }

    func testBackoffDoublesAndStopsAtTheMaximum() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 6)
        XCTAssertEqual(policy.delay(afterAttempt: 0), 1)
        XCTAssertEqual(policy.delay(afterAttempt: 1), 2)
        XCTAssertEqual(policy.delay(afterAttempt: 2), 4)
        XCTAssertEqual(policy.delay(afterAttempt: 3), 6)
    }

    func testServerWishWinsButIsCapped() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 10)
        XCTAssertEqual(policy.delay(afterAttempt: 0, retryAfter: 3), 3)
        XCTAssertEqual(policy.delay(afterAttempt: 0, retryAfter: 120), 10)
        XCTAssertEqual(policy.delay(afterAttempt: 0, retryAfter: -5), 0)
    }
}

final class RetryAfterHeaderTests: XCTestCase {
    func testSeconds() {
        XCTAssertEqual(Net.retryAfter(from: "120"), 120)
        XCTAssertEqual(Net.retryAfter(from: " 7 "), 7)
    }

    func testHttpDate() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = try XCTUnwrap(formatter.date(from: "2015-10-21 07:27:30"))
        let wait = try XCTUnwrap(Net.retryAfter(from: "Wed, 21 Oct 2015 07:28:00 GMT", now: now))
        XCTAssertEqual(wait, 30, accuracy: 0.5)
    }

    func testMissingOrUnreadable() {
        XCTAssertNil(Net.retryAfter(from: nil))
        XCTAssertNil(Net.retryAfter(from: ""))
        XCTAssertNil(Net.retryAfter(from: "soon"))
    }
}

final class ImageCacheTests: XCTestCase {
    /// A picture that is already cached is returned without any network request.
    func testCachedPictureNeedsNoNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IndraTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 1_000_000, directory: folder)
        // Reserved test domain: if the cache were skipped, this would fail instead of returning the bytes.
        let url = try XCTUnwrap(URL(string: "https://cover.invalid/a.jpg"))
        let bytes = Data([1, 2, 3, 4])
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes),
                                  for: URLRequest(url: url, timeoutInterval: 10))
        let data = await Net.cachedData(for: url, cache: cache)
        XCTAssertEqual(data, bytes)
    }

    func testBoundedImageCacheEvictsTheOldest() {
        let cache = BoundedImageCache<String>(limit: 2)
        cache["a"] = NSImage(size: NSSize(width: 1, height: 1))
        cache["b"] = NSImage(size: NSSize(width: 1, height: 1))
        cache["c"] = NSImage(size: NSSize(width: 1, height: 1))
        XCTAssertNil(cache["a"])
        XCTAssertNotNil(cache["b"])
        XCTAssertNotNil(cache["c"])
    }

    /// v523: the byte budget evicts the oldest pictures even when the count limit is far away, and keeps the newest.
    func testBoundedImageCacheIsLimitedByBytes() {
        // Each picture is 100 x 100 px = 40 000 bytes; the budget holds two.
        let cache = BoundedImageCache<String>(limit: 100, byteLimit: 100_000)
        for key in ["a", "b", "c"] {
            let image = NSImage(size: NSSize(width: 100, height: 100))
            image.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) ?? NSBitmapImageRep())
            cache[key] = image
        }
        XCTAssertNil(cache["a"])
        XCTAssertNotNil(cache["b"])
        XCTAssertNotNil(cache["c"])
    }
}
