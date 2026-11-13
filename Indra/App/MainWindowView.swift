import ServiceManagement
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case general
    case media
    case external
    case calendar
    case weather
    case todo
    case tray
    case sensory
    case battery
    case bluetooth
    case lockScreen
    case faceLock
    case tips
    case about
    case hapticLab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .media: return "Media"
        case .external: return "External Notch"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .todo: return Preferences.remindersEnabled ? "Reminders" : "To Do"
        case .tray: return "Files Tray"
        case .sensory: return "Volume & Brightness"
        case .battery: return "Battery"
        case .bluetooth: return "Bluetooth"
        case .lockScreen: return "Lock Screen"
        case .faceLock: return "Face Lock"
        case .tips: return "Tips"
        case .about: return "About"
        case .hapticLab: return "Haptic Lab"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .media: return "play.rectangle.fill"
        case .external: return "display"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .todo: return "checklist"
        case .tray: return "tray.fill"
        case .sensory: return "sun.max.fill"
        case .battery: return "battery.75percent"
        case .bluetooth: return "airpods"
        case .lockScreen: return "lock.fill"
        case .faceLock: return "faceid"
        case .tips: return "lightbulb.fill"
        case .about: return "info.circle.fill"
        case .hapticLab: return "hand.tap.fill"
        }
    }

    /// The colour of the matching Apple icon: Calendar red, Weather blue, Files blue, Sound pink, Battery green,
    /// Bluetooth blue, Lock Screen black, Tips yellow, General (About) grey. Pages with their own colour (General, Media) use `tint`.
    var appleColor: Color {
        switch self {
        case .external: return Color(red: 0.31, green: 0.31, blue: 0.34)    // External Notch: dark graphite
        case .calendar: return Color(red: 1.00, green: 0.23, blue: 0.19)    // Calendar: system red
        case .weather: return Color(red: 0.20, green: 0.56, blue: 0.97)     // Weather: sky blue
        case .todo: return Color(red: 1.00, green: 0.58, blue: 0.00)        // (Reminders is drawn white)
        case .tray: return Color(red: 0.12, green: 0.56, blue: 0.98)        // Files: blue
        case .sensory: return Color(red: 1.00, green: 0.18, blue: 0.33)     // Sound: pink-red
        case .battery: return Color(red: 0.20, green: 0.78, blue: 0.35)     // Battery: green
        case .bluetooth: return Color(red: 0.04, green: 0.48, blue: 1.00)   // Bluetooth: blue
        case .lockScreen: return Color(red: 0.11, green: 0.11, blue: 0.12)  // Lock Screen: black
        case .faceLock: return Color(red: 0.19, green: 0.76, blue: 0.45)    // Face Lock: Face ID green
        case .tips: return Color(red: 1.00, green: 0.80, blue: 0.04)        // Tips: yellow
        case .about: return Color(red: 0.56, green: 0.56, blue: 0.58)       // General: grey
        default: return tint
        }
    }

    /// The colour of the page's icon tile; it also tints the soft light in the window's top right corner.
    var tint: Color {
        switch self {
        case .general: return Color(red: 0.58, green: 0.58, blue: 0.61)
        case .media: return Color(red: 0.92, green: 0.27, blue: 0.36)
        case .todo:
            return Preferences.remindersEnabled ? Color(red: 0.20, green: 0.52, blue: 0.98) : appleColor
        case .hapticLab: return Color(red: 0.98, green: 0.58, blue: 0.20)
        // The lock screen glow stays a visible grey-violet: a black glow would not show on the dark window.
        case .lockScreen: return Color(red: 0.42, green: 0.42, blue: 0.56)
        default: return appleColor
        }
    }
}

struct MainWindowView: View {
    @State private var page: AppPage = .general
    @Namespace private var sidebarNS
    @AppStorage(Preferences.remindersEnabledKey) private var remindersOn = false
    @AppStorage(Preferences.externalMonitorKey) private var externalMonitor = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
            Rectangle()
                .fill(LinearGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
            content
        }
        .frame(minWidth: 860, minHeight: 670)
        .onReceive(NotificationCenter.default.publisher(for: .indraMainWindowClosed)) { _ in
            // v478: the next opening starts on General.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { page = .general }
        }
        .background {
            ZStack {
                VisualEffectBackground()
                // Ambient light in the colour of the current page; it cross-fades when the page changes.
                ZStack {
                    RadialGradient(colors: [page.tint.opacity(0.20), page.tint.opacity(0)],
                                   center: .topTrailing, startRadius: 0, endRadius: 560)
                        .id("\(page.rawValue)-\(remindersOn)")
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.7), value: page)
                .animation(.easeInOut(duration: 0.7), value: remindersOn)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38)
            brand
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 3) {
                sidebarRow(.general, 1)
                sidebarRow(.media, 2)
                // v433: the external monitor's own settings, only while "External monitor" is on.
                if externalMonitor {
                    sidebarRow(.external, 3)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                sectionLabel("Widgets")
                sidebarRow(.calendar, 3)
                sidebarRow(.weather, 4)
                sidebarRow(.todo, 5)
                sidebarRow(.tray, 6)
                sectionLabel("Overlays")
                sidebarRow(.sensory, 7)
                sidebarRow(.battery, 8)
                sidebarRow(.bluetooth, 9)
                sidebarRow(.lockScreen, 10)
                sidebarRow(.faceLock, 11)
                sectionLabel("Help")
                sidebarRow(.tips, 12)
                sidebarRow(.about, 13)
            }
            .animation(.smooth(duration: 0.3), value: externalMonitor)
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .background {
            LinearGradient(colors: [Color.primary.opacity(0.055), Color.primary.opacity(0.025)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// The name above the list, with a small glowing mark.
    private var brand: some View {
        HStack(spacing: 9) {
            Text(AppBrand.name)
                .font(.system(size: 17, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .staggered(0, base: 0.02, step: 0.03)
    }

    /// The build number, and the access pill: clicking it opens the Status window with every indicator.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button {
                StatusWindowController.shared.show()
            } label: {
                StatusPill(ok: !SensoryDiagnostics.isSandboxed,
                           text: SensoryDiagnostics.isSandboxed ? "Standard" : "Full access")
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.95))
        }
        .padding(.horizontal, 10)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 16)
            .padding(.leading, 10)
            .padding(.bottom, 4)
    }

    private func sidebarRow(_ item: AppPage, _ index: Int) -> some View {
        SidebarRow(item: item, selected: page == item, namespace: sidebarNS) {
            guard page != item else { return }
            withAnimation(.smooth(duration: 0.4)) { page = item }
        }
        .staggered(index, base: 0.04, step: 0.03)
    }

    // MARK: - Content

    private var content: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch page {
                case .general: GeneralPage()
                case .media: MediaPage()
                case .external: ExternalNotchPage()
                case .calendar: CalendarPage()
                case .weather: WeatherPage()
                case .todo: TodoPage()
                case .tray: TrayPage()
                case .sensory: SensoryPage()
                case .battery: BatteryPage()
                case .bluetooth: BluetoothPage()
                case .lockScreen: LockScreenPage()
                case .faceLock: FaceLockPage()
                case .tips: TipsPage()
                case .about: AboutPage()
                case .hapticLab: HapticLabPage()
                }
            }
            .id(page)
            .transition(.pageReveal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.smooth(duration: 0.45), value: page)
        .onChange(of: page) { _, new in IndraLog.crumb("Opened \(new.title) in settings") }
        .onChange(of: externalMonitor) { _, on in
            if !on, page == .external { withAnimation(.smooth(duration: 0.4)) { page = .general } }
        }
    }
}

// MARK: - Pages

private struct GeneralPage: View {
    @AppStorage(Preferences.hideInFullscreenKey) private var hideInFullscreen = false
    @AppStorage(Preferences.hideFromCaptureKey) private var hideFromCapture = false
    @AppStorage(Preferences.externalMonitorKey) private var externalMonitor = false
    @AppStorage(Preferences.liquidGlassKey) private var liquidGlass = false
    @AppStorage(Preferences.translucentNotchKey) private var translucentNotch = true
    @AppStorage(Preferences.glassDarknessKey) private var glassDarkness = 0.55
    @AppStorage(Preferences.expandOnHoverKey) private var expandOnHover = true
    @AppStorage(Preferences.hoverDelayKey) private var hoverDelay = 0.1
    @AppStorage(Preferences.hapticsEnabledKey) private var hapticsEnabled = true
    @AppStorage(Preferences.strongHapticsKey) private var strongHaptics = true
    @AppStorage(Preferences.introButtonUsedKey) private var introButtonUsed = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = newValue
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        )
    }

    /// v426: turning haptics on gives one tap as the proof that it works; turning them off gives none.
    private var hapticsBinding: Binding<Bool> {
        Binding(
            get: { hapticsEnabled },
            set: { newValue in
                hapticsEnabled = newValue
                IndraLog.crumb("Haptic feedback turned \(newValue ? "on" : "off")")
                if newValue {
                    UserDefaults.standard.set(true, forKey: Preferences.hapticsEnabledKey)
                    Haptics.tap(.action, lockout: 0)
                }
            }
        )
    }

    /// Clear glass and translucent are alternatives: turning one on turns the other off.
    private var glassBinding: Binding<Bool> {
        Binding(
            get: { liquidGlass },
            set: { newValue in
                liquidGlass = newValue
                if newValue { translucentNotch = false }
            }
        )
    }

    private var translucentBinding: Binding<Bool> {
        Binding(
            get: { translucentNotch },
            set: { newValue in
                translucentNotch = newValue
                if newValue { liquidGlass = false }
            }
        )
    }

    /// How long the pointer must rest on the notch before it opens: the value in a pill on the right and a
    /// full-width slider under it (its own ticks, one per tenth of a second, from 0 to 1 second).
    private var hoverDurationRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hover duration")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 12)
                Text(String(format: "%.1f s", hoverDelay))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: hoverDelay)
            }
            // The slider draws its own tick marks (step 0.1): the extra row of dots that used to sit under it is gone.
            Slider(value: $hoverDelay, in: 0...1, step: 0.1)
                .tint(Theme.accent)
                .onChange(of: hoverDelay) { _, _ in Haptics.hf3(lockout: 0.03) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    var body: some View {
        SettingsPage(.general) {
            SettingsCard("Behavior") {
                ToggleRow(symbol: "power", tint: Theme.green,
                          title: "Launch at login",
                          isOn: launchBinding)
                RowDivider()
                ToggleRow(symbol: "cursorarrow.rays", tint: Theme.blue,
                          title: "Expand notch on hover",
                          isOn: $expandOnHover)
                RowDivider()
                hoverDurationRow
                    .disabled(!expandOnHover)
                RowDivider()
                ToggleRow(symbol: "hand.tap.fill", tint: Theme.orange,
                          title: "Haptic feedback",
                          subtitle: "Trackpad taps in the notch and this window (the lock screen has its own switch)",
                          isOn: hapticsBinding)
                RowDivider()
                ToggleRow(symbol: "waveform.path", tint: Theme.orange,
                          title: "Full-strength haptics",
                          isOn: $strongHaptics)
                    .disabled(!hapticsEnabled)
                // v540: the Show button is offered until it has been clicked once; after that the row is gone for good.
                if !introButtonUsed {
                    RowDivider()
                    SettingRow(symbol: "play.circle.fill", tint: Theme.violet,
                               title: "Intro animation") {
                        ActionButton(title: "Show", symbol: "play.fill") {
                            introButtonUsed = true
                            NotificationCenter.default.post(name: .indraWelcomePreview, object: nil)
                        }
                    }
                }
            }
            SettingsCard("Appearance") {
                glassRow
                RowDivider()
                ToggleRow(symbol: "circle.lefthalf.filled", tint: Theme.gray,
                          title: "Translucent background",
                          isOn: translucentBinding)
                RowDivider()
                SettingRow(symbol: "slider.horizontal.3", tint: Theme.gray,
                           title: "Background darkness") {
                    HStack(spacing: 8) {
                        Text("Clear")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Slider(value: $glassDarkness, in: 0...1) { editing in
                            NotificationCenter.default.post(name: .indraGlassPreview, object: editing)
                        }
                        .tint(Theme.accent)
                        .frame(width: 170)
                        .onChange(of: Int((glassDarkness * 20).rounded())) { _, _ in Haptics.hf3(lockout: 0.03) }
                        Text("Dark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .disabled(!liquidGlass && !translucentNotch)
            }
            SettingsCard("Visibility") {
                ToggleRow(symbol: "display", tint: Theme.blue,
                          title: "External monitor",
                          isOn: $externalMonitor)
                RowDivider()
                ToggleRow(symbol: "arrow.up.left.and.arrow.down.right", tint: Theme.gray,
                          title: "Hide in full-screen apps", isOn: $hideInFullscreen)
                RowDivider()
                ToggleRow(symbol: "eye.slash.fill", tint: Theme.indigo,
                          title: "Hide from screen capture",
                          isOn: $hideFromCapture)
            }
        }
    }

    @ViewBuilder
    private var glassRow: some View {
        if #available(macOS 26.0, *) {
            ToggleRow(symbol: "sparkles", tint: Theme.violet,
                      title: "Liquid glass background",
                      isOn: glassBinding)
        } else {
            SettingRow(symbol: "sparkles", tint: Theme.violet,
                       title: "Liquid glass background") {
                Text("macOS 26")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct MediaPage: View {
    @AppStorage(Preferences.idleActivityKey) private var idleActivity = "duo"
    @AppStorage(Preferences.idleMostRecentKey) private var idleMostRecent = false
    @AppStorage(Preferences.zenModeKey) private var zenMode = Preferences.defaultZenMode
    @AppStorage(Preferences.visualizerStyleKey) private var visualizer = "waveform"
    @AppStorage(Preferences.systemNowPlayingKey) private var systemNowPlaying = true
    @AppStorage(Preferences.accentSliderKey) private var accentSlider = true
    @AppStorage(Preferences.vinylAccentKey) private var vinylAccent = false
    @AppStorage(Preferences.vinylLinesKey) private var vinylLines = false

    // The record's two colour options exclude each other: the whole disc in a shade of the album, or its lines in the slider's colour.
    private var vinylAccentBinding: Binding<Bool> {
        Binding(get: { vinylAccent }, set: { on in
            vinylAccent = on
            if on { vinylLines = false }
        })
    }
    private var vinylLinesBinding: Binding<Bool> {
        Binding(get: { vinylLines }, set: { on in
            vinylLines = on
            if on { vinylAccent = false }
        })
    }

    var body: some View {
        SettingsPage(.media) {
            SettingsCard("Any app") {
                ToggleRow(symbol: "play.rectangle.on.rectangle.fill", tint: Theme.pink,
                          title: "Show media from any app",
                          isOn: $systemNowPlaying)
            }
            SettingsCard("Visualizer") {
                SettingRow(symbol: "waveform", tint: Theme.pink,
                           title: "Style") {
                    SegmentedChoice([("waveform", "Waveform"), ("circle", "Circle"), ("none", "None")],
                                    selection: $visualizer)
                        .frame(width: 270)
                }
                RowDivider()
                ToggleRow(symbol: "slider.horizontal.3", tint: Theme.pink,
                          title: "Slider matches the album",
                          isOn: $accentSlider)
                // The record only exists in Duo, so its options appear only while Duo is the idle page.
                if idleActivity == "duo" {
                    RowDivider()
                    ToggleRow(symbol: "opticaldisc", tint: Theme.pink,
                              title: "Vinyl matches the album",
                              isOn: vinylAccentBinding)
                    RowDivider()
                    ToggleRow(symbol: "circle.dashed", tint: Theme.pink,
                              title: "Vinyl lines match the slider",
                              isOn: vinylLinesBinding)
                }
            }
            .animation(.smooth(duration: 0.3), value: idleActivity)
            SettingsCard("When idle") {
                ToggleRow(symbol: "clock.arrow.circlepath", tint: Theme.indigo,
                          title: "Follow last activity",
                          isOn: $idleMostRecent)
                RowDivider()
                HStack(spacing: 10) {
                    idleTile("none", "Nothing", symbol: "nosign")
                    idleTile("playing", "Player", symbol: "play.fill")
                    idleTile("calendar", "Calendar", symbol: "calendar")
                    idleTile("duo", "Both", symbol: "rectangle.on.rectangle")
                }
                .padding(14)
                .disabled(idleMostRecent)
                .opacity(idleMostRecent ? 0.4 : 1)
            }
            // Duo only: the page one swipe down from player + calendar (it can also be switched in the notch itself).
            if idleActivity == "duo" {
                SettingsCard("Zen space") {
                    SettingRow(symbol: zenMode == "clipboard" ? "doc.on.clipboard.fill" : (zenMode == "tray" ? "tray.fill" : "timer"),
                               tint: Theme.indigo,
                               title: "Page") {
                        SegmentedChoice([("tray", "File tray"), ("focus", "Focus"), ("clipboard", "Clipboard")], selection: $zenMode)
                            .frame(width: 290)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.3), value: idleActivity)
        .onChange(of: systemNowPlaying) { _, on in
            SystemNowPlaying.shared.setEnabled(on)
        }
    }

    private func idleTile(_ value: String, _ title: String, symbol: String) -> some View {
        let selected = idleActivity == value
        return ChoiceTile(selected: selected, action: {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) { idleActivity = value }
        }) {
            TileLabel(symbol: symbol, title: title, selected: selected)
        }
    }
}

// MARK: - External Notch

/// v433: the notch on the external monitor (the island) with its own look. Until a choice is made here it follows the
/// MacBook notch; "Same as the notch" clears every choice again.
private struct ExternalNotchPage: View {
    @AppStorage(Preferences.idleActivityKey) private var mainIdle = "duo"
    @AppStorage(Preferences.idleMostRecentKey) private var mainRecent = false
    @AppStorage(Preferences.zenModeKey) private var mainZen = Preferences.defaultZenMode
    @AppStorage(Preferences.visualizerStyleKey) private var mainVisualizer = "waveform"
    @AppStorage(Preferences.sensoryLayoutKey) private var mainLayout = "downline"
    @AppStorage(Preferences.sensoryDownlineMotionKey) private var mainMotion = "downline"
    @AppStorage(Preferences.remindersEnabledKey) private var mainReminders = false
    @AppStorage(Preferences.todoEnabledKey) private var mainTodo = true

    @AppStorage(Preferences.islandLookKey) private var look = ""
    @AppStorage(Preferences.islandIdleActivityKey) private var idle = ""
    @AppStorage(Preferences.islandIdleMostRecentKey) private var recent = ""
    @AppStorage(Preferences.islandZenModeKey) private var zen = ""
    @AppStorage(Preferences.islandVisualizerStyleKey) private var visualizer = ""
    @AppStorage(Preferences.islandSensoryLayoutKey) private var layout = ""
    @AppStorage(Preferences.islandSensoryDownlineMotionKey) private var motion = ""
    @AppStorage(Preferences.islandTaskPageKey) private var taskPage = ""

    private var idleValue: String { idle.isEmpty ? mainIdle : idle }
    private var layoutValue: String { (layout.isEmpty ? mainLayout : layout) == "inline" ? "inline" : "downline" }
    private var taskValue: String { taskPage.isEmpty ? (mainReminders ? "reminders" : "todo") : taskPage }

    private func choice(_ own: Binding<String>, _ main: String) -> Binding<String> {
        Binding(get: { own.wrappedValue.isEmpty ? main : own.wrappedValue },
                set: { own.wrappedValue = $0 })
    }

    private var recentBinding: Binding<Bool> {
        Binding(get: { recent.isEmpty ? mainRecent : recent == "on" },
                set: { recent = $0 ? "on" : "off" })
    }

    private var taskBinding: Binding<String> {
        Binding(get: { taskValue },
                set: { value in
                    taskPage = value
                    if value == "reminders" { RemindersStore.shared.activate() }
                })
    }

    private var followsRecent: Bool { recent.isEmpty ? mainRecent : recent == "on" }

    private func idleTile(_ value: String, _ title: String, symbol: String) -> some View {
        let selected = idleValue == value
        return ChoiceTile(selected: selected, action: {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) { idle = value }
        }) {
            TileLabel(symbol: symbol, title: title, selected: selected)
        }
    }

    var body: some View {
        SettingsPage(.external) {
            SettingsCard("Style") {
                SettingRow(symbol: "macbook", tint: Theme.blue,
                           title: "Look") {
                    SegmentedChoice([("island", "Island"), ("notch", "Same as MacBook notch")],
                                    selection: Binding(get: { look == "notch" ? "notch" : "island" },
                                                       set: { look = $0 }))
                        .frame(width: 330)
                }
            }
            SettingsCard("Notch") {
                ToggleRow(symbol: "clock.arrow.circlepath", tint: Theme.indigo,
                          title: "Follow last activity",
                          isOn: recentBinding)
                RowDivider()
                HStack(spacing: 10) {
                    idleTile("none", "Nothing", symbol: "nosign")
                    idleTile("playing", "Player", symbol: "play.fill")
                    idleTile("calendar", "Calendar", symbol: "calendar")
                    idleTile("duo", "Both", symbol: "rectangle.on.rectangle")
                }
                .padding(14)
                .disabled(followsRecent)
                .opacity(followsRecent ? 0.4 : 1)
            }
            if idleValue == "duo" {
                SettingsCard("Zen space") {
                    SettingRow(symbol: "timer", tint: Theme.indigo,
                               title: "Page") {
                        SegmentedChoice([("tray", "File tray"), ("focus", "Focus"), ("clipboard", "Clipboard")],
                                        selection: choice($zen, mainZen))
                            .frame(width: 290)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            SettingsCard("Visualizer") {
                SettingRow(symbol: "waveform", tint: Theme.pink,
                           title: "Style") {
                    SegmentedChoice([("waveform", "Waveform"), ("circle", "Circle"), ("none", "None")],
                                    selection: choice($visualizer, mainVisualizer))
                        .frame(width: 270)
                }
            }
            SettingsCard("Volume & Brightness") {
                SettingRow(symbol: "rectangle.split.2x1.fill", tint: Theme.teal,
                           title: "Bar position") {
                    SegmentedChoice([("downline", "Downline"), ("inline", "Inline")],
                                    selection: choice($layout, mainLayout == "inline" ? "inline" : "downline"))
                        .frame(width: 210)
                }
                if layoutValue == "downline" {
                    RowDivider()
                    SettingRow(symbol: "sparkles", tint: Theme.violet,
                               title: "Animation") {
                        SegmentedChoice([("downline", "Cascade"), ("inline", "Calm")],
                                        selection: choice($motion, mainMotion))
                            .frame(width: 210)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: layoutValue)
            SettingsCard("To-do page") {
                SettingRow(symbol: "checklist", tint: Theme.orange,
                           title: "List") {
                    SegmentedChoice([("todo", "To Do"), ("reminders", "Reminders")],
                                    selection: taskBinding)
                        .frame(width: 210)
                }
                .disabled(!mainTodo && !mainReminders)
                .opacity(!mainTodo && !mainReminders ? 0.45 : 1)
            }
            SettingsCard {
                SettingRow(symbol: "arrow.uturn.backward.circle.fill", tint: Theme.gray,
                           title: "Same as the notch") {
                    ActionButton(title: "Reset", symbol: "arrow.counterclockwise") {
                        withAnimation(.smooth(duration: 0.3)) {
                            for key in Preferences.islandKeys { UserDefaults.standard.removeObject(forKey: key) }
                        }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: idleValue)
    }
}

private struct CalendarPage: View {
    @AppStorage(Preferences.showDateKey) private var showDate = false
    @AppStorage(Preferences.idleActivityKey) private var idleActivity = "duo"

    private var duo: Bool { idleActivity == "duo" }

    var body: some View {
        SettingsPage(.calendar) {
            SettingsCard {
                // The date page belongs to the single calendar page, so it can only be changed outside Duo.
                ToggleRow(symbol: "calendar.badge.clock", tint: Theme.red,
                          title: "Date and events",
                          isOn: $showDate)
                    .disabled(duo)
                    .opacity(duo ? 0.4 : 1)
            }
            .animation(.smooth(duration: 0.3), value: duo)
        }
    }
}

private struct WeatherPage: View {
    @AppStorage(Preferences.weatherEnabledKey) private var weatherEnabled = true
    @AppStorage(Preferences.weatherCityKey) private var city = ""
    @ObservedObject private var locator = WeatherLocator.shared

    private var locationNote: String? {
        switch locator.state {
        case .idle, .working: return nil
        case .done(let found): return "Found \(found). Saved; Indra will not look again."
        case .failed(let reason): return reason
        }
    }

    var body: some View {
        SettingsPage(.weather) {
            SettingsCard {
                ToggleRow(symbol: "cloud.sun.fill", tint: Theme.cyan,
                          title: "Show weather",
                          isOn: $weatherEnabled)
                RowDivider()
                SettingRow(symbol: "mappin.and.ellipse", tint: Theme.red,
                           title: "City") {
                    TextField("", text: $city, prompt: Text("For example: Hyderabad"))
                        .fieldStyle()
                        .frame(width: 250)
                }
                .disabled(!weatherEnabled)
                RowDivider()
                SettingRow(symbol: "location.fill", tint: Theme.blue,
                           title: "Location",
                           subtitle: locationNote) {
                    ActionButton(title: locator.isWorking ? "Locating…" : "Use my location once",
                                 symbol: "location") {
                        locator.locate()
                    }
                    .disabled(locator.isWorking || !weatherEnabled)
                }
            }
        }
    }
}

private struct TodoPage: View {
    @AppStorage(Preferences.todoEnabledKey) private var todoEnabled = true
    @AppStorage(Preferences.remindersEnabledKey) private var remindersEnabled = false
    @ObservedObject private var store = TodoStore.shared
    @ObservedObject private var reminders = RemindersStore.shared

    /// To-do and Reminders switch each other off: turning one on turns the other off.
    private var todoBinding: Binding<Bool> {
        Binding(get: { todoEnabled },
                set: { on in
                    todoEnabled = on
                    if on { remindersEnabled = false }
                })
    }

    private var remindersBinding: Binding<Bool> {
        Binding(get: { remindersEnabled },
                set: { on in
                    remindersEnabled = on
                    if on {
                        todoEnabled = false
                        reminders.activate()
                    }
                })
    }

    var body: some View {
        SettingsPage(.todo) {
            SettingsCard {
                ToggleRow(symbol: "checklist", tint: Theme.orange,
                          title: "To-do list", isOn: todoBinding)
                RowDivider()
                ToggleRow(symbol: "bell.badge.fill", tint: Theme.yellow,
                          title: "Reminders", isOn: remindersBinding)
            }
            if todoEnabled {
                SettingsCard {
                    SettingRow(symbol: "list.bullet.rectangle", tint: Theme.orange,
                               title: "\(store.openItems.count) open to-dos") {
                        ActionButton(title: "Clear all", symbol: "trash", kind: .destructive) {
                            store.removeAll()
                        }
                        .disabled(store.items.isEmpty)
                    }
                }
                TodoPopupCard()
                TaskAlarmCard(kind: .todo)
            }
            if remindersEnabled {
                ReminderPopupCard()
                TaskAlarmCard(kind: .reminder)
            }
        }
        .onAppear { reminders.reload() }
    }
}

private struct TrayPage: View {
    @AppStorage(Preferences.blipEnabledKey) private var blipEnabled = true
    @AppStorage(Preferences.trayFirstKey) private var trayFirst = true

    var body: some View {
        SettingsPage(.tray) {
            SettingsCard {
                ToggleRow(symbol: "tray.full.fill", tint: Theme.teal,
                          title: "Open tray first when it has files",
                          isOn: $trayFirst)
                RowDivider()
                ToggleRow(symbol: "paperplane.fill", tint: Theme.blue,
                          title: "Blip integration",
                          isOn: $blipEnabled)
                    .disabled(FileSharing.blipURL == nil)
            }
        }
    }
}

private struct SensoryPage: View {
    @AppStorage(Preferences.sensoryBrightnessKey) private var brightness = true
    @AppStorage(Preferences.sensoryVolumeKey) private var volume = true
    @AppStorage(Preferences.sensoryKeyboardKey) private var keyboard = true
    @AppStorage(Preferences.sensoryColorModeKey) private var colorMode = ""
    @AppStorage(Preferences.sensoryLayoutKey) private var layout = "downline"
    @AppStorage(Preferences.sensoryDurationKey) private var duration = 3.0
    @AppStorage(Preferences.sensoryDownlineMotionKey) private var downlineMotion = "downline"
    @AppStorage(Preferences.sensoryPercentKey) private var showPercent = false

    /// The percentage belongs to the inline look: the Inline bar position, or the Calm animation below the notch.
    private var inlineLook: Bool { layout == "inline" || downlineMotion == "inline" }

    var body: some View {
        SettingsPage(.sensory) {
            SettingsCard("Position") {
                SettingRow(symbol: "rectangle.split.2x1.fill", tint: Theme.teal,
                           title: "Bar position") {
                    SegmentedChoice([("downline", "Downline"), ("inline", "Inline")], selection: $layout)
                        .frame(width: 210)
                }
                // Downline keeps its place below the notch; this picks the motion and look it plays with.
                if layout == "downline" {
                    RowDivider()
                    SettingRow(symbol: "sparkles", tint: Theme.violet,
                               title: "Animation") {
                        SegmentedChoice([("downline", "Cascade"), ("inline", "Calm")], selection: $downlineMotion)
                            .frame(width: 210)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: layout)
            if inlineLook {
                SettingsCard("Percentage") {
                    ToggleRow(symbol: "percent", tint: Theme.teal,
                              title: "Show percentage", isOn: $showPercent)
                }
                .transition(.opacity)
            }
            SettingsCard("Show overlays for") {
                ToggleRow(symbol: "display", tint: Theme.yellow,
                          title: "Brightness", isOn: $brightness)
                RowDivider()
                ToggleRow(symbol: "speaker.wave.2.fill", tint: Theme.blue,
                          title: "Volume", isOn: $volume)
                RowDivider()
                ToggleRow(symbol: "light.max", tint: Theme.orange,
                          title: "Keyboard backlight",
                          isOn: $keyboard)
                RowDivider()
                SettingRow(symbol: "paintpalette.fill", tint: Theme.pink,
                           title: "Color") {
                    SegmentedChoice([("album", "Album"), ("system", "System"), ("none", "None")],
                                    selection: Binding(get: { Preferences.hudColorMode(colorMode) },
                                                       set: { colorMode = $0 }))
                        .frame(width: 240)
                }
                RowDivider()
                SettingRow(symbol: "timer", tint: Theme.indigo,
                           title: "Stays on screen") {
                    HStack(spacing: 10) {
                        Slider(value: $duration, in: 1...6, step: 1)
                            .tint(Theme.accent)
                            .frame(width: 150)
                            .onChange(of: duration) { _, _ in Haptics.hf3(lockout: 0.03) }
                        Text("\(Int(duration)) sec")
                            .font(.system(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct BatteryPage: View {
    @AppStorage(Preferences.liveBatteryKey) private var liveBattery = true
    @AppStorage(Preferences.batteryLimitKey) private var batteryLimit = 100.0

    var body: some View {
        SettingsPage(.battery) {
            SettingsCard {
                ToggleRow(symbol: "bolt.fill", tint: Theme.green,
                          title: "Show battery in the notch",
                          isOn: $liveBattery)
            }
            SettingsCard("Charging animation") {
                SettingRow(symbol: "battery.100percent.bolt", tint: Theme.green,
                           title: "Show animation at") {
                    HStack(spacing: 10) {
                        Slider(value: $batteryLimit, in: 80...100, step: 10)
                            .tint(Theme.accent)
                            .frame(width: 130)
                            .onChange(of: batteryLimit) { _, _ in Haptics.hf3(lockout: 0.03) }
                        Text("\(Int(batteryLimit))%")
                            .font(.system(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!liveBattery)
                .opacity(liveBattery ? 1 : 0.4)
            }
        }
    }
}

private struct BluetoothPage: View {
    @AppStorage(Preferences.liveBluetoothKey) private var liveBluetooth = true
    @AppStorage(Preferences.bluetoothDisconnectKey) private var showDisconnect = true
    @AppStorage(Preferences.bluetoothEarbudStyleKey) private var earbudStyle = "pro"
    @AppStorage(Preferences.bluetooth3DKey) private var use3D = true

    private func deviceTile(_ kind: BluetoothKind) -> some View {
        ChoiceTile(selected: false, action: { preview(kind, connected: true) }) {
            VStack(spacing: 7) {
                BluetoothGlyph(kind: kind, style: "", size: 34)
                Text(kind.appleName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
        }
    }

    private func preview(_ kind: BluetoothKind, connected: Bool) {
        NotificationCenter.default.post(name: .indraBluetoothPreview, object: nil,
                                        userInfo: ["kind": kind.rawValue, "connected": connected])
    }

    private func earbudTile(_ title: String, style: String) -> some View {
        let selected = earbudStyle == style
        return ChoiceTile(selected: selected, action: {
            earbudStyle = style
            DispatchQueue.main.async { preview(.earbuds, connected: true) }
        }) {
            VStack(spacing: 7) {
                BluetoothGlyph(kind: .earbuds, style: style, size: 34)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.7))
            }
        }
    }

    var body: some View {
        SettingsPage(.bluetooth) {
            SettingsCard {
                ToggleRow(symbol: "airpods", tint: Theme.blue,
                          title: "Show Bluetooth devices",
                          isOn: $liveBluetooth)
                RowDivider()
                ToggleRow(symbol: "circle.fill", tint: Theme.red,
                          title: "Also show when they disconnect",
                          isOn: $showDisconnect)
                    .disabled(!liveBluetooth)
                RowDivider()
                ToggleRow(symbol: "cube.fill", tint: Theme.indigo,
                          title: "3D device renders",
                          isOn: $use3D)
            }
            SettingsCard("Earbuds animation") {
                HStack(spacing: 10) {
                    earbudTile("AirPods Pro", style: "pro")
                    earbudTile("AirPods", style: "airpods")
                    ChoiceTile(selected: false, action: { preview(.headphones, connected: true) }) {
                        VStack(spacing: 7) {
                            BluetoothGlyph(kind: .headphones, style: "bounce", size: 34)
                            Text("Headphones")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.7))
                        }
                    }
                }
                .padding(14)
            }
            SettingsCard("Other devices") {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(Array(BluetoothKind.otherDevices.prefix(4)), id: \.self) { deviceTile($0) }
                    }
                    HStack(spacing: 10) {
                        ForEach(Array(BluetoothKind.otherDevices.suffix(4)), id: \.self) { deviceTile($0) }
                    }
                }
                .padding(14)
            }
            BluetoothDevicesCard()
        }
    }
}

/// Every paired device (and every one Indra has shown), each with the product it is drawn as.
/// A wrong guess is fixed here, once.
private struct BluetoothDevicesCard: View {
    @State private var devices: [BluetoothSeenDevice] = []
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private func binding(for device: BluetoothSeenDevice) -> Binding<BluetoothKind> {
        Binding(get: { BluetoothMemory.override(for: device.name) ?? device.kind },
                set: { newKind in
                    BluetoothMemory.setOverride(newKind, for: device.name)
                    devices = BluetoothMemory.all()
                })
    }

    var body: some View {
        SettingsCard("Your devices") {
            if devices.isEmpty {
                SettingRow(title: "No paired devices") { EmptyView() }
            } else {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { RowDivider() }
                    SettingRow(title: device.name) {
                        Picker("", selection: binding(for: device)) {
                            ForEach(BluetoothKind.allCases, id: \.self) { kind in
                                Text(kind.appleName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }
        }
        .onAppear { devices = BluetoothMemory.all() }
        .onReceive(refresh) { _ in devices = BluetoothMemory.all() }   // a device paired just now appears too
    }
}

private struct LockScreenPage: View {
    @AppStorage(Preferences.lockPlayerKey) private var lockPlayer = true
    @AppStorage(Preferences.lockHapticsEnabledKey) private var lockHaptics = true
    @AppStorage(Preferences.lockSoundOnKey) private var lockSoundOn = false
    @AppStorage(Preferences.unlockSoundOnKey) private var unlockSoundOn = false
    @AppStorage(Preferences.lockClockStyleKey) private var clockStyle = "aurora"
    @AppStorage(Preferences.lockBackdropBlurKey) private var lockBlur = Preferences.lockBackdropBlurDefault
    @AppStorage(Preferences.lockBackdropDarknessKey) private var lockDarkness = Preferences.lockBackdropDarknessDefault
    @AppStorage(Preferences.lyricsFontKey) private var lyricsFont = Preferences.lyricsFontDefault
    @AppStorage(Preferences.lyricsDisplayKey) private var lyricsDisplay = Preferences.defaultLyricsDisplay
    @AppStorage(Preferences.lyricsLatinKey) private var lyricsLatin = false
    @AppStorage(Preferences.lockMotionArtKey) private var lockMotionArt = true
    @AppStorage(Preferences.lockBlurVideoKey) private var lockBlurVideo = Preferences.lockBlurVideoDefault
    @AppStorage(Preferences.spotifyClientIDKey) private var spotifyClientID = ""
    @ObservedObject private var spotify = SpotifyWebAPI.shared
    /// v419: switching the lock screen player off first asks, and hints at what would be lost.
    @State private var askKeepPlayer = false

    var body: some View {
        SettingsPage(.lockScreen) {
            SettingsCard("Music player") {
                ToggleRow(symbol: "music.note", tint: Theme.pink,
                          title: "Show the player on the lock screen",
                          isOn: Binding(get: { lockPlayer },
                                        set: { wantsOn in
                                            if wantsOn { lockPlayer = true } else { askKeepPlayer = true }
                                        }))
                RowDivider()
                ToggleRow(symbol: "hand.tap.fill", tint: Theme.orange,
                          title: "Haptic feedback",
                          subtitle: "Trackpad taps on the lock screen only. The switch in General covers the notch.",
                          isOn: Binding(get: { lockHaptics },
                                        set: { newValue in
                                            lockHaptics = newValue
                                            IndraLog.crumb("Lock screen haptic feedback turned \(newValue ? "on" : "off")")
                                            if newValue {
                                                UserDefaults.standard.set(true, forKey: Preferences.lockHapticsEnabledKey)
                                                Haptics.tap(.action, lockout: 0, scope: .lock)   // one tap as proof it works
                                            }
                                        }))
            }
            SettingsCard("Sounds") {
                ToggleRow(symbol: "lock.fill", tint: Theme.cyan,
                          title: "Lock sound",
                          subtitle: "Plays when the Mac locks.",
                          isOn: $lockSoundOn)
                    .onChange(of: lockSoundOn) { _, on in if on { LockSounds.preview(locking: true) } }
                RowDivider()
                ToggleRow(symbol: "lock.open.fill", tint: Theme.pink,
                          title: "Unlock sound",
                          subtitle: "Plays when the Mac unlocks.",
                          isOn: $unlockSoundOn)
                    .onChange(of: unlockSoundOn) { _, on in if on { LockSounds.preview(locking: false) } }
            }
            SettingsCard("Background") {
                SettingRow(symbol: "photo.fill", tint: Theme.cyan,
                           title: "Album blur") {
                    HStack(spacing: 10) {
                        Text("Clear")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Slider(value: $lockBlur, in: 0...120)
                            .tint(Theme.accent)
                            .frame(width: 170)
                            .onChange(of: Int((lockBlur / 6).rounded())) { _, _ in Haptics.hf3(lockout: 0.03) }
                        Text("Frosted")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                RowDivider()
                SettingRow(symbol: "circle.lefthalf.filled", tint: Theme.gray,
                           title: "Darkness") {
                    HStack(spacing: 10) {
                        Text("Light")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Slider(value: $lockDarkness, in: 0...1)
                            .tint(Theme.accent)
                            .frame(width: 170)
                            .onChange(of: Int((lockDarkness * 20).rounded())) { _, _ in Haptics.hf3(lockout: 0.03) }
                        Text("Dark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                RowDivider()
                ToggleRow(symbol: "play.rectangle.fill", tint: Theme.pink,
                          title: "Animated album covers",
                          isOn: $lockMotionArt)
                RowDivider()
                ToggleRow(symbol: "drop.fill", tint: Theme.cyan,
                          title: "Blur the video",
                          isOn: $lockBlurVideo)
                    .disabled(!lockMotionArt)
                    .opacity(lockMotionArt ? 1 : 0.45)
                RowDivider()
                SettingRow(symbol: "arrow.counterclockwise", tint: Theme.gray,
                           title: "Reset") {
                    ActionButton(title: "Reset", symbol: "arrow.counterclockwise", kind: .secondary) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            lockBlur = Preferences.lockBackdropBlurDefault
                            lockDarkness = Preferences.lockBackdropDarknessDefault
                        }
                    }
                    .disabled(lockBlur == Preferences.lockBackdropBlurDefault
                              && lockDarkness == Preferences.lockBackdropDarknessDefault)
                }
            }
            SettingsCard("Clock") {
                SettingRow(symbol: "clock.fill", tint: Theme.indigo,
                           title: "Digital clock style") {
                    EmptyView()
                }
                ClockStylePicker(raw: $clockStyle)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
            SettingsCard("Lyrics") {
                SettingRow(symbol: "text.alignleft", tint: Theme.teal,
                           title: "Lyrics view") {
                    SegmentedChoice([("line", "Current line"), ("whole", "Whole lyrics")], selection: $lyricsDisplay)
                        .frame(width: 230)
                }
                RowDivider()
                ToggleRow(symbol: "character.book.closed.fill", tint: Theme.teal,
                          title: "Lyrics in English letters",
                          isOn: $lyricsLatin)
                RowDivider()
                SettingRow(symbol: "textformat", tint: Theme.violet,
                           title: "Lyrics font") {
                    EmptyView()
                }
                LyricsFontPicker(raw: $lyricsFont)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
            SettingsCard("Spotify queue") {
                SettingRow(symbol: "key.fill", tint: Theme.yellow,
                           title: "Client ID") {
                    TextField("", text: $spotifyClientID, prompt: Text("From your Spotify developer app"))
                        .fieldStyle()
                        .frame(width: 260)
                }
                RowDivider()
                SettingRow(symbol: "link", tint: Theme.blue,
                           title: spotify.connected ? "Connected" : "Not connected",
                           subtitle: spotify.status.isEmpty ? nil : spotify.status) {
                    if spotify.connected {
                        ActionButton(title: "Disconnect", kind: .destructive) { spotify.disconnect() }
                    } else {
                        ActionButton(title: "Connect", kind: .primary) { spotify.connect() }
                            .disabled(spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            // v486: every browser on this Mac that Indra can read YouTube from, not only Safari.
            SettingsCard("YouTube in your browser") {
                ForEach(YouTubeBrowsers.all.filter { YouTubeBrowsers.isInstalled($0) }, id: \.id) { browser in
                    if browser.id != YouTubeBrowsers.all.first(where: { YouTubeBrowsers.isInstalled($0) })?.id {
                        RowDivider()
                    }
                    SettingRow(symbol: "play.rectangle.fill", tint: Theme.red,
                               title: browser.name) {
                        ActionButton(title: "Open…", symbol: "gearshape") {
                            // v420: Indra only appears in the Automation list after it has asked for the browser, so it
                            // asks first (opening the browser if needed), and then opens the page.
                            HealthFix.askThenOpenAutomation(bundle: browser.id)
                        }
                    }
                }
            }
        }
        .alert("Wait, there is a surprise for you", isPresented: $askKeepPlayer) {
            Button("Keep it on", role: .cancel) { }
            Button("Turn it off", role: .destructive) { lockPlayer = false }
        } message: {
            Text("On the lock screen, click the album photo or the song name on the player. Something special is waiting there.")
        }
    }
}

// MARK: - Sidebar row

/// One sidebar row: a small coloured icon tile, a selection pill that slides between rows, a soft hover glow.
private struct SidebarRow: View {
    let item: AppPage
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @State private var bounce = 0
    @AppStorage(Preferences.remindersEnabledKey) private var remindersOn = false
    @ObservedObject private var health = HealthMonitor.shared

    var body: some View {
        Button(action: { bounce += 1; action() }) {
            HStack(spacing: 10) {
                PageGlyph(page: item, size: 24, bounce: bounce)
                    .scaleEffect(hovering && !selected ? 1.08 : 1)
                Text(item.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : (hovering ? 0.95 : 0.85)))
                Spacer(minLength: 0)
                // The self-check found something that is not working: a red dot on About.
                if item == .about, !health.issues.isEmpty {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: health.issues.isEmpty)
            .animation(.smooth(duration: 0.25), value: selected)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background {
                ZStack {
                    if hovering && !selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .transition(.opacity)
                    }
                    if selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.primary.opacity(0.11))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                            .matchedGeometryEffect(id: "sidebarPill", in: namespace)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}
