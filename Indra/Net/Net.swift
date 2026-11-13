import Foundation

/// v437: when and how long a failed request is tried again. Only answers that mean "try again later" (429 and the 5xx
/// family) and network errors that usually pass by themselves are retried; a 400, 401, 403 or 404 is final.
struct RetryPolicy: Equatable {
    var maxAttempts = 3
    var baseDelay: TimeInterval = 1
    var maxDelay: TimeInterval = 15

    func shouldRetry(status: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(status)
    }

    func shouldRetry(error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        let transient: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
        return transient.contains(code)
    }

    /// Seconds to wait after try number `attempt` (0 is the first) failed: the server's own wish when it sent one,
    /// otherwise 1, 2, 4 ... seconds. Never more than `maxDelay`.
    func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        // v495: a NaN here (a "Retry-After: nan" header) went straight into UInt64() and stopped the app.
        if let retryAfter, retryAfter.isFinite { return min(max(retryAfter, 0), maxDelay) }
        let backoff = baseDelay * pow(2, Double(min(max(attempt, 0), 30)))
        return backoff.isFinite ? min(max(backoff, 0), maxDelay) : maxDelay
    }
}

/// v437: shared network helpers. One retry rule for the web APIs Indra talks to (Spotify, the weather service) and a
/// disk cache for pictures, so a cover seen once loads at once next time and still shows when offline.
enum Net {
    // MARK: Retry

    /// One request, tried again after a 429 / 5xx answer or a passing network error (see `RetryPolicy`). Returns the
    /// last answer, whatever its status, so the caller decides what a 401 or a 404 means.
    static func send(_ request: URLRequest,
                     session: URLSession = .shared,
                     policy: RetryPolicy = RetryPolicy()) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if policy.shouldRetry(status: http.statusCode), attempt + 1 < policy.maxAttempts {
                    let wait = policy.delay(afterAttempt: attempt,
                                            retryAfter: retryAfter(from: http.value(forHTTPHeaderField: "Retry-After")))
                    Trace.log("NET \(http.statusCode) from \(request.url?.host ?? "?"): trying again in \(String(format: "%.1f", wait)) s")
                    try await Task.sleep(nanoseconds: wait.sleepNanoseconds)
                    attempt += 1
                    continue
                }
                return (data, http)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw error }
                guard policy.shouldRetry(error: error), attempt + 1 < policy.maxAttempts else { throw error }
                let wait = policy.delay(afterAttempt: attempt)
                Trace.log("NET network error from \(request.url?.host ?? "?"): trying again in \(String(format: "%.1f", wait)) s")
                try await Task.sleep(nanoseconds: wait.sleepNanoseconds)
                attempt += 1
            }
        }
    }

    /// A "Retry-After" header: a number of seconds, or an HTTP date. Nil when absent or unreadable.
    static func retryAfter(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return seconds.isFinite ? max(seconds, 0) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(date.timeIntervalSince(now), 0) }
        return nil
    }

    // MARK: Pictures

    /// Pictures downloaded from the web (Spotify's album art for the queue, say), kept in the Caches folder. macOS may
    /// clear that folder; the pictures are then simply fetched again.
    static let imageCache: URLCache = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return URLCache(memoryCapacity: 16 * 1024 * 1024,
                        diskCapacity: 150 * 1024 * 1024,
                        directory: base.appendingPathComponent("IndraImages", isDirectory: true))
    }()

    /// The bytes at `url`: from the cache when they are there (no network at all), otherwise downloaded (with the
    /// retry rule) and kept for next time. Nil when there is no cached copy and the download failed.
    static func cachedData(for url: URL, cache: URLCache = Net.imageCache) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 10)
        if let hit = cache.cachedResponse(for: request), !hit.data.isEmpty { return hit.data }
        guard let (data, http) = try? await send(request, policy: RetryPolicy(maxAttempts: 2, baseDelay: 1, maxDelay: 4)),
              http.statusCode == 200, !data.isEmpty else { return nil }
        cache.storeCachedResponse(CachedURLResponse(response: http, data: data), for: request)
        return data
    }
}
