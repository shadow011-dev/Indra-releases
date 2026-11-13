import SwiftUI

/// What the closed notch shows beside the camera housing.
enum IdleMode: String {
    case none
    case playing
    case calendar
    case duo

    var isVisible: Bool { self != .none }
    var showsMedia: Bool { self == .playing || self == .duo }
    var showsDate: Bool { self == .calendar || self == .duo }
}

/// Small live activity at both sides of the closed notch (artwork / date on the left,
/// level bars on the right). Fixed layout: [slot][notch][slot].
struct IdleActivityView: View {
    let mode: IdleMode
    let live: LiveActivity?
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarController
    let levels: SmoothedLevel
    let notchWidth: CGFloat
    let slot: CGFloat
    /// True only while the notch is closed; stops the bar animation otherwise.
    let active: Bool
    /// v429: drawn on the floating island of an external monitor: its rounded ends need more room at the sides.
    var island = false
    /// v553: a new version is ready and nothing else is on the closed notch: the update symbol takes the visualizer's place.
    var updateBadge = false
    @AppStorage(Preferences.accentVisualizerKey) private var accentVisualizer = true
    @AppStorage(Preferences.sensoryColorModeKey) private var colorMode = ""
    @AppStorage(Preferences.sensoryLabelKey) private var labelStyle = "icon"
    @AppStorage(Preferences.visualizerStyleKey) private var mainVisualizerStyle = "waveform"
    @AppStorage(Preferences.islandVisualizerStyleKey) private var islandVisualizerStyle = ""
    @AppStorage(Preferences.bluetoothEarbudStyleKey) private var earbudStyle = "pro"

    private var visualizerStyle: String { Preferences.pick(mainVisualizerStyle, islandVisualizerStyle, island: island) }

    var body: some View {
        HStack(spacing: 0) {
            leftSlot
                .padding(.leading, island ? (isHUD ? 14 : (live == nil ? 4 : 12)) : (isHUD ? 11 : ((compactLayout || isBattery) ? 7 : 9)))
                .frame(width: slot, alignment: .leading)
            Spacer(minLength: 0)
            rightSlot
                // v434: on the island the idle artwork and the visualizer sit near the ends, like on the Mac notch.
                .padding(.trailing, island ? (isHUD ? 14 : (live == nil ? (visualizerStyle == "circle" ? 1 : 10) : 12)) : (isHUD ? 12 : (isBattery ? 7 : (compactLayout ? (visualizerStyle == "circle" ? 4 : 9) : 9))))
                .frame(width: slot, alignment: .trailing)
        }
        // Same 26 pt row as the now-playing layout, so artwork, battery and the like line up vertically.
        .frame(width: notchWidth + slot * 2, height: 26)
        .environment(\.hudGradient, media.hudGradient(mode: Preferences.hudColorMode(colorMode)))
        // v491: the volume / brightness row waits until the notch has widened to hold it. It used to appear while the
        // notch was still opening, so the bar showed cut off at the edge of the body.
        .opacity(isHUD && !hudRevealed ? 0 : 1)
        .onAppear { startHUDReveal() }
        .onChange(of: isHUD) { _, _ in startHUDReveal() }
    }

    @State private var hudRevealed = false
    @State private var hudRevealTask: Task<Void, Never>?

    private func startHUDReveal() {
        hudRevealTask?.cancel()
        guard isHUD else { hudRevealed = false; return }
        // A bar that is already showing (a held volume key) stays as it is.
        if hudRevealed { return }
        hudRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { hudRevealed = true }
        }
    }

    private var isBattery: Bool {
        if case .battery? = live { return true }
        return false
    }

    /// Now-playing only: the compact notch with a 20 pt artwork tile and a 26 pt circle.
    private var compactLayout: Bool { live == nil && mode == .playing }

    /// Volume / brightness overlay beside the notch: icon at the far left, bar at the far right.
    private var isHUD: Bool {
        if case .hud? = live { return true }
        return false
    }

    private var visualizerTint: Color {
        if accentVisualizer, let accent = media.accentNSColor { return Color(nsColor: accent) }
        return Color.white
    }

    private var hudTint: Color {
        media.hudTint(mode: Preferences.hudColorMode(colorMode))
    }

    // MARK: - Live activities (take priority over the idle activity)

    @ViewBuilder
    private var leftSlot: some View {
        if let live {
            switch live {
            case .battery(let percent, let charging, _):
                BatteryGlyph(percent: percent, charging: charging)
                    .id("\(percent)-\(charging)")
            case .lock(let locked):
                LockBadge(locked: locked)
                    .id(locked)
            case .bluetooth(_, let kind, let connected):
                BluetoothGlyph(kind: kind, style: earbudStyle, size: 26)
                    .id("\(kind.rawValue)-\(connected)")
            case .task, .song, .update:
                EmptyView()
            case .hud(let kind, let value, let muted):
                InlineHUDIcon(symbol: kind.notchSymbol(value: value, muted: muted),
                              value: muted ? 0 : value, tint: hudTint)
            }
        } else {
            leftContent
        }
    }

    @ViewBuilder
    private var rightSlot: some View {
        if let live {
            switch live {
            case .battery(let percent, let charging, _):
                BatteryPercent(percent: percent, charging: charging)
                    .id("\(percent)-\(charging)")
            case .hud(_, let value, _):
                InlineHUDLevel(value: value, tint: hudTint)
            case .lock:
                EmptyView()
            case .bluetooth(_, _, let connected):
                BluetoothDot(connected: connected)
                    .id(connected)
            case .task, .song, .update:
                EmptyView()
            }
        } else {
            rightContent
        }
    }

    // MARK: - Slots

    @ViewBuilder
    private var leftContent: some View {
        switch mode {
        case .none:
            EmptyView()
        case .playing:
            artworkTile(size: 20)
        case .calendar:
            dateTile(size: 22)
        case .duo:
            ZStack(alignment: .leading) {
                artworkTile(size: 18)
                dateTile(size: 18).offset(x: 12)
            }
            .frame(width: 30, height: 22, alignment: .leading)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        if mode.showsMedia {
            VisualizerView(level: levels,
                           playing: media.track?.isPlaying ?? false,
                           active: active,
                           compact: true,
                           tint: visualizerTint,
                           gradient: accentVisualizer ? media.accentGradient : nil)
        } else if mode == .none && updateBadge {
            // v553: nothing is playing: the update symbol sits where the visualizer would, and the left side stays empty.
            UpdateBadgeGlyph()
        }
    }

    // MARK: - Tiles

    private func artworkTile(size: CGFloat) -> some View {
        ZStack {
            CoverCurve.shape(size)
                .fill(Color.white.opacity(0.14))
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(CoverCurve.shape(size))
    }

    private func dateTile(size: CGFloat) -> some View {
        VStack(spacing: -1) {
            Text(calendar.today.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: size * 0.29, weight: .bold))
                .foregroundStyle(Color.red)
            Text("\(Calendar.current.component(.day, from: calendar.today))")
                .font(.system(size: size * 0.54, weight: .bold))
                .foregroundStyle(Color.black)
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Color.white))
    }
}

// MARK: - Battery

private func batteryTint(percent: Int, charging: Bool) -> Color {
    if charging { return Color(red: 0.41, green: 0.81, blue: 0.40) }
    return percent <= 10 ? Color.red : Color.white
}

/// Battery drawn by hand as a solid body: the level is bright, the rest is the same colour dimmed, with a small
/// terminal. Green while charging, white on battery (red when nearly empty). The level fills in when it appears.
struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    @State private var fill: CGFloat = 0
    @State private var pulse = false

    private var tint: Color { batteryTint(percent: percent, charging: charging) }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                tint.opacity(0.36)
                tint
                    .frame(width: max(2, 24 * fill))
            }
            .frame(width: 24, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3.8, style: .continuous))
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint.opacity(0.36))
                .frame(width: 1.8, height: 4.8)
        }
        .shadow(color: charging ? tint.opacity(pulse ? 0.75 : 0.15) : Color.clear,
                radius: pulse ? 6 : 2)
        .onAppear {
            fill = 0
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                fill = CGFloat(percent) / 100
            }
            if charging, !NotchMotion.stillLoops {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}

/// Percentage that counts up to its value.
struct BatteryPercent: View {
    let percent: Int
    let charging: Bool
    @State private var shown = 0

    var body: some View {
        Text("\(shown)%")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            // The icon turns green while charging; the number stays white (red only when nearly empty).
            .foregroundStyle(!charging && percent <= 10 ? Color.red : Color.white)
            .contentTransition(.numericText(value: Double(shown)))
            .onAppear {
                withAnimation(.easeOut(duration: 0.7)) {
                    shown = percent
                }
            }
    }
}

// MARK: - Lock

/// Shackle of the padlock: two legs joined by an arch.
private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let k: CGFloat = 0.5523
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + radius - k * radius),
                      control2: CGPoint(x: rect.minX + radius - k * radius, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                      control1: CGPoint(x: rect.minX + radius + k * radius, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + radius - k * radius))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// A padlock drawn by hand: closed, or with the shackle swung open.
private struct Padlock: View {
    let closed: Bool

    var body: some View {
        ZStack {
            Shackle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                .frame(width: 8.4, height: 7.5)
                .rotationEffect(.degrees(closed ? 0 : 32), anchor: UnitPoint(x: 0, y: 1))
                .offset(x: closed ? 0 : 1, y: closed ? -5.6 : -7.2)
            RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                .fill(Color.white)
                .frame(width: 13, height: 9.5)
                .offset(y: 1.8)
        }
        .frame(width: 16, height: 18)
    }
}

/// Round badge: the padlock closes when you lock the Mac and swings open when you unlock it.
private struct LockBadge: View {
    let locked: Bool
    @State private var showsClosed: Bool
    @State private var appeared = false

    init(locked: Bool) {
        self.locked = locked
        _showsClosed = State(initialValue: !locked)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 22, height: 22)
            Padlock(closed: showsClosed)
                .scaleEffect(0.8)
        }
        .frame(width: 22, height: 22)
        .scaleEffect(appeared ? 1 : 0.5)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                appeared = true
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) {
                    showsClosed = locked
                }
            }
        }
    }
}

// MARK: - Volume / brightness bar

/// v454: the album gradient of the slider, for the volume / brightness bars. Set where a HUD is drawn; nil = one tint.
private struct HUDGradientKey: EnvironmentKey {
    static let defaultValue: [Color]? = nil
}

extension EnvironmentValues {
    var hudGradient: [Color]? {
        get { self[HUDGradientKey.self] }
        set { self[HUDGradientKey.self] = newValue }
    }
}

extension MediaController {
    /// v456: the bar of the volume / brightness HUDs: the slider's album gradient in "album" mode, nil otherwise.
    func hudGradient(mode: String) -> [Color]? {
        mode == "album" ? accentGradient : nil
    }

    var hudGradientForHUD: [Color]? { hudGradient(mode: Preferences.sensoryColorMode) }

    /// The colour of the HUD's icon and number: album = the first colour of the slider gradient (the plain accent when
    /// the cover has none), system = the Mac's accent colour, none = white.
    func hudTint(mode: String) -> Color {
        switch mode {
        case "album":
            if let first = accentGradient?.first { return first }
            if let accent = accentNSColor { return Color(nsColor: accent) }
            return Color.white
        case "system":
            return Color(nsColor: .controlAccentColor)
        default:
            return Color.white
        }
    }

    var hudTintForHUD: Color { hudTint(mode: Preferences.sensoryColorMode) }
}

struct HUDBar: View {
    let value: Double
    let tint: Color
    var width: CGFloat = 73
    @Environment(\.hudGradient) private var gradient
    var body: some View {
        let height = Preferences.inlineBarHeight
        let length = width + Preferences.inlineBarLengthExtra
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: (gradient?.count ?? 0) > 1 ? Array(gradient!.reversed()) : [tint.opacity(0.7), tint],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(height - 1, geometry.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(width: length, height: height)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: value)
    }
}
