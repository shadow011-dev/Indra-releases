import SwiftUI

/// Duo's Zen space: a calm page that shows a Pomodoro focus session, the clipboard manager or the file tray.
/// Which one is chosen in Settings > Media > Zen space.
struct ZenSpaceView: View {
    @ObservedObject var timer: FocusTimer
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var tray: TrayStore
    let isDropTargeted: Bool
    @AppStorage(Preferences.zenModeKey) private var mainMode = Preferences.defaultZenMode
    @AppStorage(Preferences.islandZenModeKey) private var islandMode = ""
    @Environment(\.notchIsland) private var island

    private var mode: String { Preferences.pick(mainMode, islandMode, island: island) }

    var body: some View {
        ZStack {
            if mode == "clipboard" {
                ClipboardPane(store: clipboard)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else if mode == "tray" {
                TrayView(tray: tray, isDropTargeted: isDropTargeted, roomy: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                FocusPane(timer: timer)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: mode)
        .padding(.top, 2)
    }
}

// MARK: - Focus (Pomodoro)

/// The focus page of the Zen space. Left: Focus / Break switch with the session count, a ruler of minutes you
/// drag to set the length, and the Start button. Right: a ring that fills as the session goes on, with the time
/// in its middle. While a session runs the notch folds away and a glowing line under it shows the same progress.
private struct FocusPane: View {
    @ObservedObject var timer: FocusTimer
    @AppStorage(Preferences.timerSoundKey) private var sound = true
    @Environment(\.notchIsland) private var island
    @Namespace private var tabSpace
    /// When Start was pressed; the ring plays its ignition from this moment (nil when idle).
    @State private var igniteAt: Date?
    @State private var pop = false


    private var tint: Color {
        switch timer.phase {
        case .focus: return TimerShades.spring
        case .shortBreak: return TimerShades.shortBreak
        case .longBreak: return TimerShades.longBreak
        }
    }
    private var started: Bool { timer.isRunning || timer.progress > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Header and buttons keep their height; the ruler takes what is left, so its numbers are never cut off
            // at the short Duo height.
            VStack(alignment: .leading, spacing: 4) {
                header
                    .frame(height: 18)
                TimerRuler(timer: timer, tint: tint)
                    .frame(minHeight: 32, maxHeight: .infinity)
                controls
                    .frame(height: 28)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            Spacer().frame(width: 22)
            ring
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.35), value: timer.phase)
        .onChange(of: timer.isRunning) { _, running in
            if running { ignite() }
        }
    }

    /// Start pressed: the ring lights up (a comet runs once round it, then it blooms) while the notch waits a beat
    /// before folding away, so the moment is seen.
    private func ignite() {
        let stamp = Date()
        igniteAt = stamp
        pop = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            pop = false
            try? await Task.sleep(nanoseconds: UInt64(IgniteBurst.duration * 1_000_000_000))
            if igniteAt == stamp { igniteAt = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            tabs
            Spacer(minLength: 4)
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
    }

    private var caption: String {
        if timer.phase.isBreak { return timer.phase.title }
        return "Session \(min(timer.sessionsDone + 1, FocusTimer.sessionsPerRound)) of \(FocusTimer.sessionsPerRound)"
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tab("Focus", selected: !timer.phase.isBreak) { timer.select(.focus) }
            tab("Break", selected: timer.phase.isBreak) { timer.select(.shortBreak) }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .opacity(timer.isRunning ? 0.5 : 1)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: timer.phase.isBreak)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !timer.isRunning, !selected else { return }
            Haptics.hf1()
            action()
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? tint : Color.white.opacity(0.5))
                .frame(width: 60, height: 18)
                .background {
                    // One capsule that slides from tab to tab.
                    if selected {
                        Capsule()
                            .fill(tint.opacity(0.22))
                            .matchedGeometryEffect(id: "selectedTab", in: tabSpace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.hf1()
                timer.toggle(fromIsland: island)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(timer.isRunning ? "Pause" : (started ? "Resume" : "Start Timer"))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(timer.isRunning ? tint : Color.black.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    Capsule().fill(timer.isRunning
                                   ? AnyShapeStyle(tint.opacity(0.2))
                                   : AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.72)],
                                                                  startPoint: .top, endPoint: .bottom)))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(timer.isRunning ? 0.1 : 0.35), lineWidth: 0.6))
                .shadow(color: tint.opacity(timer.isRunning ? 0.25 : 0.4), radius: 8, y: 1)
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.95))
            circle(sound ? "speaker.wave.2.fill" : "speaker.slash.fill", tinted: true,
                   help: sound ? "Timer sounds: on" : "Timer sounds: off") {
                sound.toggle()
            }
            circle(started ? "arrow.counterclockwise" : "forward.end.fill", tinted: false,
                   help: started ? "Restart this session" : "Skip to the next session") {
                started ? timer.reset() : timer.skip()
            }
            .contextMenu {
                Button("Skip to the next session") { timer.skip() }
                Button("Restart this session") { timer.reset() }
            }
        }
    }

    private func circle(_ symbol: String, tinted: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.hf1()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tinted ? tint : Color.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(tinted ? tint.opacity(0.2) : Color.white.opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .help(help)
    }

    // MARK: Ring

    private static let ringSize: CGFloat = 80
    private static let ringLine: CGFloat = 5

    private var ring: some View {
        let diameter = FocusPane.ringSize - FocusPane.ringLine
        let progress = CGFloat(timer.progress)
        let headAngle = -Double.pi / 2 + 2 * Double.pi * Double(progress)
        return ZStack {
            // A soft light inside the ring, brighter while a session runs.
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(timer.isRunning ? 0.24 : 0.13), tint.opacity(0)],
                                     center: .center, startRadius: 2, endRadius: FocusPane.ringSize / 2))
            Circle()
                .stroke(started ? Color.white.opacity(0.09) : tint.opacity(0.26), lineWidth: FocusPane.ringLine)
                .frame(width: diameter, height: diameter)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(colors: [tint.opacity(0.35), tint],
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * Double(max(progress, 0.01)))),
                        style: StrokeStyle(lineWidth: FocusPane.ringLine, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.55), radius: 6)
            if started {
                Circle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: tint, radius: 4)
                    .offset(x: diameter / 2 * CGFloat(cos(headAngle)), y: diameter / 2 * CGFloat(sin(headAngle)))
            }
            VStack(spacing: 1) {
                Text(timeString)
                    .font(.system(size: 21, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.25), value: timeString)
                    .scaleEffect(pop ? 1.12 : 1)
                    .animation(.spring(response: 0.32, dampingFraction: 0.45), value: pop)
                Text(timer.phase.title.uppercased())
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                HStack(spacing: 3) {
                    ForEach(0..<FocusTimer.sessionsPerRound, id: \.self) { index in
                        Capsule()
                            .fill(index < timer.sessionsDone ? tint : Color.white.opacity(0.16))
                            .frame(width: 9, height: 3)
                    }
                }
                .padding(.top, 2)
                .animation(.smooth(duration: 0.3), value: timer.sessionsDone)
            }
            .frame(width: FocusPane.ringSize - 18)
        }
        .frame(width: FocusPane.ringSize, height: FocusPane.ringSize)
        .overlay {
            if let start = igniteAt {
                TimelineView(.animation) { timeline in
                    IgniteBurst(elapsed: timeline.date.timeIntervalSince(start), tint: tint,
                                radius: (FocusPane.ringSize - FocusPane.ringLine) / 2)
                }
                .frame(width: FocusPane.ringSize + 72, height: FocusPane.ringSize + 72)
                .allowsHitTesting(false)
            }
        }
        .animation(.linear(duration: 0.3), value: timer.progress)
        .animation(.smooth(duration: 0.5), value: timer.isRunning)
    }

    private var timeString: String {
        let seconds = Int(timer.remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The ignition of the ring when a session starts. A pure function of the time since Start was pressed: a soft flash
/// and two shock rings at once, a comet that runs once round the ring, and when it lands the ring blooms with sparks.
private struct IgniteBurst: View {
    static let duration: Double = 1.25

    let elapsed: Double
    let tint: Color
    let radius: CGFloat

    private static let sweepEnd = 0.7

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            }

            // A soft flash of the colour inside the ring.
            let flash = max(0, 1 - elapsed / 0.5)
            if flash > 0 {
                context.fill(circle(radius + 6),
                             with: .radialGradient(Gradient(colors: [tint.opacity(0.55 * flash), tint.opacity(0)]),
                                                   center: centre, startRadius: 0, endRadius: radius + 6))
            }

            // Two shock rings leaving the ring, the second a moment behind.
            for index in 0..<2 {
                let life = (elapsed - Double(index) * 0.15) / 0.75
                guard life > 0, life < 1 else { continue }
                let eased = 1 - pow(1 - life, 3)
                context.stroke(circle(radius + 2 + CGFloat(eased) * 18),
                               with: .color(tint.opacity((1 - life) * 0.75)),
                               lineWidth: 2.4 - 1.7 * CGFloat(life))
            }

            // The comet: it whips round the ring and slows as it comes home to the top.
            let sweep = elapsed / IgniteBurst.sweepEnd
            if sweep > 0, sweep < 1.15 {
                let travel = min(sweep, 1)
                let eased = 1 - pow(1 - travel, 2.2)
                let headAngle = -Double.pi / 2 + 2 * Double.pi * eased
                let fade = sweep <= 1 ? 1 : max(0, 1 - (sweep - 1) / 0.15)
                let tailCount = 28
                for index in stride(from: tailCount, through: 0, by: -1) {
                    let along = Double(index) / Double(tailCount)
                    let angle = headAngle - Double(index) * 0.055
                    let point = CGPoint(x: centre.x + radius * CGFloat(cos(angle)),
                                        y: centre.y + radius * CGFloat(sin(angle)))
                    let dot = 4.2 * (1 - 0.7 * along)
                    let colour: Color = index == 0 ? .white : tint
                    context.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                                 with: .color(colour.opacity(pow(1 - along, 1.5) * fade)))
                }
                let headPoint = CGPoint(x: centre.x + radius * CGFloat(cos(headAngle)),
                                        y: centre.y + radius * CGFloat(sin(headAngle)))
                context.drawLayer { layer in
                    layer.opacity = fade
                    layer.addFilter(.shadow(color: tint, radius: 7))
                    layer.fill(Path(ellipseIn: CGRect(x: headPoint.x - 3.5, y: headPoint.y - 3.5, width: 7, height: 7)),
                               with: .color(.white))
                }
            }

            // The bloom: sparks leave the whole ring as the comet lands.
            let bloom = (elapsed - IgniteBurst.sweepEnd) / 0.5
            if bloom > 0, bloom < 1 {
                let eased = 1 - pow(1 - bloom, 2.6)
                let count = 18
                for index in 0..<count {
                    let angle = Double(index) / Double(count) * 2 * Double.pi
                    // A fixed, uneven spread so the sparks do not look machine-made.
                    let jitter = (abs(sin(Double(index) * 12.9898)) * 0.6) + 0.4
                    let distance = radius + 3 + CGFloat(eased) * 15 * CGFloat(jitter)
                    let point = CGPoint(x: centre.x + distance * CGFloat(cos(angle)),
                                        y: centre.y + distance * CGFloat(sin(angle)))
                    let dot = 3.2 * CGFloat(1 - bloom) + 0.6
                    context.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                                 with: .color((index % 3 == 0 ? Color.white : tint).opacity(1 - bloom)))
                }
            }
        }
    }
}

/// The ruler of minutes: one tick per minute, a number every five. The selected tick stays put and the ruler slides
/// under it. Ticks up to it are lit, the rest are dim. Drag it to set the focus length; while a session runs it
/// slowly slides along with the time left.
private struct TimerRuler: View {
    @ObservedObject var timer: FocusTimer
    let tint: Color
    @State private var dragStart: Int?

    private let spacing: CGFloat = 7
    private let range = 0...120

    private var editable: Bool { !timer.isRunning && timer.progress == 0 && !timer.phase.isBreak }

    var body: some View {
        GeometryReader { geo in
            let anchor = geo.size.width * 0.66
            Canvas { context, size in
                let value = timer.rulerMinutes
                // Ticks stand on a line 8 pt above the bottom; the numbers sit above the tall ticks. Everything is
                // measured from the ruler's own height, so nothing falls outside it.
                let base = size.height - 8
                for minute in range {
                    let x = anchor + (CGFloat(minute) - CGFloat(value)) * spacing
                    guard x > -8, x < size.width + 8 else { continue }
                    let isMajor = minute % 5 == 0
                    let lit = Double(minute) <= value + 0.001
                    let height: CGFloat = isMajor ? 14 : 9
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: base))
                    path.addLine(to: CGPoint(x: x, y: base - height))
                    context.stroke(path, with: .color(lit ? tint.opacity(isMajor ? 0.95 : 0.7) : Color.white.opacity(0.16)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    if isMajor, minute > 0 {
                        let label = context.resolve(Text("\(minute)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(lit ? tint.opacity(0.85) : Color.white.opacity(0.3)))
                        context.draw(label, at: CGPoint(x: x, y: base - height - 8), anchor: .center)
                    }
                }
                // The selected tick: taller and white, with a small mark under it.
                var current = Path()
                current.move(to: CGPoint(x: anchor, y: base + 1))
                current.addLine(to: CGPoint(x: anchor, y: base - 17))
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: tint.opacity(0.9), radius: 4))
                    layer.stroke(current, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                let mark = CGRect(x: anchor - 4, y: base + 4, width: 8, height: 2)
                context.fill(Path(roundedRect: mark, cornerRadius: 1), with: .color(tint))
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.94),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard editable else { return }
                        if dragStart == nil { dragStart = FocusTimer.focusMinutes }
                        let proposed = (dragStart ?? FocusTimer.focusMinutes) - Int((drag.translation.width / spacing).rounded())
                        let minutes = min(max(proposed, 5), 120)
                        guard minutes != FocusTimer.focusMinutes else { return }
                        Haptics.hf3(lockout: 0.03)
                        timer.setFocusMinutes(minutes)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .help(editable ? "Drag to set the focus length" : "")
    }
}

// MARK: - Clipboard

/// Duo's clipboard page, laid out like the clipboard manager in the reference: a row of pill tabs (Text, Images,
/// Links; it opens on Text) with a red "Clear all" at the right, and under it one row of rounded cards that
/// scrolls sideways. Each card shows what was copied and, at its foot, the icon of the app it came from and how
/// long ago. Clicking a card copies it back to the clipboard.
private struct ClipboardPane: View {
    @ObservedObject var store: ClipboardStore
    @Namespace private var tabSpace

    private static let tabHeight: CGFloat = 20
    private static let gap: CGFloat = 6
    private let cardSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let cardHeight = max(geo.size.height - Self.tabHeight - Self.gap, 40)
            VStack(alignment: .leading, spacing: Self.gap) {
                tabRow
                    .frame(height: Self.tabHeight)
                cards(height: cardHeight)
                    .frame(height: cardHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.top, 2)
        .onAppear { store.tab = .text }
    }

    private var hasAnything: Bool {
        !store.texts.isEmpty || !store.images.isEmpty || !store.links.isEmpty
    }

    // MARK: Tabs

    private var tabRow: some View {
        HStack(spacing: 6) {
            ForEach(ClipTab.allCases) { tab in
                ClipTabPill(title: tab.rawValue, selected: store.tab == tab, space: tabSpace) {
                    Haptics.hf1()
                    withAnimation(.smooth(duration: 0.28)) { store.tab = tab }
                }
            }
            Spacer(minLength: 4)
            if hasAnything {
                ClearAllPill {
                    Haptics.hf1()
                    store.clearAll()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            }
        }
        .padding(.horizontal, 2)
        .animation(.smooth(duration: 0.25), value: hasAnything)
    }

    // MARK: Cards

    @ViewBuilder
    private func cards(height: CGFloat) -> some View {
        Group {
            switch store.tab {
            case .text:
                row(count: store.texts.count, empty: "Copy some text") {
                    ForEach(store.texts) { item in
                        TextCard(item: item, height: height, onCopy: { store.copy(item) }) {
                            Button("Copy") { store.copy(item) }
                            Button("Remove") { store.remove(item) }
                        }
                    }
                }
            case .images:
                row(count: store.images.count, empty: "Copy an image") {
                    ForEach(store.images) { item in
                        ImageCard(item: item, height: height, onCopy: { store.copy(item) }) {
                            Button("Copy") { store.copy(item) }
                            Button("Remove") { store.remove(item) }
                        }
                    }
                }
            case .links:
                row(count: store.links.count, empty: "Copy a link") {
                    ForEach(store.links) { item in
                        LinkCard(item: item, height: height, onCopy: { store.copy(item) }) {
                            Button("Copy link") { store.copy(item) }
                            Button("Open") { NSWorkspace.shared.open(item.url) }
                            Divider()
                            Button("Remove") { store.remove(item) }
                        }
                    }
                }
            }
        }
        .id(store.tab)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    /// One sideways-scrolling row; an empty tab shows a quiet hint instead.
    @ViewBuilder
    private func row<Content: View>(count: Int, empty: String, @ViewBuilder content: () -> Content) -> some View {
        if count == 0 {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    Text(empty)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.32))
                )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) { content() }
                    .padding(.horizontal, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .lockScrollAxis(.horizontal)
            // The cards fade out at the right edge: a hint that there are more to scroll to.
            .mask(
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                }
            )
            .animation(.smooth(duration: 0.25), value: count)
        }
    }
}

/// A pill tab: the chosen one is solid white with dark text and slides to the next when it changes.
private struct ClipTabPill: View {
    let title: String
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? Color.black.opacity(0.88) : Color.white.opacity(hovering ? 0.95 : 0.78))
                .padding(.horizontal, 11)
                .frame(height: 20)
                .background {
                    ZStack {
                        Capsule().fill(Color.white.opacity(hovering ? 0.17 : 0.11))
                        if selected {
                            Capsule()
                                .fill(Color.white)
                                .matchedGeometryEffect(id: "clipTab", in: space)
                        }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

/// The red "Clear all" pill at the right of the tabs.
private struct ClearAllPill: View {
    let action: () -> Void
    @State private var hovering = false
    private let red = Color(red: 1.0, green: 0.30, blue: 0.30)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 8.5, weight: .semibold))
                Text("Clear all")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(red.opacity(hovering ? 1 : 0.88))
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Capsule().fill(red.opacity(hovering ? 0.22 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

// MARK: Cards

/// The line at the foot of a card: the icon of the app it came from, and how long ago.
private struct CardFooter: View {
    let source: NSImage?
    let date: Date
    var onImage = false

    var body: some View {
        HStack(spacing: 4) {
            if let source {
                Image(nsImage: source)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 11, height: 11)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 9, height: 9)
            }
            AgoLabel(date: date)
        }
        .shadow(color: .black.opacity(onImage ? 0.55 : 0), radius: 2)
    }
}

/// "11s ago", "2m ago", "1h ago": counts on by itself while the page is open.
private struct AgoLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(since: date, now: context.date))
                .font(.system(size: 8.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    static func text(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "\(max(seconds, 1))s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Shared look of a card: dark rounded tile, a check for a moment after it is clicked, a soft light on hover.
private struct CardShell<Content: View, MenuContent: View>: View {
    let width: CGFloat
    let height: CGFloat
    let fill: Color
    let onCopy: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovering = false
    @State private var copied = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Button {
            onCopy()
            Haptics.hf1()
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                copied = false
            }
        } label: {
            ZStack {
                fill
                content()
                if copied {
                    Color.black.opacity(0.55)
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(red: 0.45, green: 0.9, blue: 0.6))
                        .transition(.scale.combined(with: .opacity))
                } else if hovering {
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.07), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .contextMenu { menu() }
        .animation(.smooth(duration: 0.2), value: copied)
    }
}

private struct TextCard<MenuContent: View>: View {
    let item: ClipText
    let height: CGFloat
    let onCopy: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        CardShell(width: height * 1.7, height: height, fill: Color(white: 0.115), onCopy: onCopy, content: {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineSpacing(0.5)
                    .lineLimit(max(Int((height - 26) / 11), 2))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 2)
                CardFooter(source: item.source, date: item.date)
            }
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 6)
        }, menu: menu)
    }
}

private struct LinkCard<MenuContent: View>: View {
    let item: ClipLink
    let height: CGFloat
    let onCopy: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        CardShell(width: height * 1.7, height: height, fill: Color(white: 0.115), onCopy: onCopy, content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color(red: 0.42, green: 0.88, blue: 0.72))
                    Text(item.host)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !item.path.isEmpty {
                    Text(item.path)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 3)
                }
                Spacer(minLength: 2)
                CardFooter(source: item.source, date: item.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 6)
        }, menu: menu)
    }
}

private struct ImageCard<MenuContent: View>: View {
    let item: ClipImage
    let height: CGFloat
    let onCopy: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        CardShell(width: height * 1.35, height: height, fill: Color(white: 0.115), onCopy: onCopy, content: {
            ZStack(alignment: .bottomLeading) {
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: height * 1.35, height: height)
                    .clipped()
                LinearGradient(colors: [.clear, Color.black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                CardFooter(source: item.source, date: item.date, onImage: true)
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
            }
        }, menu: menu)
    }
}
