import SwiftUI

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    // v440: each notch watches its own record (the MacBook's and the external monitor's are independent).
    @ObservedObject private var mainVinyl = DuoVinylState.shared
    @ObservedObject private var islandVinyl = DuoVinylState.island
    // The same flag the player page uses to pick its record (the window's, not the metrics': with the lid closed the
    // external monitor hosts the first notch, which is still the "main" one).
    @Environment(\.notchIsland) private var windowIsIsland
    private var duoVinyl: DuoVinylState { windowIsIsland ? islandVinyl : mainVinyl }
    @AppStorage(Preferences.showDateKey) private var showDate = false
    @AppStorage(Preferences.showCalendarKey) private var showCalendar = true
    @AppStorage(Preferences.liquidGlassKey) private var liquidGlass = false
    @AppStorage(Preferences.translucentNotchKey) private var translucentNotch = true
    @AppStorage(Preferences.idleActivityKey) private var mainIdleActivity = "duo"
    @AppStorage(Preferences.zenModeKey) private var mainZenMode = Preferences.defaultZenMode
    // v433: the island (external monitor) can have its own idle page, Zen page and to-do list (Settings > External Notch).
    @AppStorage(Preferences.islandIdleActivityKey) private var islandIdleActivity = ""
    @AppStorage(Preferences.islandZenModeKey) private var islandZenMode = ""
    @AppStorage(Preferences.islandTaskPageKey) private var islandTaskPage = ""
    @AppStorage(Preferences.glassDarknessKey) private var glassDarkness = 0.55
    @AppStorage(Preferences.remindersEnabledKey) private var mainRemindersOn = false
    let requestExpand: () -> Void
    let toggleMirror: () -> Void
    /// The camera button in the header: opens the camera preview and starts the camera; pressed again it switches
    /// the camera off, and once more on.
    let mirrorButton: () -> Void
    let selectTab: (NotchTab) -> Void
    /// v443: Duo only: the month name was clicked, open the full month calendar.
    var openMonth: () -> Void = {}

    private var expanded: Bool { state.isExpanded }
    private var metrics: NotchMetrics { state.metrics }
    private var idleActivity: String { Preferences.pick(mainIdleActivity, islandIdleActivity, island: metrics.island) }
    private var zenMode: String { Preferences.pick(mainZenMode, islandZenMode, island: metrics.island) }
    private var remindersOn: Bool {
        metrics.island && !islandTaskPage.isEmpty ? islandTaskPage == "reminders" : mainRemindersOn
    }
    private var openSize: CGSize {
        // v530: the intro animation: the normal open notch, sized for the video.
        if state.introPlaying { return metrics.introSize }
        if state.isDropTargeted { return metrics.dropSize }
        let full: CGSize
        if state.showsMirror { full = state.isDuoSized ? metrics.duoMirrorSize : metrics.mirrorSize }
        else if state.isDuoLarge { full = metrics.duoLargeSize }
        else if state.isDuoSized { full = metrics.duoSize }
        else { full = metrics.expandedSize }
        // v459: no header row on the island: the notch is that much shorter (the page keeps its own size).
        return CGSize(width: full.width, height: full.height - state.islandHeaderSaving)
    }

    /// Calendar, weather and to-do fill the whole notch (no header, no side padding).
    private var isFullBleed: Bool {
        guard !state.showsMirror, !state.isDropTargeted else { return false }
        switch state.tab {
        case .calendar, .weather, .todo: return true
        default: return false
        }
    }

    @State private var staggerEpoch = 0
    @State private var hoveredButton: String?
    /// Kept for the hover tracking below; the header buttons no longer hide on it.
    @State private var pointerAtTop = false
    @State private var hideTask: Task<Void, Never>?
    /// 0 = at rest, 1 = the closed notch at the top of its bounce.
    @State private var bounce: CGFloat = 0
    @State private var bounceTask: Task<Void, Never>?
    /// 0 ... 1 while the pointer rests on the closed notch waiting for the hover duration (Settings): the notch swells
    /// a little and a thin line fills under it, then the opening takes over.
    @State private var charge: CGFloat = 0
    /// How far the bottom corners have turned into the circle round the open record (0 ... 1).
    @State private var vinylAmount: CGFloat = 0

    /// The header buttons (player, tray, camera) stay on screen the whole time the notch is open, in Duo too.
    private var headerRevealed: Bool { true }

    /// Height of the card under the open notch (none while files are being dragged in).
    private var stripHeight: CGFloat { state.isDropTargeted ? 0 : state.stripHeight }

    private func stripCardWidth(for activity: LiveActivity) -> CGFloat {
        if case .hud = activity { return metrics.hudDownlineSize.width }
        return openSize.width
    }

    private var currentSize: CGSize {
        if expanded { return CGSize(width: openSize.width, height: openSize.height + stripHeight) }
        if state.isDownlineHUD { return state.downlineSize }
        let body = state.closedBodySize
        return CGSize(width: body.width + state.closedNudge, height: body.height)
    }

    private var shape: NotchShape {
        // v394: on an external monitor the notch is a floating island: the same body as the notch (so every page
        // sits exactly where it does there) with all four corners rounded, like the Dynamic Island.
        if metrics.islandShaped {
            let closedRadius = metrics.closedSize.height / 2
            return NotchShape(topCornerRadius: expanded ? 23 : (state.isDownlineHUD ? 18 : (state.isClosedWide ? 8 : 0)),
                              bottomCornerRadius: expanded ? (state.isDuoSized ? 32 : 36) : (state.isDownlineHUD ? 26 : closedRadius),
                              island: true,
                              islandTopRadius: expanded ? 26 : (state.isDownlineHUD ? 22 : closedRadius),
                              vinylCorner: vinylAmount,
                              vinylCornerRadius: PlayerView.duoArtSide / 2 + PlayerView.duoCoverLeftGap)
        }
        // v404: with the record open on the Duo page the bottom corners follow the disc (same gap all round).
        // v412: the amount is its own animated value (`vinylAmount`), see `vinylTarget`.
        let vinyl = vinylAmount
        return NotchShape(topCornerRadius: expanded ? 23 : (state.isDownlineHUD ? 18 : (state.isClosedWide ? 8 : 0)),
                          bottomCornerRadius: expanded ? (state.isDuoSized ? 30 : 38) : (state.isDownlineHUD ? 28 : (state.isClosedWide ? 14 : 10)),
                          vinylCorner: vinyl,
                          vinylCornerRadius: PlayerView.duoArtSide / 2 + PlayerView.duoCoverLeftGap)
    }

    /// 1 while the corners should follow the open record: notch open, Duo page showing, record open, and nothing
    /// else (camera, file drop) on screen. It flips together with the page change, so the corner returns to the
    /// normal curve while the notch resizes, instead of snapping back later when the player page is already gone.
    private var vinylTarget: CGFloat {
        (expanded && state.isDuoSized && state.tab == .duo && !state.showsMirror && !state.isDropTargeted
            && duoVinyl.open) ? 1 : 0
    }

    /// The animated value the shape reads. Its own animation: on opening it waits until the notch has grown (a
    /// 54 pt corner on a body that is still 40 pt tall made the border bulge), and on leaving it moves with the resize.
    private func animateVinylCorner(to target: CGFloat) {
        guard vinylAmount != target else { return }
        if NotchMotion.reduced {
            withAnimation(.easeInOut(duration: 0.18)) { vinylAmount = target }
        } else if target > 0.5 {
            let sinceOpen = Date().timeIntervalSince(state.expandedAt)
            let wait = sinceOpen < 0.4 ? max(0, 0.16 - sinceOpen) : 0
            withAnimation(.smooth(duration: 0.6).delay(wait)) { vinylAmount = target }
        } else {
            withAnimation(.smooth(duration: 0.4)) { vinylAmount = target }
        }
    }

    private struct ClosedKey: Equatable {
        var slot: CGFloat
        var downline: Bool
        var strip: CGFloat
    }

    private var closedKey: ClosedKey {
        ClosedKey(slot: state.closedSlot, downline: state.isDownlineHUD, strip: stripHeight)
    }

    /// Growing: the lively spring. Shrinking (decided by the state, in the same turn as the change): no overshoot.
    private var closedMotion: Animation {
        state.closedShrinking ? NotchMotion.hudClose : NotchMotion.hudOpen
    }

    /// The smallest the body may be drawn. At rest and while growing: the camera housing. While the closed notch shrinks:
    /// the size it is shrinking to.
    private var closedFloor: CGSize {
        if !expanded, state.closedShrinking { return currentSize }
        return metrics.closedSize
    }

    private var motion: Animation {
        expanded ? (state.openedByHover ? NotchMotion.hoverOpen : NotchMotion.open) : NotchMotion.close
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                bodyBackground
                expandedContent
                    .frame(width: openSize.width, height: openSize.height, alignment: .top)
                    .scaleEffect(expanded ? 1 : NotchMotion.hiddenScale, anchor: .top)
                    .blur(radius: expanded ? 0 : NotchMotion.hiddenBlur(external: metrics.island))
                    // Never fully transparent while closed: a layer at 0 is dropped by the window server, and the first
                    // opening after a long rest then showed an empty notch that only filled in a moment later. At 1 %
                    // (blurred, shrunk, clipped to the closed notch) it cannot be seen, but stays ready to draw, so
                    // every opening, after any rest, runs like the quick second one.
                    .opacity(expanded ? 1 : NotchMotion.restingOpacity)
                    .allowsHitTesting(expanded)
                    .animation(expanded ? NotchMotion.contentIn : NotchMotion.contentOut, value: expanded)
                    // v443: the month calendar opened from Duo keeps the header buttons (player + calendar, tray, camera).
                    .overlay(alignment: .top) {
                        if showsDuoCalendarHeader, !metrics.islandShaped {
                            duoCalendarHeader
                                .frame(width: openSize.width, height: metrics.closedSize.height)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: showsDuoCalendarHeader)
                if expanded, !state.isDropTargeted, let strip = state.expandedStrip, stripHeight > 0 {
                    // Volume / brightness: exactly as wide as the card under the closed notch, centred.
                    // Battery and Bluetooth use the full width of the open notch.
                    ExpandedStripView(activity: strip, tint: downlineTint)
                        .environment(\.hudGradient, state.media.hudGradientForHUD)
                        .frame(width: stripCardWidth(for: strip), height: stripHeight, alignment: .top)
                        .frame(width: openSize.width, height: stripHeight, alignment: .top)
                        .offset(y: openSize.height)
                        .allowsHitTesting(false)
                        .transition(AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                           identity: ClosedContentFade(amount: 0))
                            .animation(.easeOut(duration: 0.26).delay(0.1)))
                }
                if let hud = state.downlineHUD, !expanded {
                    DownlineHUDView(kind: hud.kind,
                                    value: hud.value,
                                    muted: hud.muted,
                                    tint: downlineTint,
                                    notchHeight: metrics.closedSize.height)
                        .environment(\.hudGradient, state.media.hudGradientForHUD)
                        .frame(width: metrics.hudDownlineSize.width,
                               height: metrics.hudDownlineSize.height,
                               alignment: .top)
                        .allowsHitTesting(false)
                        .transition(AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                           identity: ClosedContentFade(amount: 0))
                            .animation(.easeOut(duration: 0.24).delay(0.06)))
                }
                if let task = state.taskPopup, !expanded {
                    TaskDownlineView(kind: task.kind, title: task.title, detail: task.detail,
                                     notchHeight: metrics.closedSize.height)
                        .id("\(task.kind.rawValue)|\(task.title)|\(task.detail)")
                        .frame(width: metrics.hudDownlineSize.width,
                               height: metrics.hudDownlineSize.height,
                               alignment: .top)
                        .allowsHitTesting(false)
                        .transition(AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                           identity: ClosedContentFade(amount: 0))
                            .animation(.easeOut(duration: 0.24).delay(0.06)))
                }
                if let song = state.songCard, !expanded {
                    SongChangeDownline(title: song.title, artist: song.artist,
                                       notchHeight: metrics.closedSize.height)
                        .id("\(song.title)|\(song.artist)")
                        .frame(width: state.downlineSize.width,
                               height: state.downlineSize.height,
                               alignment: .top)
                        .allowsHitTesting(false)
                        .transition(AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                           identity: ClosedContentFade(amount: 0))
                            .animation(.easeOut(duration: 0.16)))
                }
                if let version = state.updateNotice, !expanded {
                    UpdateAvailableDownline(version: version, notchHeight: metrics.closedSize.height)
                        .id(version)
                        .frame(width: state.downlineSize.width,
                               height: state.downlineSize.height,
                               alignment: .top)
                        .allowsHitTesting(false)
                        .transition(AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                           identity: ClosedContentFade(amount: 0))
                            .animation(.easeOut(duration: 0.24).delay(0.06)))
                }
                if let name = state.bluetoothName, !expanded {
                    BluetoothNameDownline(name: name, notchHeight: metrics.closedSize.height)
                        .id(name)
                        .frame(width: state.downlineSize.width,
                               height: state.downlineSize.height,
                               alignment: .top)
                        .allowsHitTesting(false)
                        .transition(AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                           identity: ClosedContentFade(amount: 0))
                            .animation(.easeOut(duration: 0.24).delay(0.06)))
                }
                if state.isClosedWide {
                    IdleActivityView(mode: (state.isSongDownline && !state.idleMode.showsMedia) ? .playing : state.idleMode,
                                     live: (state.isDownlineHUD && !state.isBluetoothDownline) ? nil : state.liveActivity,
                                     media: state.media,
                                     calendar: state.calendar,
                                     levels: state.audio.level,
                                     notchWidth: metrics.closedSize.width,
                                     slot: state.closedSlot,
                                     active: !expanded,
                                     island: metrics.islandShaped,
                                     updateBadge: state.updateBadge)
                        .frame(width: state.closedBodySize.width,
                               height: metrics.closedSize.height,
                               alignment: metrics.islandShaped ? .center : .top)
                        .opacity(expanded ? 0 : 1)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.18), value: expanded)
                        .transition(.asymmetric(
                            insertion: AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                              identity: ClosedContentFade(amount: 0))
                                .animation(.easeOut(duration: 0.26).delay(0.07)),
                            removal: AnyTransition.modifier(active: ClosedContentFade(amount: 1),
                                                            identity: ClosedContentFade(amount: 0))
                                .animation(.easeIn(duration: 0.12))))
                }
            }
            // The closed notch's small bounce: it swells a little wider (centred), then settles with a wobble.
            .frame(width: currentSize.width + (expanded ? 0 : 10 * bounce + 8 * charge),
                   height: currentSize.height + (expanded ? 0 : 2 * charge), alignment: .top)
            // v430: while the body shrinks (after a volume card, or when the open notch folds) the animation must never take it
            // narrower or shorter than the camera housing, or the housing shows beyond the edge.
            // v439: while the closed notch gets smaller (a card folding back into a notch that has an artwork + visualizer
            // beside it) the floor is the size it is heading for, not just the camera housing, so it can never be drawn
            // narrower than where it ends up.
            .frame(minWidth: metrics.islandShaped ? 0 : closedFloor.width,
                   minHeight: metrics.islandShaped ? 0 : closedFloor.height, alignment: .top)
            .clipShape(shape)
            .overlay(alignment: .bottom) {
                // The wait before opening shows as a thin light that fills from the middle of the notch outwards.
                if charge > 0.001, state.hoverChargeDuration >= 0.15, !expanded {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.9), Color.white.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(currentSize.width * charge, 1), height: 2)
                        .shadow(color: Color.white.opacity(0.5), radius: 4)
                        .offset(y: 5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { requestExpand() }
            // The spring only drives the notch body, not the content inside it.
            .animation(motion, value: expanded)
            .animation(NotchMotion.mirror, value: state.showsMirror)
            .animation(NotchMotion.resize, value: state.isDropTargeted)
            .animation(NotchMotion.resize, value: state.isDuoSized)
            .animation(NotchMotion.resize, value: state.isDuoLarge)
            .animation(NotchMotion.resize, value: state.islandHeaderSaving)
            // v439: one animation for every change of the closed size. Three separate ones (slot, card, strip) changed together
            // when a card left, and the one closest to the body won: for a notch with a song playing that was the springy
            // opening one, so the body folded back with a bounce and went under the camera housing.
            .animation(closedMotion, value: closedKey)
            // v430: rebuilt once after a desktop change when nothing is showing, so an animation that the slide of the desktops
            // froze half way (a notch left wide, a card left hanging) always ends at its real size.
            .id(state.settleToken)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        // v439: the external notch changing its look: the old one shrinks into the top edge and fades, the new one grows out of it.
        .opacity(state.lookHidden ? 0 : 1)
        .scaleEffect(state.lookHidden ? NotchMotion.lookHiddenScale : 1, anchor: UnitPoint(x: 0.5, y: 0))
        .animation(state.lookHidden ? NotchMotion.lookOut : NotchMotion.lookIn, value: state.lookHidden)
        .onChange(of: vinylTarget) { _, target in animateVinylCorner(to: target) }
        .onAppear { vinylAmount = vinylTarget }
        .onChange(of: state.bounceToken) { _, _ in playBounce() }
        .onChange(of: state.hoverCharging) { _, charging in
            if charging, !expanded {
                withAnimation(.linear(duration: max(state.hoverChargeDuration, 0.05))) { charge = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { charge = 0 }
            }
        }
    }

    private func playBounce() {
        // The tap on the trackpad still says the pointer arrived; the movement is left out for "Reduce motion".
        guard !expanded, !NotchMotion.reduced else { return }
        bounceTask?.cancel()
        bounceTask = Task { @MainActor in
            withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) { bounce = 1 }
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.4)) { bounce = 0 }
        }
    }

    private var downlineTint: Color {
        state.media.hudTintForHUD
    }

    // MARK: - Background

    /// Solid black normally. With Liquid Glass on, the open notch turns into clear glass;
    /// the top stays black so it blends with the camera housing, and the slider sets how dark the rest is.
    private var bodyBackground: some View {
        // v440: the soft black cap behind the camera housing is gone (it showed as a dark smudge through the
        // translucent body); the body is just the background now.
        baseBackground
    }

    @ViewBuilder
    private var baseBackground: some View {
        if state.introPlaying {
            // v530: the intro video has a black background: a solid black body makes it melt into the notch.
            Color.black
        } else if #available(macOS 26.0, *), liquidGlass {
            glassBackground
        } else if translucentNotch {
            frostedBackground
        } else {
            Color.black
        }
    }

    /// NotchNook-style translucent notch: the whole background is frosted glass with no gradient,
    /// open or closed, with or without an activity beside it.
    /// The Clear ... Dark slider sets how dark the glass is.
    private var frostedBackground: some View {
        ZStack {
            FrostedBackground()
            Color.black.opacity(glassDarkness * 0.9)
        }
    }

    @available(macOS 26.0, *)
    private var glassBackground: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .glassEffect(.clear, in: shape)
            // Black behind the title row, then fading to the chosen darkness (Clear = fully clear glass).
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.30),
                                   .init(color: Color.black.opacity(glassDarkness), location: 0.62),
                                   .init(color: Color.black.opacity(glassDarkness), location: 1)],
                           startPoint: .top,
                           endPoint: .bottom)
            Color.black.opacity(expanded || state.isHUDActive ? 0 : 1)
        }
    }

    // MARK: - Expanded content

    /// The old page leaves in the swipe direction while the new one arrives from the opposite side.
    private var expandedContent: some View {
        ZStack(alignment: .top) {
            if state.introPlaying {
                IntroNotchView(metrics: metrics,
                               playing: expanded,
                               outro: state.introOutro,
                               onStart: {},
                               onThunder: { IntroSound.playThunder() },
                               onEnd: { state.introVideoEnded() })
            } else if isFullBleed {
                fullBleedPage
                    .id(state.pageToken)
                    .transition(NotchMotion.pageTransition(move: state.pageMove))
            } else {
                standardContent
                    .transition(NotchMotion.pageTransition(move: state.pageMove))
            }
        }
        .animation(state.animatesPages ? (state.pageMove.height == 0 ? NotchMotion.reveal : NotchMotion.page) : nil,
                   value: state.tab)
        .environment(\.staggerEpoch, staggerEpoch)
        .onChange(of: expanded) { _, isOpen in
            if isOpen { staggerEpoch &+= 1 }
        }
    }

    /// These pages are laid out for 390 x 175 and scale with the notch size chosen in Settings.
    @ViewBuilder
    private var fullBleedPage: some View {
        // At the Duo size the page keeps its height and gets the extra width, so the widgets spread out
        // instead of sitting in a narrow column.
        let base = CalendarLayout.size
        let scale = state.isDuoSized
            ? openSize.height / base.height
            : min(openSize.width / base.width, openSize.height / base.height)
        let layoutWidth = state.isDuoSized ? openSize.width / scale : base.width
        fullBleedBase(layoutWidth: layoutWidth)
            .scaleEffect(scale, anchor: .top)
    }

    @ViewBuilder
    private func fullBleedBase(layoutWidth: CGFloat) -> some View {
        switch state.tab {
        case .weather:
            WeatherView(controller: state.weather, layoutWidth: layoutWidth)
        case .todo:
            if remindersOn {
                RemindersView(store: state.reminders, onEditingChange: { state.setEditing($0) }, layoutWidth: layoutWidth)
            } else {
                TodoView(store: state.todo, onEditingChange: { state.setEditing($0) }, layoutWidth: layoutWidth)
            }
        default:
            // "Show date" turns the calendar page into the date + events page (same colours, no month grid).
            // Clicking the date there opens the month calendar; clicking the date in the calendar goes back.
            ZStack(alignment: .topLeading) {
                if state.duoLayout {
                    // v443: opened from Duo's month name: always the month calendar (the page of a notch without Duo), on the day
                    // that was in focus.
                    CalendarView(controller: state.calendar, keepsDay: true)
                } else if showDate && !state.monthOpen {
                    DatePageView(controller: state.calendar, onOpenMonth: { state.setMonthOpen(true) })
                        .transition(.opacity)
                } else {
                    CalendarView(controller: state.calendar,
                                 onShowDate: showDate ? { state.setMonthOpen(false) } : nil)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: state.monthOpen)
        }
    }

    private var standardContent: some View {
        VStack(spacing: 0) {
            if state.isDropTargeted {
                Color.clear.frame(height: metrics.closedSize.height)
                DropZonesView(zones: state.dropZones, active: state.activeDropZone)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            } else {
                if metrics.islandShaped {
                    // v459: the island has no buttons inside it (they sit just outside its sides): only a small top inset.
                    Color.clear.frame(height: NotchMetrics.islandTopInset)
                } else {
                    header
                        .frame(height: metrics.closedSize.height)
                        .transition(.opacity)
                }
                ZStack(alignment: .top) {
                    Group {
                        if state.showsMirror {
                            MirrorView(controller: state.mirror, rectangular: state.isDuoSized)
                                .opacity(state.mirrorClosing ? 0 : 1)
                                .scaleEffect(state.mirrorClosing ? 0.82 : 1)
                                .blur(radius: state.mirrorClosing ? 6 : 0)
                                .animation(.easeIn(duration: 0.14), value: state.mirrorClosing)
                        } else {
                            switch state.tab {
                            case .player:
                                PlayerView(media: state.media, identifier: state.identifier, levels: state.audio.level, active: expanded)
                            case .tray:
                                TrayView(tray: state.tray, isDropTargeted: state.isDropTargeted, roomy: state.isDuoSized)
                            case .calendar:
                                // Full-page tab: drawn by fullBleedPage, never here.
                                EmptyView()
                            case .duo:
                                // Fixed size so the page never squeezes while the notch morphs to the Mirror.
                                DuoView(media: state.media,
                                        identifier: state.identifier,
                                        calendar: state.calendar,
                                        levels: state.audio.level,
                                        active: expanded,
                                        onOpenMonth: openMonth)
                                    // The cover sits `duoCoverLeftGap` from the edge of the black body (which starts
                                    // `notchEarInset` inside the frame). The outer fixed frame keeps the page's reported
                                    // width as before, so the header above never widens.
                                    .frame(width: metrics.duoSize.width - 2 * (PlayerView.notchEarInset + PlayerView.duoCoverLeftGap),
                                           height: metrics.duoPageHeight,
                                           alignment: .top)
                                    .frame(width: metrics.duoSize.width - 72,
                                           height: metrics.duoPageHeight,
                                           alignment: .top)
                            case .zen:
                                ZenSpaceView(timer: state.focus, clipboard: state.clipboard,
                                             tray: state.tray, isDropTargeted: state.isDropTargeted)
                                    .frame(width: metrics.duoSize.width - 72,
                                           height: metrics.duoPageHeight,
                                           alignment: .top)
                            case .weather, .todo:
                                EmptyView()
                            }
                        }
                    }
                    .id(state.showsMirror ? "mirror" : String(describing: state.tab))
                    .transition(NotchMotion.pageTransition(move: state.pageMove))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(state.animatesPages ? NotchMotion.page : nil,
                           value: state.showsMirror ? "mirror" : String(describing: state.tab))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, state.isDuoSized ? NotchMetrics.duoBottomMargin : 16)
        .animation(.smooth(duration: 0.28), value: state.isDropTargeted)
    }

    /// True on the month calendar that Duo opens (the calendar tab only exists in Duo by way of the month name).
    private var showsDuoCalendarHeader: Bool {
        expanded && state.duoLayout && state.tab == .calendar && !state.showsMirror && !state.isDropTargeted
    }

    /// v443: the header buttons on that page, in the corners (the calendar's own text starts further in). The player button
    /// goes back to the Duo page, the camera button opens Duo's camera, the tray button only exists when the tray is not
    /// already Duo's Zen page. Nothing else changes: closing the notch and opening it again opens the Duo player.
    private var duoCalendarHeader: some View {
        HStack(spacing: 4) {
            headerButton("music.note", active: false) { selectTab(.duo) }
            Spacer(minLength: 0)
            if !state.trayInZen {
                headerButton("tray.fill", active: false) { selectTab(.tray) }
            }
            headerButton("person.crop.circle", active: false, action: mirrorButton)
        }
        // v444: the same side inset as the normal header (23 pt of ear + 13): the body of the notch / island starts 23 pt inside
        // this frame, so 14 put the buttons on the curve of the top corners. Raised 5 pt (v445, was 3), and the labels
        // under them move down (CalendarView.clearance), so the icons never touch the TUE / NOV labels.
        .padding(.horizontal, 36)
        .offset(y: -5)
    }

    /// How close (in points) the pointer must come to a header button for the buttons to appear.
    private static let revealRadius: CGFloat = 44

    /// True when the pointer is inside a circle around one of the buttons (point in the header's own coordinates).
    private func isNearHeaderButton(_ point: CGPoint, width: CGFloat) -> Bool {
        let y = metrics.closedSize.height / 2
        let centers: [CGFloat] = [13, 43, width - 13]
        return centers.contains { hypot(point.x - $0, point.y - y) <= Self.revealRadius }
    }

    private func setPointerAtTop(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            pointerAtTop = true
        } else {
            // A short grace period, so grazing the edge of the strip does not make the buttons flicker.
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                pointerAtTop = false
            }
        }
    }

    /// Left and right halves flank the physical notch; the middle is left empty.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                // The player button and the camera button are always there, whatever the Zen page is.
                headerButton("music.note", active: !state.showsMirror && (state.tab == .player || state.tab == .duo)) {
                    selectTab(idleActivity == "duo" ? .duo : .player)
                }
                // In Duo with the file tray chosen as the Zen page, the tray is that page: no button of its own.
                if !(state.duoLayout && zenMode == "tray") {
                    headerButton("tray.fill", active: !state.showsMirror && state.tab == .tray) {
                        selectTab(.tray)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: metrics.closedSize.width)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                // The camera button works the same in Duo: it opens the camera, pressed again it goes back.
                headerButton("person.crop.circle", active: state.showsMirror, action: mirrorButton)
            }
            .frame(maxWidth: .infinity)
        }
        // All buttons share one reveal: they fade, unblur and settle in together.
        .opacity(headerRevealed ? 1 : 0)
        .blur(radius: headerRevealed ? 0 : 5)
        .scaleEffect(headerRevealed ? 1 : 0.86, anchor: .top)
        .offset(y: headerRevealed ? 0 : -3)
        .allowsHitTesting(headerRevealed)
        .animation(headerRevealed ? .smooth(duration: 0.32) : .easeIn(duration: 0.22), value: headerRevealed)
        // The buttons appear when the pointer comes within a round area around them (not along the whole strip).
        .background(alignment: .top) {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            setPointerAtTop(isNearHeaderButton(point, width: geo.size.width))
                        case .ended:
                            setPointerAtTop(false)
                        }
                    }
            }
            .frame(height: metrics.closedSize.height + 44)
        }
        .onChange(of: expanded) { _, isOpen in
            if !isOpen {
                hideTask?.cancel()
                pointerAtTop = false
                hoveredButton = nil
            }
        }
    }

    /// Selected button: a darker shade on glass; on the black notch (where dark would not show) a soft light one.
    private func activeButtonFill(_ active: Bool, hovered: Bool = false) -> Color {
        guard active else { return hovered ? Color.white.opacity(0.10) : Color.clear }
        if liquidGlass || translucentNotch { return Color.black.opacity(0.4) }
        return Color.white.opacity(0.18)
    }

    private func headerButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(active ? 1 : 0.7))
                .frame(width: 26, height: 26)
                .background(Circle().fill(activeButtonFill(active, hovered: hoveredButton == symbol)))
                .contentShape(Rectangle())
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: active)
                .animation(.easeOut(duration: 0.16), value: hoveredButton)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.86))
        .onHover { inside in
            if inside {
                hoveredButton = symbol
            } else if hoveredButton == symbol {
                hoveredButton = nil
            }
        }
    }
}

/// Blur + fade used when the closed notch's activity content appears or disappears.
struct ClosedContentFade: ViewModifier {
    /// 0 = fully shown, 1 = hidden.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: 7 * amount)
            .opacity(1 - amount)
    }
}

/// Vertical moves: gentle slide + fade. Horizontal moves (Calendar, Weather, To-Do): the same
/// scale-from-the-top + blur-clearing reveal the notch uses when it opens.
struct PageSlide: Transition {
    /// Direction the pages travel: (0, 1) = down, (1, 0) = right.
    let move: CGSize

    private var isReveal: Bool { move.height == 0 }

    @ViewBuilder
    func body(content: Content, phase: TransitionPhase) -> some View {
        let appearing = isAppearing(phase)
        let hidden = !phase.isIdentity
        let offset = isReveal ? CGSize.zero : slideOffset(for: phase)
        let scale: CGFloat = hidden ? (isReveal ? (appearing ? NotchMotion.hiddenScale : 0.96) : 0.94) : 1
        // v412: a blur over the whole page is recomputed on every frame of the move; smaller radii look the same
        // at this size and keep the frames steady.
        let blur: CGFloat = hidden ? (isReveal ? (appearing ? min(NotchMotion.hiddenBlur, 9) : 5) : 6) : 0
        content
            .compositingGroup()
            .offset(x: offset.width, y: offset.height)
            .scaleEffect(scale, anchor: .top)
            .blur(radius: blur)
            .opacity(hidden ? 0 : 1)
    }

    private func isAppearing(_ phase: TransitionPhase) -> Bool {
        switch phase {
        case .willAppear: return true
        default: return false
        }
    }

    private func slideOffset(for phase: TransitionPhase) -> CGSize {
        switch phase {
        case .willAppear: return CGSize(width: -move.width * 20, height: -move.height * 16)
        case .identity: return .zero
        case .didDisappear: return CGSize(width: move.width * 20, height: move.height * 16)
        }
    }
}
