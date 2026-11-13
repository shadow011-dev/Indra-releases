import AppKit
import SwiftUI

/// Edge light for video calls: the edges of the Mac's own screen glow, so the screen lights your face. The cool
/// (blue) and warm (orange) lights are switched, and set in intensity and width, with the two knobs next to the
/// camera box in Duo. The glow window never takes a click and sits just under the notch.
@MainActor
final class EdgeLightController {
    static let shared = EdgeLightController()

    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    private var anyOn: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: Preferences.edgeWarmOnKey) || defaults.bool(forKey: Preferences.edgeCoolOnKey)
    }

    func start() {
        // A light left on in an earlier session does not light the screen at launch.
        UserDefaults.standard.set(false, forKey: Preferences.edgeWarmOnKey)
        UserDefaults.standard.set(false, forKey: Preferences.edgeCoolOnKey)
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                object: nil, queue: .main) { _ in
            Task { @MainActor in EdgeLightController.shared.sync() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            Task { @MainActor in EdgeLightController.shared.sync() }
        })
    }

    private func sync() {
        guard anyOn, let screen = NotchMetrics.notchScreen() else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: EdgeLightScreenView())
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        SpaceChangeGuard.register(panel)
        return panel
    }
}

/// The glow: a soft gradient along each edge of the screen, as thick as the width knob says and as bright as the
/// intensity knob says. When both lights are on they mix.
struct EdgeLightScreenView: View {
    @AppStorage(Preferences.edgeWarmOnKey) private var warmOn = false
    @AppStorage(Preferences.edgeWarmIntensityKey) private var warmIntensity = 0.6
    @AppStorage(Preferences.edgeWarmWidthKey) private var warmWidth = 0.4
    @AppStorage(Preferences.edgeCoolOnKey) private var coolOn = false
    @AppStorage(Preferences.edgeCoolIntensityKey) private var coolIntensity = 0.6
    @AppStorage(Preferences.edgeCoolWidthKey) private var coolWidth = 0.4

    var body: some View {
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height)
            ZStack {
                if coolOn { glow(EdgeLight.cool, intensity: coolIntensity, thickness: base * (0.03 + 0.17 * coolWidth)) }
                if warmOn { glow(EdgeLight.warm, intensity: warmIntensity, thickness: base * (0.03 + 0.17 * warmWidth)) }
            }
            .blendMode(.plusLighter)
            .animation(.easeOut(duration: 0.25), value: coolOn)
            .animation(.easeOut(duration: 0.25), value: warmOn)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func glow(_ color: Color, intensity: Double, thickness: CGFloat) -> some View {
        let strong = color.opacity(0.95 * intensity)
        let colors = [strong, color.opacity(0.3 * intensity), Color.clear]
        return ZStack {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                .frame(height: thickness).frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top)
                .frame(height: thickness).frame(maxHeight: .infinity, alignment: .bottom)
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: thickness).frame(maxWidth: .infinity, alignment: .leading)
            LinearGradient(colors: colors, startPoint: .trailing, endPoint: .leading)
                .frame(width: thickness).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
