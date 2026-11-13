import Foundation

enum Preferences {
    static let expandOnHoverKey = "expandOnHover"
    static let hoverDelayKey = "hoverDelay"
    static let blipEnabledKey = "blipEnabled"
    static let liveBatteryKey = "liveBattery"
    static let zenModeKey = "zenMode"
    /// The Zen page of Duo shows the file tray until the person picks Focus or Clipboard.
    /// v413: a click on the album cover in Duo always turns it into the spinning record (there is no setting any more;
    /// an old stored "Open app" choice is ignored).
    static let coverTapKey = "coverTap"
    static let defaultCoverTap = "vinyl"
    static var coverTap: String { defaultCoverTap }
    static let defaultZenMode = "tray"
    static var zenMode: String { UserDefaults.standard.string(forKey: zenModeKey) ?? defaultZenMode }
    static let focusMinutesKey = "focusMinutes"
    static let timerSoundKey = "timerSound"
    static let batteryLimitKey = "batteryLimit"
    static let liquidGlassKey = "liquidGlass"
    static let translucentNotchKey = "translucentNotch"
    static let glassDarknessKey = "glassDarkness"
    static let visualizerStyleKey = "visualizerStyle"
    static let sensoryStyleKey = "sensoryStyle"
    static let sensoryBrightnessKey = "sensoryBrightness"
    static let sensoryVolumeKey = "sensoryVolume"
    static let sensoryKeyboardKey = "sensoryKeyboard"
    static let lyricsDisplayKey = "lyricsDisplay"
    /// The lock screen shows only the current line until the person picks the whole lyrics.
    static let defaultLyricsDisplay = "line"
    static let lockMotionArtKey = "lockMotionArt"
    static let lockCursorJumpKey = "lockCursorJump"
    static let lyricsLatinKey = "lyricsLatin"
    static let lockBlurVideoKey = "lockBlurVideo"
    /// v565: the video of an animated cover is sharp (the setting "Blur the video" is off) until someone turns it on.
    static let lockBlurVideoDefault = false
    static let remindersEnabledKey = "remindersEnabled"
    static let sensoryMatchSongKey = "sensoryMatchSong"
    /// v456: what colour the volume / brightness HUD takes: "album" (the song's colours, the default), "system" (the
    /// Mac's accent colour) or "none" (plain white). It replaces the old "Match song color" switch.
    static let sensoryColorModeKey = "sensoryColorMode"
    static let sensoryLabelKey = "sensoryLabel"
    static let sensoryLayoutKey = "sensoryLayout"
    /// With the downline position: "downline" (the card drops in row by row) or "inline" (the slim icon and bar of the
    /// inline layout, with its motion, hanging below the notch).
    static let sensoryDownlineMotionKey = "sensoryDownlineMotion"
    static let sensoryDurationKey = "sensoryDuration"
    /// v429: the inline volume / brightness bar can show the level as a number (off by default), with its own size and place.
    static let sensoryPercentKey = "sensoryPercent"
    /// v496: the final size of the inline volume / brightness bar, chosen with the (now removed) v491 sliders: 18 pt longer
    /// than designed, 6 pt thick.
    static let inlineBarLengthExtra: CGFloat = 18
    static let inlineBarHeight: CGFloat = 6
    static let sensoryPercentSizeKey = "sensoryPercentSize"
    /// "icon" (beside the icon), "above" (above the bar) or "bar" (left of the bar).
    static let sensoryPercentPlaceKey = "sensoryPercentPlace"
    static let sensoryPercentNudgeXKey = "sensoryPercentNudgeX"
    static let sensoryPercentNudgeYKey = "sensoryPercentNudgeY"
    static let sensoryPositionKey = "sensoryPosition"
    static let appleHUDWidthKey = "appleHUDWidth"
    static let appleHUDHeightKey = "appleHUDHeight"
    static let downlineHUDWidthKey = "downlineHUDWidth"
    static let defaultDownlineHUDWidth: Double = 252
    static let defaultAppleHUDWidth: Double = 78
    static let defaultAppleHUDHeight: Double = 246
    static let notchWidthKey = "notchWidth"
    static let notchHeightKey = "notchHeight"
    static let defaultNotchWidth: Double = 390
    static let defaultNotchHeight: Double = 175
    static let accentVisualizerKey = "accentVisualizer"
    static let accentSliderKey = "accentSlider"
    /// The expanded notch's white record takes a light shade of the album's colour (off by default).
    static let vinylAccentKey = "vinylAccent"
    /// The circular lines on the expanded notch's record take the slider's colour instead of black (off by default).
    static let vinylLinesKey = "vinylLines"
    // v541: the "Notch curve follows the vinyl" option is gone: with the record open the corners always follow the disc.
    static let weatherEnabledKey = "weatherEnabled"
    static let weatherCityKey = "weatherCity"
    static let weatherLatitudeKey = "weatherLatitude"
    static let weatherLongitudeKey = "weatherLongitude"
    static let weatherLocatedCityKey = "weatherLocatedCity"
    static let todoEnabledKey = "todoEnabled"
    static let hideInFullscreenKey = "hideInFullscreen"
    static let stickyDesktopsKey = "stickyDesktops"
    static let hideFromCaptureKey = "hideFromCapture"
    /// v394: the notch lives on the external monitor only, drawn as a floating island (off by default).
    static let externalMonitorKey = "externalMonitorIsland"
    static let menuBarIconKey = "menuBarIcon"
    static let liveLockKey = "liveLock"
    static let lockPlayerKey = "lockPlayer"
    static let spotifyClientIDKey = "spotifyClientID"
    static let lockClockStyleKey = "lockClockStyle"
    static let lockBackdropBlurKey = "lockBackdropBlur"
    static let lockBackdropDarknessKey = "lockBackdropDarkness"
    static let lockBackdropBlurDefault = 20.0
    static let lockBackdropDarknessDefault = 0.14
    /// Edge light for video calls (Mirror): the warm (orange) and cool (blue) lights, each switched on or off and set
    /// in intensity and width (0...1) with the knobs next to the camera box. See EdgeLightController.
    static let edgeWarmOnKey = "edgeWarmOn"
    static let edgeWarmIntensityKey = "edgeWarmIntensity"
    static let edgeWarmWidthKey = "edgeWarmWidth"
    static let edgeCoolOnKey = "edgeCoolOn"
    static let edgeCoolIntensityKey = "edgeCoolIntensity"
    static let edgeCoolWidthKey = "edgeCoolWidth"
    static let lyricsFontKey = "lyricsFont"
    static let lyricsFontDefault = "shandey"
    static let liveBluetoothKey = "liveBluetooth"
    static let bluetoothDisconnectKey = "bluetoothDisconnect"
    static let bluetoothEarbudStyleKey = "bluetoothEarbudStyle"
    static let bluetoothOtherDevicesKey = "bluetoothOtherDevices"
    static let bluetooth3DKey = "bluetooth3D"
    /// v540: set the first time General > Intro animation > Show is clicked; the row is gone after that.
    static let introButtonUsedKey = "indraIntroButtonUsed"
    static let trayFirstKey = "trayFirst"
    static let showDateKey = "showDate"
    static let showCalendarKey = "showCalendar"
    static let idleActivityKey = "idleActivity"
    static let autoIdentifyKey = "autoIdentify"
    static let systemNowPlayingKey = "systemNowPlaying"
    static let idleMostRecentKey = "idleMostRecent"
    static let songChangeCardKey = "songChangeCard"
    /// Haptic taps in the notch, the main window and the haptic lab (Settings > General > Haptic feedback). Default: on.
    /// v428: this switch no longer covers the lock screen, which has its own switch below.
    /// v543: full-strength taps go through the trackpad's private driver (MultitouchSupport). That driver is shared with the
    /// keyboard and the cursor, and the MacBook froze completely (cursor, keyboard, display, hard shutdown) while Indra was
    /// driving it. The switch is switched OFF by itself when the previous run ended abruptly (see `IndraLog`), and when
    /// it is off the app only uses the system's own haptic patterns.
    static let strongHapticsKey = "strongHapticsEnabled"
    static var strongHaptics: Bool {
        UserDefaults.standard.object(forKey: strongHapticsKey) as? Bool ?? true
    }

    static let hapticsEnabledKey = "hapticsEnabled"
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsEnabledKey) as? Bool ?? true
    }
    /// v428: haptic taps on the lock screen only (Settings > Lock Screen). Independent of the switch above. Default: on.
    /// v517: a sound when the Mac locks and when it unlocks (Settings > Lock Screen > Sounds). Both off by default. v524: one fixed iPhone-style sound each, no picker.
    static let lockSoundOnKey = "lockSoundOn"
    static let unlockSoundOnKey = "unlockSoundOn"
    static let lockHapticsEnabledKey = "lockHapticsEnabled"
    static var lockHapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: lockHapticsEnabledKey) as? Bool ?? true
    }

    /// Default: true (matches @AppStorage default in SettingsView).
    static var expandOnHover: Bool {
        UserDefaults.standard.object(forKey: expandOnHoverKey) as? Bool ?? true
    }

    /// How long the pointer must rest on the closed notch before hovering opens it, in seconds (0 ... 1). Default: 0.1.
    static var hoverDelay: Double {
        let value = UserDefaults.standard.object(forKey: hoverDelayKey) as? Double ?? 0.1
        return min(max(value, 0), 1)
    }

    /// v413: the card under the closed notch with the title and artist whenever the song changes is always on (no
    /// setting any more; an old stored "off" is ignored).
    static var songChangeCard: Bool { true }

    static var liveBattery: Bool {
        UserDefaults.standard.object(forKey: liveBatteryKey) as? Bool ?? true
    }

    /// Charge level (80, 90 or 100) at which the charging animation pops up. Default: 100.
    static var batteryLimit: Int {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: batteryLimitKey) == nil ? 100 : Int(defaults.double(forKey: batteryLimitKey))
        return [80, 90, 100].min(by: { abs($0 - stored) < abs($1 - stored) }) ?? 100
    }

    static var liveLock: Bool {
        UserDefaults.standard.object(forKey: liveLockKey) as? Bool ?? true
    }

    /// Client ID of the user's own Spotify developer app (needed to read the Spotify queue).
    static var spotifyClientID: String {
        (UserDefaults.standard.string(forKey: spotifyClientIDKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Music player on the lock screen. Default: true.
    static var lockPlayer: Bool {
        UserDefaults.standard.object(forKey: lockPlayerKey) as? Bool ?? true
    }

    /// Show Bluetooth devices connecting in the notch. Default: true.
    static var liveBluetooth: Bool {
        UserDefaults.standard.object(forKey: liveBluetoothKey) as? Bool ?? true
    }

    /// Also show the red dot when they disconnect. Default: true.
    static var bluetoothDisconnect: Bool {
        UserDefaults.standard.object(forKey: bluetoothDisconnectKey) as? Bool ?? true
    }

    /// Phones, laptops, speakers, watches, keyboards and mice are always shown, not only earbuds and headphones.
    static var bluetoothOtherDevices: Bool { true }

    /// Draw devices as live 3D models (otherwise as the flat animations). Switched off by itself if the app ever
    /// stops while a 3D model is being drawn (see SceneGuard). Default: true.
    static var bluetooth3D: Bool {
        UserDefaults.standard.object(forKey: bluetooth3DKey) as? Bool ?? true
    }

    /// Open the Files Tray first when it holds files. Default: true.
    static var trayFirst: Bool {
        UserDefaults.standard.object(forKey: trayFirstKey) as? Bool ?? true
    }

    static var blipEnabled: Bool {
        UserDefaults.standard.object(forKey: blipEnabledKey) as? Bool ?? true
    }

    static var showDate: Bool {
        UserDefaults.standard.object(forKey: showDateKey) as? Bool ?? false
    }

    /// "none", "playing", "calendar" or "duo".
    static var idleActivity: String {
        UserDefaults.standard.string(forKey: idleActivityKey) ?? "duo"
    }

    static var idleMostRecent: Bool {
        UserDefaults.standard.object(forKey: idleMostRecentKey) as? Bool ?? false
    }

    /// Show whatever macOS reports as playing (Safari, YouTube, Chrome, VLC, any app). Default: on.
    static var systemNowPlaying: Bool {
        UserDefaults.standard.object(forKey: systemNowPlayingKey) as? Bool ?? true
    }

    /// Automatically identify background music while nothing plays in Music / Spotify. Default: on.
    static var autoIdentify: Bool {
        true
    }

    static var showCalendar: Bool {
        true   // v423: the month calendar is always on
    }

    static var hideInFullscreen: Bool {
        UserDefaults.standard.object(forKey: hideInFullscreenKey) as? Bool ?? false
    }

    static var hideFromCapture: Bool {
        UserDefaults.standard.object(forKey: hideFromCaptureKey) as? Bool ?? false
    }

    /// v394: show the notch only on the external monitor, as a floating island (needs an external monitor).
    static var externalMonitor: Bool {
        UserDefaults.standard.object(forKey: externalMonitorKey) as? Bool ?? false
    }

    static var menuBarIcon: Bool {
        UserDefaults.standard.object(forKey: menuBarIconKey) as? Bool ?? true
    }

    /// Keep the notch fixed while switching desktops. Default: on.
    static var stickyDesktops: Bool {
        true
    }

    /// v479: waveform is the default. Anyone who still has the vibrating circle stored from before is moved to the waveform
    /// once; the circle (and None) can still be chosen again in Settings and then stay.
    static func migrateVisualizerDefault() {
        let flag = "visualizerWaveformDefaultV479"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        if defaults.string(forKey: visualizerStyleKey) == "circle" { defaults.set("waveform", forKey: visualizerStyleKey) }
        if defaults.string(forKey: islandVisualizerStyleKey) == "circle" { defaults.removeObject(forKey: islandVisualizerStyleKey) }
    }

    /// "none", "waveform" or "circle".
    static var visualizerStyle: String {
        UserDefaults.standard.string(forKey: visualizerStyleKey) ?? "waveform"
    }

    static var weatherEnabled: Bool {
        UserDefaults.standard.object(forKey: weatherEnabledKey) as? Bool ?? true
    }

    static var weatherCity: String {
        UserDefaults.standard.string(forKey: weatherCityKey) ?? ""
    }

    /// Saved by "Use my location once"; only valid while the city field still shows that city.
    static func weatherSavedCoordinate(for city: String) -> (latitude: Double, longitude: Double)? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: weatherLocatedCityKey) == city,
              defaults.object(forKey: weatherLatitudeKey) != nil,
              defaults.object(forKey: weatherLongitudeKey) != nil else { return nil }
        return (defaults.double(forKey: weatherLatitudeKey), defaults.double(forKey: weatherLongitudeKey))
    }

    static func saveWeatherLocation(city: String, latitude: Double, longitude: Double) {
        let defaults = UserDefaults.standard
        defaults.set(latitude, forKey: weatherLatitudeKey)
        defaults.set(longitude, forKey: weatherLongitudeKey)
        defaults.set(city, forKey: weatherLocatedCityKey)
        defaults.set(city, forKey: weatherCityKey)
    }

    static var todoEnabled: Bool {
        UserDefaults.standard.object(forKey: todoEnabledKey) as? Bool ?? true
    }

    static var liquidGlass: Bool {
        UserDefaults.standard.object(forKey: liquidGlassKey) as? Bool ?? false
    }

    /// Width of the open notch in points (recommended: 390).
    static var notchWidth: Double { defaultNotchWidth }

    /// Height of the open notch in points (recommended: 175).
    static var notchHeight: Double { defaultNotchHeight }

    /// "notch" or "apple".
    static var sensoryStyle: String {
        "notch"
    }

    /// Notch-style overlay layout: "inline" (beside the notch) or "downline" (hangs below it).
    static var sensoryLayout: String {
        UserDefaults.standard.string(forKey: sensoryLayoutKey) == "inline" ? "inline" : "downline"
    }

    static var sensoryBrightness: Bool {
        UserDefaults.standard.object(forKey: sensoryBrightnessKey) as? Bool ?? true
    }

    /// "whole" (all lines, the current one bright) or "line" (only the line being sung).
    static var lyricsDisplay: String {
        (UserDefaults.standard.string(forKey: lyricsDisplayKey) ?? defaultLyricsDisplay) == "whole" ? "whole" : "line"
    }

    /// True when the downline HUD plays the inline layout's look and motion.
    static var sensoryDownlineInline: Bool {
        UserDefaults.standard.string(forKey: sensoryDownlineMotionKey) == "inline"
    }

    /// Animated album covers play behind the blurred lock screen when the vinyl is open.
    /// True: the animated cover is always blurred. False: it is sharp, and only blurred while the lyrics are open.
    static var lockBlurVideo: Bool {
        UserDefaults.standard.object(forKey: lockBlurVideoKey) as? Bool ?? Preferences.lockBlurVideoDefault
    }

    /// The sounds of the focus timer: the soft note when a session starts and the chime when it ends.
    static var timerSound: Bool {
        UserDefaults.standard.object(forKey: timerSoundKey) as? Bool ?? true
    }

    /// Lyrics in other scripts are shown in Latin letters (Hindi as Hinglish). Off by default.
    static var lyricsLatin: Bool {
        UserDefaults.standard.bool(forKey: lyricsLatinKey)
    }

    static var lockMotionArt: Bool {
        UserDefaults.standard.object(forKey: lockMotionArtKey) as? Bool ?? true
    }

    /// After a click on the cover or song name on the lock screen, the pointer jumps to the right edge. On by default.
    static var lockCursorJump: Bool {
        UserDefaults.standard.object(forKey: lockCursorJumpKey) as? Bool ?? true
    }

    static var sensoryKeyboard: Bool {
        UserDefaults.standard.object(forKey: sensoryKeyboardKey) as? Bool ?? true
    }

    /// True when the to-do page shows the Reminders app instead of Indra's own list.
    static var remindersEnabled: Bool {
        UserDefaults.standard.object(forKey: remindersEnabledKey) as? Bool ?? false
    }

    /// The to-do page (either list) can be reached by swiping.
    static var taskPageEnabled: Bool { todoEnabled || remindersEnabled }

    static var sensoryVolume: Bool {
        UserDefaults.standard.object(forKey: sensoryVolumeKey) as? Bool ?? true
    }

    /// The HUD colour mode for a stored value; nothing chosen yet falls back to the old "Match song color" switch
    /// (on = album, off = none), so nobody's setting changes.
    static func hudColorMode(_ raw: String) -> String {
        if raw == "album" || raw == "system" || raw == "none" { return raw }
        let legacy = UserDefaults.standard.object(forKey: sensoryMatchSongKey) as? Bool ?? true
        return legacy ? "album" : "none"
    }

    static var sensoryColorMode: String {
        hudColorMode(UserDefaults.standard.string(forKey: sensoryColorModeKey) ?? "")
    }

    static var sensoryMatchSong: Bool { sensoryColorMode == "album" }

    /// Seconds the overlay stays visible, 1 ... 6.
    static var sensoryDuration: Double {
        let value = UserDefaults.standard.object(forKey: sensoryDurationKey) as? Double ?? 3
        return min(max(value, 1), 6)
    }

    /// Vertical position of the Apple-style overlay as a fraction of the screen height from the top.
    static var sensoryPosition: Double {
        let value = UserDefaults.standard.object(forKey: sensoryPositionKey) as? Double ?? 0.45
        return min(max(value, 0.15), 0.85)
    }

    static var downlineHUDWidth: Double {
        let value = UserDefaults.standard.object(forKey: downlineHUDWidthKey) as? Double ?? defaultDownlineHUDWidth
        return min(max(value, 190), 340)
    }

    static var appleHUDWidth: Double {
        let value = UserDefaults.standard.object(forKey: appleHUDWidthKey) as? Double ?? defaultAppleHUDWidth
        return min(max(value, 24), 140)
    }

    static var appleHUDHeight: Double {
        let value = UserDefaults.standard.object(forKey: appleHUDHeightKey) as? Double ?? defaultAppleHUDHeight
        return min(max(value, 60), 360)
    }
}

extension Notification.Name {
    /// Posted by views that want the Indra app window (settings) opened.
    static let indraOpenSettings = Notification.Name("indraOpenSettings")
    /// Posted while the glass slider is dragged (object: Bool, true = dragging). Opens the notch
    /// (and the Apple-style HUD if that style is chosen) so the change can be seen live.
    static let indraGlassPreview = Notification.Name("indraGlassPreview")
    static let indraBluetoothPreview = Notification.Name("indraBluetoothPreview")
    /// v536: Battery > Charging animation > Preview: shows the battery card in the notch as if the charge limit was reached.
    /// Posted by General > Behavior > Intro animation > Show: plays the intro video in the notch again.
    static let indraWelcomePreview = Notification.Name("indraWelcomePreview")
    /// Posted when a focus session starts or resumes: the notch folds away, then the sound and the wave play.
    static let indraFocusStarted = Notification.Name("indraFocusStarted")
}
