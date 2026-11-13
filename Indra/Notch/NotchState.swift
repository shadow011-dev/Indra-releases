import SwiftUI

enum NotchTab: Equatable {
    case player
    case tray
    case calendar
    /// Now playing + calendar side by side (NotchNook style).
    case duo
    case weather
    case todo
    /// Duo only: the Zen space (focus session / clipboard manager), one swipe down from the player + calendar page.
    case zen
}

@MainActor
final class NotchState: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var showsMirror = false
    /// True for a moment while the mirror is closing: the camera circle fades out before the notch shrinks.
    @Published private(set) var mirrorClosing = false
    @Published private(set) var tab: NotchTab = .player
    /// A new value for every page change: each page is built fresh, even when you switch back and forth quickly.
    /// "Show date" is on and the person opened the month grid by clicking the date (false = the date + events page).
    @Published private(set) var monthOpen = false
    @Published private(set) var pageToken = 0
    /// Direction the pages travel on a swipe: (0, 1) = down, (1, 0) = right. Drives the page transition.
    @Published private(set) var pageMove = CGSize(width: 0, height: 1)
    /// False while the notch opens / after it closes, so a stale page never animates away in view.
    @Published private(set) var animatesPages = true
    @Published private(set) var idleMode: IdleMode = .none
    @Published private(set) var liveActivity: LiveActivity?
    /// v553: a new version is ready and the closed notch is idle: the update symbol is drawn on its right side (see UpdateNotice).
    @Published private(set) var updateBadge = false
    /// A volume / brightness, Bluetooth or battery card shown in a strip that hangs below the OPEN notch.
    @Published private(set) var expandedStrip: LiveActivity?
    @Published var isDropTargeted = false
    /// True while Duo is the chosen idle page. Duo already shows the calendar, so Weather, To-do and the camera
    /// preview open at the Duo size instead of resizing the notch.
    @Published private(set) var duoLayout = false
    /// v530: true from the moment the intro animation is asked for until the notch has closed again after it. The open notch
    /// then has the intro's size, a black body and the video as its page (see NotchRootView).
    @Published private(set) var introPlaying = false
    /// v531: true once the intro video has ended: the picture melts away and "Indra / CREATED BY SHADOW" settles in.
    @Published private(set) var introOutro = false
    /// Set by the notch controller: called once when the intro video has shown its last frame.
    var onIntroEnded: (() -> Void)?

    /// A new value makes the closed notch give a small bounce (the pointer arrived while "Expand notch on hover" is off).
    @Published private(set) var bounceToken = 0
    /// True while the pointer rests on the closed notch and the hover duration (Settings) is running down; the
    /// notch swells a little and a thin line fills under it meanwhile. `hoverChargeDuration` is how long that is.
    @Published var hoverCharging = false
    var hoverChargeDuration = 0.1
    /// True while the notch is open because the pointer rested on it for the hover duration (it opens more softly).
    @Published var openedByHover = false
    /// True while a text field in the notch has the keyboard (the notch stays open meanwhile).
    @Published private(set) var isEditing = false
    var onEditingEnded: (() -> Void)?
    @Published var activeDropZone: DropZone?
    @Published var metrics: NotchMetrics
    /// Changes after a desktop change when the closed notch is at rest (see NotchRootView).
    @Published private(set) var settleToken = 0

    /// v563: 0 or 0.01 points added to the closed body's width. Changing it WITHOUT animation ends a spring that stopped half way
    /// (a widening that the slide of the desktops or a window change froze): the body jumps to the width it was heading for. When
    /// the spring has finished, nothing can be seen. See NotchWindowController.verifyInlineHUDWidth.
    @Published private(set) var closedNudge: CGFloat = 0

    func nudgeClosed() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { closedNudge = closedNudge == 0 ? 0.01 : 0 }
    }

    func settle() {
        guard !isExpanded, liveActivity == nil, expandedStrip == nil, !isDropTargeted else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { settleToken &+= 1 }
    }

    // v429: the second notch (the island on an external monitor) shares all of these with the first, so there is one player,
    // one calendar and one tray; only what is open, hovered or showing is its own.
    let mirror: MirrorController
    let media: MediaController
    let identifier: SongIdentifier
    let tray: TrayStore
    let calendar: CalendarController
    let weather: WeatherController
    let todo = TodoStore.shared
    let reminders = RemindersStore.shared
    let audio: AudioLevelMonitor
    let focus = FocusTimer.shared
    let clipboard = ClipboardStore.shared

    init(metrics: NotchMetrics, sharing other: NotchState? = nil) {
        self.metrics = metrics
        mirror = other?.mirror ?? MirrorController()
        media = other?.media ?? MediaController()
        identifier = other?.identifier ?? SongIdentifier()
        tray = other?.tray ?? TrayStore()
        calendar = other?.calendar ?? CalendarController()
        weather = other?.weather ?? WeatherController()
        audio = other?.audio ?? AudioLevelMonitor()
        if other == nil {
            media.start()
            identifier.media = media
        }
    }

    func setIntro(_ on: Bool) {
        guard introPlaying != on else { return }
        introPlaying = on
        introOutro = false
    }

    func introVideoEnded() {
        guard introPlaying, !introOutro else { return }
        introOutro = true
        onIntroEnded?()
    }

    func bounce() {
        bounceToken &+= 1
    }

    /// First half of opening: the page is chosen while the notch is still closed and nothing is animated, so the
    /// layout work happens before the opening animation starts instead of during its first frames.
    /// When the notch last started to open (the corner of an open record waits for the notch to grow first).
    private(set) var expandedAt = Date.distantPast

    func prepareOpen(tab: NotchTab) {
        guard !isExpanded else { return }
        animatesPages = false
        self.tab = resolvedTab(tab)
    }

    /// Opens on the requested tab, never on the last-used one.
    func expand(tab: NotchTab = .player) {
        guard !isExpanded else { return }
        animatesPages = false
        self.tab = resolvedTab(tab)
        expandedAt = Date()
        isExpanded = true
        IndraLog.crumb("Notch opened (\(tab))")
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        closedShrinking = true
        IndraLog.crumb("Notch closed")
        isDropTargeted = false
        isEditing = false
        expandedStrip = nil
        activeDropZone = nil
        mirrorClosing = false
        setMirror(false)
    }

    /// Left to right: Files Tray, AirDrop, and Blip when enabled and installed.
    var dropZones: [DropZone] {
        var zones: [DropZone] = [.tray, .airDrop]
        if Preferences.blipEnabled && FileSharing.blipURL != nil { zones.append(.blip) }
        return zones
    }

    /// Size of the closed notch body, wider while an idle activity is visible.
    /// True while the closed notch is widened (idle activity or a live activity).
    var closedSlot: CGFloat { slot(idle: idleMode, live: liveActivity) }

    /// Width added on each side of the closed notch for an idle / live activity combination.
    func slot(idle: IdleMode, live: LiveActivity?, badge: Bool? = nil) -> CGFloat {
        if case .hud? = live {
            // v491: a longer inline bar widens the slot by the same amount, so it is never cut.
            if sensoryLayout != "downline" { return metrics.hudSlot + max(0, Preferences.inlineBarLengthExtra) }
            // Downline overlay: only the HUD shows, the idle activity (art, circle, ...) steps aside.
            return 0
        }
        if case .task? = live { return 0 }
        // v553: the update card keeps the notch the way it is (the update symbol, or the artwork and visualizer, stay beside it).
        if case .update? = live { return idle == .duo ? metrics.idleSlot : metrics.compactSlot }
        // Song change: the closed notch keeps its artwork and visualizer, whatever the idle page is.
        if case .song? = live { return idle == .duo ? metrics.idleSlot : metrics.compactSlot }
        if live != nil { return metrics.idleSlot }
        switch idle {
        case .none: return (badge ?? updateBadge) ? metrics.compactSlot : 0
        case .playing: return metrics.compactSlot
        default: return metrics.idleSlot
        }
    }

    /// v433: the island (external monitor) can have its own HUD position and Zen page (Settings > External Notch).
    var sensoryLayout: String { Preferences.sensoryLayout(island: metrics.island) }
    var zenMode: String { Preferences.zenMode(island: metrics.island) }

    /// Volume / brightness overlay shown below the notch (notch style, "downline" layout).
    var downlineHUD: (kind: HUDKind, value: Double, muted: Bool)? {
        if case .hud(let kind, let value, let muted)? = liveActivity, sensoryLayout == "downline" {
            return (kind, value, muted)
        }
        return nil
    }
    /// The name of the Bluetooth device being shown, when there is one (a preview or an unnamed device has none).
    var bluetoothName: String? {
        if case .bluetooth(let name, _, _)? = liveActivity, !name.isEmpty { return name }
        return nil
    }
    var isBluetoothDownline: Bool { bluetoothName != nil }
    /// A to-do or reminder popping up below the closed notch.
    var taskPopup: (kind: TaskKind, title: String, detail: String)? {
        if case .task(let kind, let title, let detail)? = liveActivity { return (kind, title, detail) }
        return nil
    }
    /// The title and artist of the song that just started, while its card hangs below the closed notch.
    var songCard: (title: String, artist: String)? {
        if case .song(let title, let artist)? = liveActivity { return (title, artist) }
        return nil
    }
    var isSongDownline: Bool { songCard != nil }
    /// v553: the version number of the update card hanging below the closed notch.
    var updateNotice: Int? {
        if case .update(let version)? = liveActivity { return version }
        return nil
    }
    var isUpdateDownline: Bool { updateNotice != nil }
    var isDownlineHUD: Bool {
        downlineHUD != nil || isBluetoothDownline || taskPopup != nil || isSongDownline || isUpdateDownline
    }
    /// Size of the body while any downline overlay shows.
    var downlineSize: CGSize {
        if isSongDownline || isUpdateDownline { return metrics.songDownlineSize(slot: closedSlot) }
        return isBluetoothDownline ? metrics.bluetoothDownlineSize(slot: closedSlot) : metrics.hudDownlineSize
    }
    var isClosedWide: Bool { closedSlot > 0 }
    var isHUDActive: Bool {
        if case .hud? = liveActivity { return true }
        return false
    }
    var closedBodySize: CGSize { metrics.closedBodySize(slot: closedSlot) }

    /// Height of the strip under the open notch for an activity (0 = that activity has no strip).
    static func stripHeight(for activity: LiveActivity, island: Bool = false) -> CGFloat {
        switch activity {
        // "Inline" layout: the slim icon + bar row of the closed notch; otherwise the taller percentage + ticks card.
        case .hud: return Preferences.sensoryLayout(island: island) == "inline" ? 50 : 64
        case .battery: return 56
        case .bluetooth: return 60
        case .task: return 56
        case .lock, .song, .update: return 0
        }
    }

    var stripHeight: CGFloat { expandedStrip.map { NotchState.stripHeight(for: $0, island: metrics.island) } ?? 0 }

    func setStrip(_ activity: LiveActivity?) {
        guard expandedStrip != activity else { return }
        expandedStrip = activity
        // The card under the open notch growing is an opening movement, its leaving a closing one.
        closedShrinking = activity == nil
    }

    /// v439: true while the closed notch is getting smaller (a card folding back, an activity leaving, the open notch
    /// closing). It picks the spring that does not overshoot, and keeps the body from going narrower or shorter than the
    /// size it is heading for (see NotchRootView). Set in the same turn as the change itself, before anything is drawn.
    private(set) var closedShrinking = false

    private var closedFootprint: CGSize { isDownlineHUD ? downlineSize : closedBodySize }

    private func noteClosedChange(from before: CGSize) {
        let after = closedFootprint
        closedShrinking = after.width + after.height < before.width + before.height
    }

    /// v439: while the external notch changes between the island and the notch look it is invisible for a moment.
    @Published private(set) var lookHidden = false

    func setLookHidden(_ hidden: Bool) {
        guard lookHidden != hidden else { return }
        lookHidden = hidden
    }

    func setLive(_ activity: LiveActivity?) {
        guard liveActivity != activity else { return }
        let before = closedFootprint
        liveActivity = activity
        noteClosedChange(from: before)
    }

    func setIdle(_ mode: IdleMode, updateBadge badge: Bool? = nil) {
        let badgeChanged = badge != nil && badge != updateBadge
        guard idleMode != mode || badgeChanged else { return }
        let before = closedFootprint
        idleMode = mode
        if let badge { updateBadge = badge }
        noteClosedChange(from: before)
    }

    /// In Duo the Zen space can be set to show the file tray (Settings > Zen space). The tray then lives on that
    /// page: it has no page or header button of its own, and anything that would open the tray opens it instead.
    var trayInZen: Bool {
        duoLayout && zenMode == "tray"
    }

    /// The page that really shows `tab`: the tray's page is the Zen page while the tray lives there.
    func resolvedTab(_ tab: NotchTab) -> NotchTab {
        tab == .tray && trayInZen ? .zen : tab
    }

    func setDuoLayout(_ on: Bool) {
        guard duoLayout != on else { return }
        duoLayout = on
        // The clipboard manager only watches the clipboard while Duo is the chosen page.
        if on { clipboard.start() } else { clipboard.stop() }
        if !on, tab == .zen { tab = .player }
    }

    /// True while Weather, To-do or Reminders is open in Duo: they get the Duo width and a taller notch, so the
    /// page is shown large instead of squeezed into the short Duo height.
    var isDuoLarge: Bool {
        !showsMirror && duoLayout && (tab == .weather || tab == .todo)
    }

    /// v459: on the floating island the header row (player / tray / camera buttons) is gone, so a page that had it is shorter
    /// by that row. Pages without a header (calendar, weather, to-do) and the file-drop zones keep their size.
    var islandHeaderSaving: CGFloat {
        guard metrics.islandShaped, !isDropTargeted else { return 0 }
        if !showsMirror, tab == .calendar || tab == .weather || tab == .todo { return 0 }
        return metrics.islandHeaderSaving
    }

    /// True when the open notch has the (wider) Duo size.
    var isDuoSized: Bool {
        if showsMirror { return tab == .duo }
        if tab == .duo || tab == .zen { return true }
        return duoLayout && (tab == .weather || tab == .todo || tab == .tray)
    }

    func setMonthOpen(_ open: Bool) {
        guard monthOpen != open else { return }
        monthOpen = open
    }

    func setPageMove(_ move: CGSize) {
        pageMove = move
    }

    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        if !editing { onEditingEnded?() }
    }

    func setAnimatesPages(_ on: Bool) {
        animatesPages = on
    }

    /// Back to the default page, without animation (used once the notch is closed).
    func resetPage() {
        animatesPages = false
        monthOpen = false
        calendar.resetToToday()
        isEditing = false
        if tab != .player { pageToken &+= 1 }
        tab = .player
        pageMove = CGSize(width: 0, height: 1)
    }

    func select(_ requested: NotchTab) {
        let tab = resolvedTab(requested)
        if self.tab != tab { pageToken &+= 1 }
        if tab != .calendar { monthOpen = false }
        if tab != .todo { isEditing = false }
        self.tab = tab
    }

    func setMirrorClosing(_ closing: Bool) {
        mirrorClosing = closing
    }

    func setMirror(_ on: Bool) {
        guard showsMirror != on else { return }
        showsMirror = on
        // The box opens first; the camera only starts when it is clicked (MirrorView), and stops with the box.
        if !on { mirror.stop() }
    }
}
