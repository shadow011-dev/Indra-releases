import SwiftUI

// v433: the external monitor's island (the second notch) can have its own look. Every setting below is stored apart from
// the MacBook notch's; while one has never been set for the island (an empty or missing value) the island simply follows
// the notch, so nothing changes for anyone who does not open Settings > External Notch.

private struct NotchIslandKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the island's window (the notch on an external monitor).
    var notchIsland: Bool {
        get { self[NotchIslandKey.self] }
        set { self[NotchIslandKey.self] = newValue }
    }
}

extension Preferences {
    /// v438: "island" (the floating pill, the default) or "notch" (drawn exactly like the MacBook's physical notch).
    static let islandLookKey = "islandLook"
    static let islandIdleActivityKey = "islandIdleActivity"
    /// "on" / "off" / "" (follow the notch).
    static let islandIdleMostRecentKey = "islandIdleMostRecent"
    static let islandZenModeKey = "islandZenMode"
    static let islandVisualizerStyleKey = "islandVisualizerStyle"
    static let islandSensoryLayoutKey = "islandSensoryLayout"
    static let islandSensoryDownlineMotionKey = "islandSensoryDownlineMotion"
    /// "todo" / "reminders" / "" (follow the notch): which list the island's to-do page shows.
    static let islandTaskPageKey = "islandTaskPage"

    static let islandKeys = [islandLookKey, islandIdleActivityKey, islandIdleMostRecentKey, islandZenModeKey, islandVisualizerStyleKey,
                             islandSensoryLayoutKey, islandSensoryDownlineMotionKey, islandTaskPageKey]

    private static func islandString(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    /// True when the external monitor's notch is drawn exactly like the MacBook's own notch (flush with the top edge,
    /// the same size, the same shape) instead of as a floating island.
    static var islandNotchLook: Bool {
        UserDefaults.standard.string(forKey: islandLookKey) == "notch"
    }

    static func idleActivity(island: Bool) -> String {
        if island, let value = islandString(islandIdleActivityKey) { return value }
        return idleActivity
    }

    static func idleMostRecent(island: Bool) -> Bool {
        if island, let value = islandString(islandIdleMostRecentKey) { return value == "on" }
        return idleMostRecent
    }

    static func zenMode(island: Bool) -> String {
        if island, let value = islandString(islandZenModeKey) { return value }
        return zenMode
    }

    static func visualizerStyle(island: Bool) -> String {
        if island, let value = islandString(islandVisualizerStyleKey) { return value }
        return visualizerStyle
    }

    static func sensoryLayout(island: Bool) -> String {
        if island, let value = islandString(islandSensoryLayoutKey) { return value == "inline" ? "inline" : "downline" }
        return sensoryLayout
    }

    static func remindersEnabled(island: Bool) -> Bool {
        if island, let value = islandString(islandTaskPageKey) { return value == "reminders" }
        return remindersEnabled
    }

    /// Picks the island's own value when `island` is true and one is stored, else the notch's.
    static func pick(_ main: String, _ own: String, island: Bool) -> String {
        island && !own.isEmpty ? own : main
    }
}
