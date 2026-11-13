import AppKit
import SwiftUI

/// v555: which edge of the screen the tall pill sits on. The right edge is the "Apple style" overlay; the left edge is the bar
/// shown while the face scan animation owns the notch above an App Lock blur screen (see NotchWindowController).
enum HUDEdge {
    case left, right
}

@MainActor
final class AppleHUDModel: ObservableObject {
    @Published var kind: HUDKind = .volume
    @Published var value: Double = 0
    @Published var muted = false
    @Published var accent: NSColor?
    @Published var size = CGSize(width: 78, height: 246)
    @Published var edge: HUDEdge = .right
    /// Drives the slide / scale / blur entrance and exit.
    @Published var visible = false
    /// Counts updates, so the pill can press in slightly on every key press.
    @Published var tick = 0
}

/// The "Apple style" overlay: a tall rounded pill on the right edge of the screen.
/// Its background follows the notch look (Liquid Glass, translucent or black).
@MainActor
final class AppleHUDController {
    private let panel: NSPanel
    private let model = AppleHUDModel()
    private var hideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?
    private let edge: HUDEdge

    /// v559: size and distance from the screen's left edge of the bar shown while the face scan animation plays (points).
    static let leftBarSize = CGSize(width: 48, height: 148)
    static let leftBarMargin: CGFloat = 12.5

    init(edge: HUDEdge = .right) {
        self.edge = edge
        model.edge = edge
        let panel = NSPanel(contentRect: NSRect(origin: .zero,
                                        size: CGSize(width: Preferences.appleHUDWidth, height: Preferences.appleHUDHeight)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        let host = NSHostingView(rootView: AppleHUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        SpaceChangeGuard.register(panel)
        // v420: the bar does not stay (or freeze half way) when the desktop changes: it is simply gone.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissNow() }
        }
    }

    private var spaceObserver: NSObjectProtocol?

    /// v555: removes what the bar registered and takes the window away (it never did, so a notch that was shut down left its
    /// Space observer behind).
    func shutdown() {
        hideTask?.cancel()
        orderOutTask?.cancel()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// v555: the bar leaves with its normal exit animation (used when something else takes over, e.g. the face scan animation is
    /// gone and the normal volume / brightness display follows).
    func hide() {
        hideTask?.cancel()
        guard model.visible || panel.alphaValue > 0 else { return }
        withAnimation(.easeIn(duration: 0.24)) {
            model.visible = false
        }
        orderOutTask?.cancel()
        orderOutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.panel.alphaValue = 0
        }
    }

    /// Takes the bar away at once, without any animation.
    private func dismissNow() {
        guard model.visible || panel.alphaValue > 0 else { return }
        hideTask?.cancel()
        orderOutTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.visible = false }
        panel.alphaValue = 0
    }

    func show(_ event: SensoryEvent, on screen: NSScreen?, accent: NSColor?, duration: Double) {
        model.kind = event.kind
        model.value = event.value
        model.muted = event.muted
        model.accent = accent

        let frame = (screen ?? NSScreen.main)?.frame ?? .zero
        // v559: the left-edge bar has the exact size and place of the reference picture (measured from it, in points on a 1470 x 956
        // screen): 48 x 148, 12.5 from the left edge, its middle at the middle of the screen's height. The right-edge style keeps
        // the size and position chosen in Settings.
        let size = edge == .left
            ? AppleHUDController.leftBarSize
            : CGSize(width: Preferences.appleHUDWidth, height: Preferences.appleHUDHeight)
        model.size = size
        let centerY = edge == .left ? frame.midY : frame.maxY - frame.height * Preferences.sensoryPosition
        panel.setFrame(NSRect(x: edge == .left ? frame.minX + AppleHUDController.leftBarMargin : frame.maxX - size.width - 14,
                              y: centerY - size.height / 2,
                              width: size.width,
                              height: size.height),
                       display: false)
        orderOutTask?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        model.tick &+= 1
        if !model.visible {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
                model.visible = true
            }
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeIn(duration: 0.24)) {
                self.model.visible = false
            }
            self.orderOutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                self?.panel.alphaValue = 0
            }
        }
    }
}

struct AppleHUDView: View {
    @ObservedObject var model: AppleHUDModel
    @AppStorage(Preferences.liquidGlassKey) private var liquidGlass = false
    @AppStorage(Preferences.translucentNotchKey) private var translucent = true
    @AppStorage(Preferences.glassDarknessKey) private var darkness = 0.55
    @State private var pressed = false

    private var shape: RoundedRectangle {
        // v559: the left-edge bar is a full capsule (its ends are half circles), as in the reference picture.
        RoundedRectangle(cornerRadius: model.edge == .left ? model.size.width / 2 : min(model.size.width * 0.38, 40),
                         style: .continuous)
    }

    private var accentColor: Color? {
        model.accent.map { Color(nsColor: $0) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            fill
            HUDSymbol(symbol: model.kind.appleSymbol(value: model.value, muted: model.muted), value: model.value,
                      size: model.edge == .left ? 18 : max(9, model.size.width * 0.28))
                .foregroundStyle(model.value > 0.14 ? Color(white: 0.22) : Color.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .padding(.bottom, min(model.size.width * 0.23, model.size.height * 0.3))
                .animation(.easeOut(duration: 0.16), value: model.value > 0.14)
        }
        .frame(width: model.size.width, height: model.size.height)
        .clipShape(shape)
        .scaleEffect(model.visible ? (pressed ? 0.96 : 1) : 0.86, anchor: model.edge == .left ? .leading : .trailing)
        .offset(x: model.visible ? 0 : (model.edge == .left ? -26 : 26))
        .blur(radius: model.visible ? 0 : 6)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.2, dampingFraction: 0.55), value: pressed)
        .onChange(of: model.tick) { _, _ in
            pressed = true
            Task {
                try? await Task.sleep(nanoseconds: 90_000_000)
                pressed = false
            }
        }
    }

    /// Same look as the notch: clear glass, translucent frost, or black.
    @ViewBuilder
    private var background: some View {
        if #available(macOS 26.0, *), liquidGlass {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: shape)
                Color.black.opacity(0.12 + darkness * 0.78)
            }
        } else if translucent {
            ZStack {
                FrostedBackground()
                Color.black.opacity(0.12 + darkness * 0.8)
            }
        } else {
            Color.black.opacity(0.88)
        }
    }

    private var fill: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(fillStyle)
                    .frame(height: geometry.size.height * CGFloat(min(max(model.value, 0), 1)))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: model.value)
    }

    private var fillStyle: LinearGradient {
        if let accentColor {
            return LinearGradient(colors: [accentColor, accentColor.opacity(0.75)],
                                  startPoint: .top,
                                  endPoint: .bottom)
        }
        return LinearGradient(colors: [Color.white.opacity(0.96), Color.white.opacity(0.9)],
                              startPoint: .top,
                              endPoint: .bottom)
    }
}
