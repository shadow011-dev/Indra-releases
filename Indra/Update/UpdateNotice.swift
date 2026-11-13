import SwiftUI

/// v553: how the notch tells the person that a new version is ready.
///
///  * The CARD: "Update available (version N)" hangs below the closed notch for 4 seconds, at most twice a day (the first time
///    as soon as the version is found and the notch is free, the second at least 4 hours later). A new version always gets its
///    own two.
///  * The SYMBOL: while the closed notch is idle (nothing playing, nothing else showing) an up-arrow-in-a-circle sits where the
///    visualizer sits when music plays, with nothing where the album cover would be. It stays until Indra is updated.
enum UpdateNoticeLog {
    private static let versionKey = "updateNoticeVersion"
    private static let dayKey = "updateNoticeDay"
    private static let countKey = "updateNoticeCount"
    private static let lastKey = "updateNoticeLastAt"

    /// Cards allowed per day for one version.
    private static let perDay = 2
    /// The second card of a day comes at least this long after the first.
    private static let gap: TimeInterval = 4 * 3600

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// True when the card for this version may show now.
    static func isDue(version: Int, now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        // A version that has not had a card yet always gets one, and a new day starts again.
        guard defaults.integer(forKey: versionKey) == version, defaults.string(forKey: dayKey) == day(now) else { return true }
        guard defaults.integer(forKey: countKey) < perDay else { return false }
        let last = defaults.object(forKey: lastKey) as? Date ?? .distantPast
        return now.timeIntervalSince(last) >= gap
    }

    /// Call at the moment the card is shown.
    static func record(version: Int, now: Date = Date()) {
        let defaults = UserDefaults.standard
        let sameDay = defaults.integer(forKey: versionKey) == version && defaults.string(forKey: dayKey) == day(now)
        defaults.set(version, forKey: versionKey)
        defaults.set(day(now), forKey: dayKey)
        defaults.set(sameDay ? defaults.integer(forKey: countKey) + 1 : 1, forKey: countKey)
        defaults.set(now, forKey: lastKey)
    }
}

/// The card under the closed notch: "Update available (version N)". Same place and motion as the song-change card.
struct UpdateAvailableDownline: View {
    let version: Int
    let notchHeight: CGFloat
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            Text("Update available (version \(version))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 36)   // clear of the card's rounded bottom corners
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 4)
                .offset(y: shown ? 0 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
    }
}

/// The update symbol of the idle closed notch: an arrow pointing up inside a circle.
struct UpdateBadgeGlyph: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "arrow.up.circle")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 22, height: 22)
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.7)
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { shown = true } }
    }
}
