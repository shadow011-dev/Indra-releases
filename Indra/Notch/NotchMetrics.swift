import AppKit

/// All notch geometry in points. Closed size is read from the screen, never hard-coded.
struct NotchMetrics: Equatable {
    var closedSize: CGSize
    var expandedSize: CGSize
    var mirrorSize: CGSize
    var dropSize: CGSize
    var calendarSize: CGSize
    var duoSize: CGSize
    /// Share of the Duo page taken by the player (the rest is the calendar).
    static let duoPlayerFraction: CGFloat = 0.5
    /// Transparent margin left/right/bottom of the expanded notch (room for the shadow).
    var windowPadding: CGFloat
    /// Extra hover margin left/right of the closed notch.
    var hoverPadding: CGFloat
    /// Width added on each side of the closed notch while an idle activity is shown.
    var idleSlot: CGFloat
    /// Narrower slot used by the now-playing activity: the closed notch is about 240 pt wide.
    var compactSlot: CGFloat
    /// Width added on each side of the closed notch while a volume / brightness overlay is shown.
    var hudSlot: CGFloat
    /// v394: True when the notch is drawn as a floating island on an external monitor (no physical notch there).
    var island: Bool = false
    /// v438: the external monitor's notch drawn exactly like the MacBook's physical notch (Settings > External Notch >
    /// Style). It is still the second notch (it keeps its own settings), but its geometry is the notch's.
    var notchLook: Bool = false
    /// True for the floating pill: an island that does not take the notch's look.
    var islandShaped: Bool { island && !notchLook }

    /// Gap between the top edge of an external monitor and the island, like the Dynamic Island's.
    static let islandGap: CGFloat = 8
    /// The closed island: a small pill (the notch of a MacBook is about 185 x 32).
    static let islandClosedSize = CGSize(width: 92, height: 34)
    /// Empty space between the top of the screen and the top of the notch body (0 for the real notch).
    var topGap: CGFloat { islandShaped ? NotchMetrics.islandGap : 0 }

    // v459: the floating island has no header buttons inside it: they are round buttons just outside its sides.
    /// Space kept above a page where the header row used to be (the row itself is gone on the island).
    static let islandTopInset: CGFloat = 12
    /// Diameter of the round buttons beside the island and the gap between them and the island's edge.
    static let islandButtonSize: CGFloat = 40
    static let islandButtonGap: CGFloat = 8
    /// Extra window width on each side of the open island, so the buttons (and the pointer on them) stay inside the window.
    static let islandSideExtra: CGFloat = 0   // v464: the buttons beside the island are gone
    /// How far the open island's body sits inside its layout frame (the notch's ear inset).
    static let islandBodyInset: CGFloat = 23
    var sideExtra: CGFloat { islandShaped ? NotchMetrics.islandSideExtra : 0 }
    /// What the open island is shorter by on a page that has the header row (the row is replaced by a small top inset).
    var islandHeaderSaving: CGFloat { islandShaped ? max(0, closedSize.height - NotchMetrics.islandTopInset) : 0 }

    /// Height left for a Duo-sized page under the header row (the bottom margin is 12 pt).
    var duoPageHeight: CGFloat { duoSize.height - closedSize.height - NotchMetrics.duoBottomMargin }

    /// Margin under the page in a Duo-sized notch (the Duo cover sits a little lower, see `PlayerView.duoCoverBottomGap`).
    static let duoBottomMargin: CGFloat = 12

    /// Weather, To-do and Reminders in Duo: as wide as Duo and taller than the standard page, so their text and
    /// pictures are drawn at full size (the short Duo height shrank them to about three quarters).
    var duoLargeSize: CGSize {
        CGSize(width: duoSize.width,
               height: max(expandedSize.height, duoSize.height + 48, calendarSize.height))
    }

    /// The Duo camera page while the camera is on: same width as Duo, but extended downwards so the
    /// 16:9 camera box is large enough to see (the short Duo height left it only about 160 pt wide).
    var duoMirrorSize: CGSize {
        CGSize(width: duoSize.width, height: max(duoSize.height + 104, duoLargeSize.height))
    }

    var expandedWindowSize: CGSize {
        CGSize(width: max(expandedSize.width, duoSize.width) + windowPadding * 2 + sideExtra * 2,
               height: max(expandedSize.height, duoSize.height, duoLargeSize.height, duoMirrorSize.height) + windowPadding)
    }

    // v530: the intro animation. The notch opens in the shape of the normal (non-Duo) open notch, sized for the video: a
    // little wider than it, with the usual side inset (23 pt of ear + 13) and the camera housing's height above it.
    /// The video's picture is drawn this wide, at the video's own proportions (IndraIntro.mp4 is 1100 x 856).
    static let introVideoWidth: CGFloat = 330
    static let introVideoAspect: CGFloat = 1100.0 / 856.0
    static let introSideInset: CGFloat = 36
    static let introBottomInset: CGFloat = 18

    var introVideoSize: CGSize {
        CGSize(width: NotchMetrics.introVideoWidth,
               height: (NotchMetrics.introVideoWidth / NotchMetrics.introVideoAspect).rounded())
    }

    /// Space above the picture: the camera housing (the floating island has none, only its small top inset).
    var introTopInset: CGFloat { islandShaped ? NotchMetrics.islandTopInset : closedSize.height }

    /// The open notch while the intro plays.
    var introSize: CGSize {
        CGSize(width: introVideoSize.width + NotchMetrics.introSideInset * 2,
               height: introTopInset + introVideoSize.height + NotchMetrics.introBottomInset)
    }

    /// The window while the intro plays: never smaller than the normal open window, so nothing is clipped.
    var introWindowSize: CGSize {
        let page = expandedWindowSize
        return CGSize(width: max(page.width, introSize.width + windowPadding * 2 + sideExtra * 2),
                      height: max(page.height, introSize.height + windowPadding))
    }

    var mirrorWindowSize: CGSize {
        CGSize(width: mirrorSize.width + windowPadding * 2 + sideExtra * 2,
               height: mirrorSize.height + windowPadding)
    }

    /// Wide and short; tall enough to cover any other open size so nothing is clipped.
    var dropWindowSize: CGSize {
        CGSize(width: dropSize.width + windowPadding * 2,
               height: max(dropSize.height, mirrorSize.height) + windowPadding)
    }

    /// Notch-style volume / brightness overlay that hangs below the notch.
    var hudDownlineSize: CGSize {
        // v436: the island (external monitor) has a small pill instead of a camera housing, so sizing the card from the
        // pill made it much narrower than the MacBook notch's cascade card. It now takes the MacBook notch's size.
        if islandShaped {
            let reference = NotchMetrics.make(for: NotchMetrics.notchScreen(), island: false)
            return CGSize(width: reference.closedBodySize(slot: reference.compactSlot).width + 36,
                          height: closedSize.height + 64)
        }
        // Exactly as wide as the closed notch with a live activity (artwork + visualizer).
        return CGSize(width: closedBodySize(slot: compactSlot).width + 36, height: closedSize.height + 64)
    }

    /// Notch-style Bluetooth card: the usual row (picture left, dot right) with the device's name centred in a
    /// short strip hanging below the notch.
    func bluetoothDownlineSize(slot: CGFloat) -> CGSize {
        CGSize(width: max(closedBodySize(slot: slot).width, hudDownlineSize.width), height: closedSize.height + 38)
    }

    /// The song-change card: a little wider than the closed notch with its artwork and visualizer (18 pt each side),
    /// so those sit inside the rounded corners of the card, with a strip below for the title and artist.
    func songDownlineSize(slot: CGFloat) -> CGSize {
        CGSize(width: closedBodySize(slot: slot).width + 36, height: closedSize.height + 38)
    }

    func closedBodySize(slot: CGFloat) -> CGSize {
        // The top ears of a widened notch (8 pt each) sit outside the activity content.
        CGSize(width: closedSize.width + slot * 2 + (slot > 0 ? 16 : 0), height: closedSize.height)
    }

    func closedWindowSize(slot: CGFloat) -> CGSize {
        let body = closedBodySize(slot: slot)
        return CGSize(width: body.width + hoverPadding * 2, height: body.height)
    }

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The display number of a screen (nil when it cannot be read).
    static func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// True for the MacBook's own display.
    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    /// The first external monitor (the one nearest the menu bar when there are several).
    static func externalScreen() -> NSScreen? {
        NSScreen.screens.first { !isBuiltIn($0) }
    }

    /// The screen the notch window lives on: the external monitor when "External monitor" is on and one is
    /// connected, otherwise the notch screen. (The lock screen and everything else keep using `notchScreen()`.)
    static func hostScreen() -> NSScreen? {
        // v429: the MacBook's own notch always stays where it is. Only when no screen with a notch is connected (the lid
        // is closed) does the external monitor take over its role, drawn as the island.
        if !hasNotchScreen, Preferences.externalMonitor, let external = externalScreen() { return external }
        return notchScreen()
    }

    /// True while a screen with a camera housing (the MacBook's own display, lid open) is connected.
    static var hasNotchScreen: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// v429: the screen of the SECOND notch, the floating island: the external monitor when "External monitor" is on and a
    /// MacBook screen with its own notch is also connected. Both then work on their own. Nil when there is no second one.
    static func islandScreen() -> NSScreen? {
        guard Preferences.externalMonitor, hasNotchScreen else { return nil }
        return externalScreen()
    }

    /// The island look is used only when the setting is on and the host screen is not the MacBook's own display.
    static func usesIsland(on screen: NSScreen?) -> Bool {
        guard Preferences.externalMonitor, let screen else { return false }
        return !isBuiltIn(screen)
    }

    static func make(for screen: NSScreen?, island forcedIsland: Bool? = nil) -> NotchMetrics {
        let island = forcedIsland ?? usesIsland(on: screen)
        // v438: with the notch look the external notch is measured from the MacBook's own notch screen, so every size
        // (closed notch, activity row, Duo, volume card) is exactly the MacBook notch's.
        let notchLook = island && Preferences.islandNotchLook
        let shaped = island && !notchLook
        let sizeScreen = notchLook ? (notchScreen() ?? screen) : screen
        var closed = CGSize(width: 190, height: 32) // fallback for screens without a notch
        if shaped {
            closed = islandClosedSize
        } else if let sizeScreen,
                  sizeScreen.safeAreaInsets.top > 0,
                  let left = sizeScreen.auxiliaryTopLeftArea,
                  let right = sizeScreen.auxiliaryTopRightArea {
            closed = CGSize(width: sizeScreen.frame.width - left.width - right.width,
                            height: sizeScreen.safeAreaInsets.top)
        }
        // Duo is the size of the reference widget: about 39.2 % of the screen's width and 9.3 % of it tall
        // (a 1470 pt wide Mac gives 576 x 136), so it looks the same on every notch Mac.
        // An external monitor can be much wider than a MacBook: the island is sized as on a 1512 pt wide Mac at most.
        let screenWidth = island ? min(sizeScreen?.frame.width ?? 1470, 1512) : (screen?.frame.width ?? 1470)
        let duo = CGSize(width: max((screenWidth * 0.392).rounded(), 520),
                         height: max((screenWidth * 0.0927).rounded(), 130))
        let width = CGFloat(Preferences.notchWidth)
        let height = CGFloat(Preferences.notchHeight)
        return NotchMetrics(closedSize: closed,
                            expandedSize: CGSize(width: width, height: height),
                            mirrorSize: CGSize(width: width, height: 240),
                            dropSize: CGSize(width: 520, height: 130),
                            calendarSize: CalendarLayout.size,
                            duoSize: duo,
                            windowPadding: 24,
                            hoverPadding: 8,
                            idleSlot: shaped ? 38 : 40,
                            // v429: the island has no camera housing in its middle, so its activity row is packed
                            // close (artwork and visualizer near each other) instead of spread to a 240 pt notch width.
                            compactSlot: shaped ? 40 : max((240 - closed.width) / 2, 34),
                            hudSlot: 88,
                            island: island,
                            notchLook: notchLook)
    }
}
