import AppKit
import Combine
import SwiftUI

/// The line of light that spreads along the top of the screen when a focus session starts. It only holds the start time: the drawing
/// is a pure function of the time that has passed, so there is nothing to keep in sync.
@MainActor
final class FocusWave: ObservableObject {
    /// How long the whole wave lasts: the strike, the line crossing the screen, and the glint over the timer line.
    /// (The start sound is 3.4 s long; the picture is done a moment before its tail ends.)
    static let duration: TimeInterval = 3.2

    @Published private(set) var startedAt: Date?
    /// The colour of the session that started it; it tints the light.
    private(set) var tint: Color = .white
    private var endTask: Task<Void, Never>?

    func play(tint: Color) {
        endTask?.cancel()
        self.tint = tint
        startedAt = Date()
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((FocusWave.duration + 0.2) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startedAt = nil
        }
    }
}

/// Everything drawn around the closed notch for a focus session: a thin glowing white line right under the notch
/// that fills as the time passes, and the line of light that spreads from the notch.
struct FocusEdgeView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var timer: FocusTimer
    @ObservedObject var wave: FocusWave

    var body: some View {
        ZStack(alignment: .top) {
            if let start = wave.startedAt {
                let notchBottom = state.metrics.closedSize.height + state.metrics.topGap
                TimelineView(.animation) { timeline in
                    HorizonLight(elapsed: timeline.date.timeIntervalSince(start), notchBottom: notchBottom,
                                 notchHalfWidth: state.metrics.closedSize.width / 2,
                                 trackHalfWidth: max((state.metrics.closedSize.width - 20) / 2, 12),
                                 tint: wave.tint)
                }
            }
            FocusProgressLine(state: state, timer: timer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// The start of a focus session, one gesture in three beats, timed to the singing-bowl note (struck at 0):
///
///  1. the strike (0 s): a soft bloom of the session's colour right under the notch, gone in under a second;
///  2. the horizon (0.1 to 1.8 s): a hairline of light is released from the notch to both ends of the screen, fast at
///     first and settling as it arrives, brightest in the middle and fading towards the ends, with a spark leading each
///     tip (it starts as a flash at the notch's edges and ends as a soft point at the screen's) and a faint wash of the
///     colour under it. It then simply dissolves: nothing goes back, nothing repeats;
///  3. the hand-off (1.85 to 2.65 s): one small glint runs along the timer line under the notch, left to right, as
///     the line takes over.
///
/// One colour, no particles, no blur filter (the glow is built from soft strokes), and a pure function of the time
/// since the start, so there is nothing to keep in sync.
private struct HorizonLight: View {
    let elapsed: Double
    let notchBottom: CGFloat
    let notchHalfWidth: CGFloat
    /// Half the width of the timer line under the notch, for the glint's run.
    let trackHalfWidth: CGFloat
    let tint: Color

    private static let spreadStart = 0.08
    private static let spreadLength = 1.7
    private static let lineFadeStart = 1.5
    private static let lineFadeLength = 1.2
    private static let washFadeStart = 1.2
    private static let washFadeLength = 1.6
    private static let sweepStart = 1.85
    private static let sweepLength = 0.8

    private func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let t = elapsed
        // 0 = as wide as the notch, 1 = the whole width of the screen: a quintic ease-out, so it leaves quickly and
        // arrives slowly.
        let x = min(max((t - HorizonLight.spreadStart) / HorizonLight.spreadLength, 0), 1)
        let spread = 1 - pow(1 - x, 5)
        let lineAmount = smooth(t / 0.3) * (1 - smooth((t - HorizonLight.lineFadeStart) / HorizonLight.lineFadeLength))
        let washAmount = smooth(t / 0.4) * (1 - smooth((t - HorizonLight.washFadeStart) / HorizonLight.washFadeLength))
        let strike = exp(-t / 0.45) * smooth(t / 0.05)
        let sweep = min(max((t - HorizonLight.sweepStart) / HorizonLight.sweepLength, 0), 1)

        return Canvas { context, size in
            let centreX = size.width / 2
            let half = size.width / 2
            let y = notchBottom + 1
            let reach = notchHalfWidth + (half - notchHalfWidth) * CGFloat(spread)

            // 1. The strike: a bloom under the notch.
            if strike > 0.01 {
                let r = notchHalfWidth * 1.7
                context.drawLayer { layer in
                    layer.clip(to: Path(CGRect(x: 0, y: y, width: size.width, height: 170)))
                    layer.translateBy(x: centreX, y: y)
                    layer.scaleBy(x: 1, y: 0.55)
                    layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                               with: .radialGradient(Gradient(colors: [tint.opacity(0.5 * strike), tint.opacity(0)]),
                                                     center: .zero, startRadius: 0, endRadius: r))
                }
            }

            // The colour's wash under the line, as wide as the line.
            if washAmount > 0.003 {
                context.drawLayer { layer in
                    layer.opacity = washAmount
                    layer.clip(to: Path(CGRect(x: 0, y: y, width: size.width, height: 170)))
                    layer.translateBy(x: centreX, y: y)
                    layer.scaleBy(x: max(reach, 1) / 120, y: 0.9)
                    layer.fill(Path(ellipseIn: CGRect(x: -120, y: -120, width: 240, height: 240)),
                               with: .radialGradient(Gradient(colors: [tint.opacity(0.26), tint.opacity(0)]),
                                                     center: .zero, startRadius: 0, endRadius: 120))
                }
            }

            // 2. The horizon: the hairline, its halo, and a spark at each tip.
            if lineAmount > 0.003 {
                let left = centreX - reach
                let right = centreX + reach
                let gradient = Gradient(stops: [
                    .init(color: tint.opacity(0), location: 0),
                    .init(color: tint.opacity(0.5), location: 0.18),
                    .init(color: Color.white.opacity(0.95), location: 0.5),
                    .init(color: tint.opacity(0.5), location: 0.82),
                    .init(color: tint.opacity(0), location: 1)
                ])
                let shading = GraphicsContext.Shading.linearGradient(gradient,
                                                                     startPoint: CGPoint(x: left, y: y),
                                                                     endPoint: CGPoint(x: right, y: y))
                var line = Path()
                line.move(to: CGPoint(x: left, y: y))
                line.addLine(to: CGPoint(x: right, y: y))

                // The halo: two wide, faint strokes (cheaper than a blur, and just as soft).
                for (width, strength) in [(16.0, 0.07), (6.0, 0.16)] {
                    context.drawLayer { layer in
                        layer.opacity = lineAmount * strength
                        layer.stroke(line, with: shading, style: StrokeStyle(lineWidth: CGFloat(width), lineCap: .round))
                    }
                }
                context.drawLayer { layer in
                    layer.opacity = lineAmount
                    layer.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }

                // The sparks leading the tips: strongest at the start, softer as the line reaches the ends.
                let tipStrength = lineAmount * (0.3 + 0.7 * (1 - spread))
                for side in [-1.0, 1.0] {
                    let tipX = centreX + CGFloat(side) * reach * 0.97
                    context.drawLayer { layer in
                        layer.opacity = tipStrength
                        layer.translateBy(x: tipX, y: y)
                        layer.scaleBy(x: 2.4, y: 1)
                        layer.fill(Path(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18)),
                                   with: .radialGradient(Gradient(colors: [Color.white.opacity(0.95), tint.opacity(0.35), tint.opacity(0)]),
                                                         center: .zero, startRadius: 0, endRadius: 9))
                    }
                }
            }

            // 3. The hand-off: one glint along the timer line.
            if sweep > 0, sweep < 1 {
                let glintX = centreX - trackHalfWidth + 2 * trackHalfWidth * CGFloat(smooth(sweep))
                let glintY = notchBottom + 3.75
                context.drawLayer { layer in
                    layer.opacity = sin(Double.pi * sweep)
                    layer.translateBy(x: glintX, y: glintY)
                    layer.scaleBy(x: 3.2, y: 1)
                    layer.fill(Path(ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14)),
                               with: .radialGradient(Gradient(colors: [Color.white.opacity(0.95), tint.opacity(0.4), tint.opacity(0)]),
                                                     center: .zero, startRadius: 0, endRadius: 7))
                }
            }
        }
    }
}

/// The glowing white line under the closed notch. It is as wide as the notch is right now (it widens with the music
/// activity and narrows again), and it fills from left to right as the session goes on.
private struct FocusProgressLine: View {
    @ObservedObject var state: NotchState
    @ObservedObject var timer: FocusTimer
    @State private var breathe = false

    private var started: Bool { timer.isRunning || timer.progress > 0 }
    private var visible: Bool { started && !state.isExpanded }

    private var bodySize: CGSize {
        state.isDownlineHUD ? state.downlineSize : state.closedBodySize
    }

    /// The flat part of the notch's bottom edge (its bottom corners are rounded).
    private var cornerRadius: CGFloat {
        if state.metrics.islandShaped { return state.isDownlineHUD ? 26 : state.metrics.closedSize.height / 2 }
        return state.isDownlineHUD ? 28 : (state.isClosedWide ? 14 : 10)
    }

    /// The island's body is narrower than its frame by the same ear inset on each side (see NotchShape).
    private var islandInset: CGFloat {
        guard state.metrics.islandShaped else { return 0 }
        return state.isDownlineHUD ? 18 : (state.isClosedWide ? 8 : 0)
    }

    var body: some View {
        let width = max(bodySize.width - islandInset * 2 - cornerRadius * 2, 24)
        let filled = max(width * CGFloat(timer.progress), 3)
        let glow = timer.isRunning ? (breathe ? 0.85 : 0.5) : 0.4
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.14))
            Capsule()
                .fill(Color.white)
                .frame(width: filled)
                .shadow(color: Color.white.opacity(0.95), radius: 2.5)
                .shadow(color: Color.white.opacity(glow), radius: breathe && timer.isRunning ? 10 : 6)
        }
        .frame(width: width, height: 2.5)
        .offset(y: bodySize.height + 2.5 + state.metrics.topGap)
        .opacity(visible ? 1 : 0)
        .animation(.linear(duration: 0.3), value: timer.progress)
        .animation(.easeInOut(duration: 0.4), value: visible)
        .animation(state.closedSlot > 0 ? NotchMotion.hudOpen : NotchMotion.hudClose, value: state.closedSlot)
        .animation(state.isDownlineHUD ? NotchMotion.hudOpen : NotchMotion.hudClose, value: state.isDownlineHUD)
        .onAppear {
            guard !NotchMotion.stillLoops else { breathe = true; return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// A transparent window across the top of the screen that the pointer passes straight through. It carries the
/// progress line and the wave, because the notch window itself is only as big as the notch.
@MainActor
final class FocusEdgeController {
    let panel: NSPanel
    private let wave = FocusWave()
    private var observers: [NSObjectProtocol] = []
    private var locked = false

    init(state: NotchState) {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: FocusEdgeView(state: state, timer: FocusTimer.shared, wave: wave))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel

        // Not drawn over the lock screen (it has its own player and clock).
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setLocked(true) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setLocked(false) }
        })
    }

    /// Covers the top of the given screen and goes on screen (it stays there, empty and see-through, until needed).
    func show(on screen: NSScreen?) {
        reposition(on: screen)
        panel.orderFrontRegardless()
    }

    func reposition(on screen: NSScreen?) {
        let frame = (screen ?? NSScreen.main)?.frame ?? .zero
        // The whole screen: the wave runs from the notch to the bottom edge. The window is see-through and the
        // pointer passes straight through it.
        panel.setFrame(frame, display: true)
    }

    func playWave(tint: Color) {
        wave.play(tint: tint)
    }

    /// v504: the window and the lock-screen listeners go for good (the external monitor's island was removed). Without this
    /// every island that was ever created left a full-screen window and two system listeners behind.
    func shutdown() {
        let center = DistributedNotificationCenter.default()
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func setLocked(_ isLocked: Bool) {
        locked = isLocked
        panel.alphaValue = isLocked ? 0 : 1
    }
}
