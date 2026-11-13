import Foundation

/// v495: conversions that cannot trap. `UInt64(Double)` and `Int(Double)` crash the app on NaN, infinity and (for
/// UInt64) negative numbers, and durations / delays that come from other apps or from a web server can be any of those
/// (a live stream reports an infinite length, a server can send "Retry-After: nan").
extension Double {
    /// A usable length of time: finite and not negative, otherwise 0.
    var sanitizedSeconds: Double { isFinite && self > 0 ? self : 0 }

    /// Nanoseconds for `Task.sleep(nanoseconds:)`: NaN and negative become 0, infinity and huge values stop at one hour.
    var sleepNanoseconds: UInt64 {
        if isNaN || self <= 0 { return 0 }
        return UInt64(Swift.min(self, 3600) * 1_000_000_000)
    }

    /// A whole number for display or logging, 0 when the value is NaN or infinite.
    var finiteInt: Int {
        guard isFinite else { return 0 }
        return Int(Swift.max(Swift.min(self, 1e12), -1e12))
    }
}
