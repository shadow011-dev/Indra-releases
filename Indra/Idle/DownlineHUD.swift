import SwiftUI

/// Volume / brightness overlay that hangs below the notch: icon top left, percentage above the
/// bar (it follows the filled end), then the bar. Volume uses ticks, brightness a smooth line.
/// The three rows arrive one after another; ticks near the filled end swell like a wave.
/// With Settings > Volume & Brightness > Animation set to Inline, the card keeps its place below the notch but shows
/// the inline layout's slim icon and bar with the inline motion instead.
struct DownlineHUDView: View {
    let kind: HUDKind
    let value: Double
    let muted: Bool
    let tint: Color
    let notchHeight: CGFloat
    @Environment(\.hudGradient) private var gradient
    @State private var shown = false

    /// The panel's top corners curve outward, so the visible body is narrower than its frame:
    /// keep the icon well inside it.
    private static let edge: CGFloat = 32
    private static let iconWidth: CGFloat = 20
    private static let gap: CGFloat = 6
    /// Distance from the panel edge to the start (and end) of the bar.
    private static let sideInset: CGFloat = edge + iconWidth + gap

    private var level: Double { muted ? 0 : min(max(value, 0), 1) }

    private var symbol: String {
        switch kind {
        case .brightness: return "sun.max"
        default: return kind.appleSymbol(value: value, muted: muted)
        }
    }

    /// Settings > Volume & Brightness > Animation: the downline card plays the inline layout's look and motion.
    @AppStorage(Preferences.sensoryDownlineMotionKey) private var mainMotion = "downline"
    @AppStorage(Preferences.islandSensoryDownlineMotionKey) private var islandMotion = ""
    @Environment(\.notchIsland) private var island

    private var motion: String { Preferences.pick(mainMotion, islandMotion, island: island) }

    var body: some View {
        if motion == "inline" {
            inlineBody
        } else {
            downlineBody
        }
    }

    /// The inline layout hung below the notch: the same slim icon and rounded bar the closed notch shows beside the
    /// camera housing, in one calm row, with the inline motion (the icon bounces, the bar springs to the level; no
    /// row-by-row drop-in). The card itself keeps its place and size below the notch.
    @AppStorage(Preferences.sensoryPercentKey) private var showsPercent = false
    /// v467: the number always sits beside the bar (the Position setting is gone).
    private let percentPlace = "bar"

    private var inlineBody: some View {
        GeometryReader { geo in
            // Same geometry as the downline card: the bar has the same width and sits in the exact middle of the
            // panel (an empty slot of the icon's width on the right balances the icon on the left), on the same row.
            // v429: with the percentage beside the icon, both side slots grow by the room it needs and the bar gets
            // that much shorter, so the bar stays in the middle.
            let extra: CGFloat = (showsPercent && percentPlace == "icon") ? 38 : 0
            // v434: with the number beside the bar, both side cells have the same width (icon hugging the bar on the left, the
            // number hugging it on the right), so the whole row (icon, bar, number) sits in the exact middle of the card.
            let numberBesideBar = showsPercent && percentPlace == "bar"
            // v438: with the number beside the bar, the icon cell and the number cell are as wide as what they hold, so the
            // whole row (icon, bar, number) has the same room on both sides: it sits in the exact middle of the card.
            let iconCell = DownlineHUDView.iconWidth
            let numberCell: CGFloat = 36
            let sideWidth = numberBesideBar ? iconCell : DownlineHUDView.iconWidth + extra
            let barWidth = numberBesideBar
                ? geo.size.width - DownlineHUDView.edge * 2 - iconCell - numberCell - DownlineHUDView.gap * 2
                : geo.size.width - DownlineHUDView.edge * 2 - sideWidth * 2 - DownlineHUDView.gap * 2
            HStack(spacing: DownlineHUDView.gap) {
                InlineHUDIcon(symbol: kind.notchSymbol(value: value, muted: muted), value: level, tint: tint)
                    .frame(width: sideWidth, height: 22, alignment: numberBesideBar ? .trailing : .leading)
                if numberBesideBar {
                    // v517: the bar is drawn `inlineBarLengthExtra` longer than the width it is given, so it used to overflow its
                    // slot and touch the icon and the number. It is now shorter than the slot by that much plus 16 pt, which
                    // leaves 8 pt of room on each side.
                    HUDBar(value: level, tint: tint, width: max(barWidth - Preferences.inlineBarLengthExtra - 16, 30))
                        .frame(width: barWidth, height: 24)
                    InlinePercentText(value: level, tint: tint)
                        .frame(width: numberCell, height: 22, alignment: .leading)
                } else {
                    InlineHUDLevel(value: level, tint: tint, barWidth: max(barWidth - Preferences.inlineBarLengthExtra - 16, 30))
                        .frame(width: barWidth, height: 24)
                    Color.clear.frame(width: sideWidth, height: 22)
                }
            }
            .frame(width: geo.size.width - DownlineHUDView.edge * 2, height: 24)
            // v491: the row waits until the card has opened (it used to be drawn at once, while the card was still
            // growing downwards, so the bar showed cut in half), then fades and settles in.
            .reveal(shown, delay: 0.16)
            // v438: in the middle of the card below the notch (it sat low, near the bottom edge).
            .position(x: geo.size.width / 2, y: notchHeight + (geo.size.height - notchHeight) / 2)
        }
        .onAppear { shown = true }
    }

    private var downlineBody: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width - DownlineHUDView.sideInset * 2
            let fillEnd = DownlineHUDView.sideInset + barWidth * CGFloat(level)
            let labelX = min(max(fillEnd, DownlineHUDView.sideInset + 22), geo.size.width - DownlineHUDView.sideInset - 22)
            ZStack(alignment: .topLeading) {
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.62))
                    .contentTransition(.numericText(value: level * 100))
                    .position(x: labelX, y: notchHeight + 21)
                    .reveal(shown, delay: 0.04)
                // Icon, bar, and an empty slot of the icon's width so the bar sits in the middle.
                HStack(spacing: DownlineHUDView.gap) {
                    HUDSymbol(symbol: symbol, value: level, size: 17, weight: .regular)
                        .foregroundStyle(tint)
                        .frame(width: DownlineHUDView.iconWidth, height: 22)
                        .reveal(shown, delay: 0)
                    bar(width: barWidth)
                        .frame(width: barWidth, height: 24)
                        .reveal(shown, delay: 0.08)
                    Color.clear.frame(width: DownlineHUDView.iconWidth, height: 22)
                }
                .frame(width: geo.size.width - DownlineHUDView.edge * 2, height: 24)
                .position(x: geo.size.width / 2, y: notchHeight + 43)
            }
            // v462: no overshoot. The bar and the number follow the level smoothly, also while the key is held (an
            // underdamped spring wobbled and lagged behind every new level).
            .animation(.spring(response: 0.24, dampingFraction: 1.0), value: level)
        }
        .onAppear { shown = true }
    }

    /// v454: the album gradient of the slider (the plain tint when the cover has none).
    private var barFill: LinearGradient {
        // v458: dark at the start, light at the tip.
        let colors = (gradient?.count ?? 0) > 1 ? Array(gradient!.reversed()) : [tint, tint]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        if kind == .volume {
            TickBar(level: level, width: width,
                    colors: (gradient?.count ?? 0) > 1 ? Array(gradient!.reversed()) : nil,
                    tint: tint)
        } else {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                Capsule()
                    .fill(barFill)
                    .frame(width: max(4, width * CGFloat(level)), height: 4)
                    .shadow(color: tint.opacity(0.55), radius: 3)
            }
        }
    }
}

private extension View {
    /// Fades, drops in and unblurs after `delay`, once `shown` turns true.
    func reveal(_ shown: Bool, delay: Double) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -8)
            .blur(radius: shown ? 0 : 5)
            .animation(.spring(response: 0.42, dampingFraction: 0.82).delay(delay), value: shown)
    }
}


/// The card that hangs under the OPEN notch (any page, Duo included) while the volume or brightness changes, a
/// Bluetooth device connects or disconnects, or the charger is plugged in. The notch body simply grows downward
/// to hold it, so it reads as one piece with the notch.
struct ExpandedStripView: View {
    let activity: LiveActivity
    let tint: Color
    @AppStorage(Preferences.bluetoothEarbudStyleKey) private var earbudStyle = "pro"
    @Environment(\.notchIsland) private var island

    var body: some View {
        // v479: the faint separator line between the page and the card is gone.
        ZStack(alignment: .top) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch activity {
        case .hud(let kind, let value, let muted):
            if Preferences.sensoryLayout(island: island) == "inline" {
                InlineHUDStrip(kind: kind, value: value, muted: muted, tint: tint)
            } else {
                DownlineHUDView(kind: kind, value: value, muted: muted, tint: tint, notchHeight: 0)
            }
        case .battery(let percent, let charging, let pluggedIn):
            BatteryStrip(percent: percent, charging: charging, pluggedIn: pluggedIn)
                .id("\(percent)-\(charging)-\(pluggedIn)")
        case .bluetooth(let name, let kind, let connected):
            BluetoothStrip(name: name, kind: kind, connected: connected, style: earbudStyle)
                .id("\(kind.rawValue)-\(connected)-\(name)")
        case .task(let kind, let title, let detail):
            TaskStrip(kind: kind, title: title, detail: detail)
                .id("\(kind.rawValue)|\(title)|\(detail)")
        case .lock, .song, .update:
            EmptyView()
        }
    }
}

private struct BatteryStrip: View {
    let percent: Int
    let charging: Bool
    let pluggedIn: Bool
    @State private var shown = 0

    private var title: String {
        if charging || pluggedIn { return percent >= 100 ? "Fully charged" : "Charging" }
        if percent <= 10 { return "Battery very low" }
        return percent <= 20 ? "Low battery" : "On battery"
    }

    var body: some View {
        HStack(spacing: 14) {
            BatteryGlyph(percent: percent, charging: charging)
                .scaleEffect(1.3)
                .frame(width: 38, height: 20)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
            Spacer(minLength: 0)
            Text("\(shown)%")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(!charging && percent <= 10 ? Color.red : Color.white)
                .contentTransition(.numericText(value: Double(shown)))
        }
        .padding(.horizontal, 46)
        .padding(.top, 2)
        .frame(maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { shown = percent }
        }
    }
}

private struct BluetoothStrip: View {
    let name: String
    let kind: BluetoothKind
    let connected: Bool
    let style: String

    var body: some View {
        HStack(spacing: 12) {
            BluetoothGlyph(kind: kind, style: style, size: 36)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? kind.appleName : name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(connected ? "Connected" : "Disconnected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            BluetoothDot(connected: connected)
        }
        .padding(.horizontal, 46)
        .padding(.top, 2)
        .frame(maxHeight: .infinity)
    }
}

/// "Inline" layout while the notch is open: the same icon and slim bar the closed notch shows beside the camera
/// housing, as a calm row in the strip under the open notch.
private struct InlineHUDStrip: View {
    let kind: HUDKind
    let value: Double
    let muted: Bool
    let tint: Color
    @AppStorage(Preferences.sensoryPercentKey) private var showsPercent = false
    /// v467: the number always sits beside the bar (the Position setting is gone).
    private let place = "bar"

    /// v431: both side cells have the same width, so the bar (and with it the whole row) is exactly in the middle.
    private var side: CGFloat { showsPercent && place != "above" ? 60 : 24 }

    var body: some View {
        let level = muted ? 0 : value
        // v517: 16 pt between the icon, the bar and the number (it was 8), and the bar keeps its 170 pt total length.
        HStack(spacing: 16) {
            InlineHUDIcon(symbol: kind.notchSymbol(value: value, muted: muted), value: level, tint: tint)
                .frame(width: side, alignment: .trailing)
            if showsPercent && place == "above" {
                InlineHUDLevel(value: level, tint: tint, barWidth: 170 - Preferences.inlineBarLengthExtra)
            } else {
                HUDBar(value: level, tint: tint, width: 170 - Preferences.inlineBarLengthExtra)
            }
            Group {
                if showsPercent && place == "bar" {
                    InlinePercentText(value: level, tint: tint)
                } else {
                    Color.clear
                }
            }
            .frame(width: side, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}


/// v462: the volume ticks as one animatable view. Its level is interpolated on every frame of the animation, so the fill
/// edge slides across the ticks (the tick at the edge fills in part by part) and the wave of taller ticks travels with it,
/// instead of every tick switching on its own while the heights ease.
private struct TickBar: View, Animatable {
    var level: Double
    let width: CGFloat
    let colors: [Color]?
    let tint: Color

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let count = max(16, Int(width / 6.3))
            let cell = size.width / CGFloat(count)
            let tickWidth = cell * 0.56
            let edge = level * Double(count)
            for index in 0..<count {
                // Ticks close to the filled end are taller: a small wave that travels with the level.
                let boost = max(0, 1 - abs(Double(index) + 0.5 - edge) / 3.5)
                let height = 13 + 7 * CGFloat(boost)
                let rect = CGRect(x: CGFloat(index) * cell + (cell - tickWidth) / 2,
                                  y: (size.height - height) / 2,
                                  width: tickWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: tickWidth / 2)
                context.fill(path, with: .color(Color.white.opacity(0.22)))
                let filled = min(max(edge - Double(index), 0), 1)
                if filled > 0 {
                    let color: Color
                    if let colors, count > 1 {
                        color = ArtworkPalette.sample(colors, at: Double(index) / Double(count - 1))
                    } else {
                        color = tint
                    }
                    context.fill(path, with: .color(color.opacity(filled)))
                }
            }
        }
        .frame(width: width, height: 24)
    }
}
