//
//  FaceLockGate.swift
//  Indra Face Lock
//
//  The full-screen "Verify it's you" prompt (fingerprint or password) that stands in front of the Face Lock section of the
//  app. Same look as the Lumen gate it comes from, without the quit shortcut, the watchdog and the face check.
//

import AppKit
import SwiftUI
import LocalAuthentication

// MARK: - Authentication gate

@MainActor
final class GateModel: ObservableObject {
    @Published var status = ""
    @Published var showPassword = false
    @Published var canRetryFace = false
    @Published var succeeded = false
    @Published var touching = false
    var title = "Face Lock is locked"
    var allowCancel = false
    var onPassword: (String) -> Bool = { _ in false }
    var onFace: () -> Void = {}
    var onTouch: () -> Void = {}
    var onCancel: () -> Void = {}
}

private final class GatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct GateBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct GateView: View {   // GATE_LOOK_V4
    @ObservedObject var model: GateModel
    @State private var password = ""
    @State private var shake: CGFloat = 0
    @State private var wrongFlash = false
    @State private var stage = 0
    @State private var breathe = false
    @State private var spin = false
    @FocusState private var focused: Bool

    private let smooth = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.7)

    var body: some View {
        ZStack {
            GateBlur().ignoresSafeArea()
            Color.black.opacity(0.30).ignoresSafeArea()
            RadialGradient(colors: [Color.white.opacity(0.08), .clear],
                           center: .center, startRadius: 0, endRadius: 480)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                card
                    .opacity(stage >= 1 ? 1 : 0)
                    .scaleEffect(stage >= 1 ? 1 : 0.96)
                    .offset(y: stage >= 1 ? 0 : 18)
                    .blur(radius: stage >= 1 ? 0 : 6)
                if model.allowCancel {
                    Button("Cancel") { model.onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .opacity(stage >= 3 && !model.succeeded ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: model.succeeded)
                }
            }
            .offset(y: 24)
            .scaleEffect(model.succeeded ? 0.97 : 1)
            .opacity(model.succeeded ? 0 : 1)
            .blur(radius: model.succeeded ? 4 : 0)
            .animation(.easeInOut(duration: 0.3), value: model.succeeded)
        }
        .overlay { if model.succeeded { SuccessMark() } }
        .onAppear {
            withAnimation(smooth) { stage = 1 }
            withAnimation(smooth.delay(0.12)) { stage = 2 }
            withAnimation(smooth.delay(0.24)) { stage = 3 }
            breathe = true
            spin = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 56, height: 56)
                    .blur(radius: 24)
                    .opacity(breathe ? 0.26 : 0.08)
                    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: breathe)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            }
            .padding(.bottom, 12)

            Text(model.title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(stage >= 2 ? 1 : 0)
                .offset(y: stage >= 2 ? 0 : 6)
            Text(model.status.isEmpty ? "Verify it's you" : model.status)
                .font(.system(size: 12))
                .foregroundStyle(model.status == "Wrong password."
                                 ? Color(red: 1, green: 0.5, blue: 0.5) : .white.opacity(0.58))
                .id(model.status)
                .transition(.opacity)
                .frame(height: 16)
                .padding(.top, 3)
                .padding(.bottom, 16)
                .opacity(stage >= 2 ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: model.status)

            fingerprintButton
                .opacity(stage >= 3 ? 1 : 0)
                .offset(y: stage >= 3 ? 0 : 8)

            passwordField
                .padding(.top, 16)
                .opacity(stage >= 3 ? 1 : 0)
                .offset(y: stage >= 3 ? 0 : 10)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 244)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 26, y: 12)
    }

    private var fingerprintButton: some View {
        Button { model.onTouch() } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: 58, height: 58)
                    .opacity(breathe ? 0.28 : 0.06)
                    .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: breathe)
                Circle().fill(Color.white.opacity(0.12)).frame(width: 50, height: 50)
                Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1).frame(width: 50, height: 50)
                Image(systemName: "touchid")
                    .font(.system(size: 24, weight: .light))
                    .opacity(model.touching ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.25), value: model.touching)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                    .opacity(model.touching ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: model.touching)
            }
        }
        .buttonStyle(GatePressStyle())
        .help("Use fingerprint")
    }

    private var passwordField: some View {
        HStack(spacing: 7) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(focused ? 0.75 : 0.45))
                .animation(.easeInOut(duration: 0.25), value: focused)
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.white.opacity(password.isEmpty ? 0.2 : 0.95))
                    .scaleEffect(password.isEmpty ? 0.88 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: password.isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(password.isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(Capsule().fill(Color.white.opacity(focused ? 0.13 : 0.09)))
        .overlay(Capsule().strokeBorder(
            wrongFlash ? Color(red: 1, green: 0.42, blue: 0.42) : Color.white.opacity(focused ? 0.3 : 0.16),
            lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: focused)
        .animation(.easeInOut(duration: 0.25), value: wrongFlash)
        .offset(x: shake)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        if !model.onPassword(password) {
            model.status = "Wrong password."
            password = ""
            wrongFlash = true
            Task { @MainActor in
                for dx in [-9, 8, -5, 3, 0] as [CGFloat] {
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.55)) { shake = dx }
                    try? await Task.sleep(for: .milliseconds(70))
                }
                try? await Task.sleep(for: .milliseconds(600))
                wrongFlash = false
            }
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.54))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.74))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.8, y: r.minY + r.height * 0.28))
        return path
    }
}

private struct SuccessMark: View {
    @State private var ring: CGFloat = 0
    @State private var check: CGFloat = 0
    @State private var settle = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 76, height: 76)
            CheckShape()
                .trim(from: 0, to: check)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 34, height: 34)
        }
        .scaleEffect(settle ? 1 : 0.92)
        .opacity(settle ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { settle = true }
            withAnimation(.easeInOut(duration: 0.4)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.22)) { check = 1 }
        }
    }
}

private struct GatePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

@MainActor
final class FaceLockGate {
    static let shared = FaceLockGate()
    private static let enabledKey = "faceLockGateEnabled"
    /// Constant: the gate never changes level, so it can never drop behind anything when Touch ID opens.
    private static let gateLevel = NSWindow.Level.floating
    private static let stripLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    private var panel: GatePanel?
    private var extraPanels: [NSPanel] = []
    private let model = GateModel()
    /// v502: true once fingerprint or password was passed, until Indra loses focus. Replaces the old two-minute window:
    /// one check covers every crucial change for as long as the app stays in front.
    private var passedThisFocus = false
    private var lastPassAt = Date.distantPast
    private var resignObserver: NSObjectProtocol?
    private var pending: [() -> Void] = []
    private var authenticating = false
    private var cancelHandlers: [() -> Void] = []
    /// Changes with every gate that opens, so a late close from an old gate can never touch a newer one.
    private var gateID = 0

    private init() {
        // Losing focus ends the unlocked state: coming back and touching a crucial setting asks again.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appLostFocus() }
        }
    }

    private func appLostFocus() {
        // The gate itself (and Touch ID's system dialog) may briefly move focus; that must not undo a check in progress
        // or one that has only just passed.
        guard panel == nil, !authenticating, Date().timeIntervalSince(lastPassAt) > 1.0 else { return }
        passedThisFocus = false
    }

    /// The setting (on by default) and at least one way to pass: a password set for Face Lock, or Touch ID.
    /// With neither there is nothing to ask, so the section simply opens.
    var isEnabled: Bool {
        // v543: always on (the switch was removed). A "false" left behind by an older version is ignored.
        get { canVerify }
    }

    /// The switch the user sees (independent of whether a way to verify exists).
    var isSwitchedOn: Bool { true }

    var canVerify: Bool {
        FaceLockSecrets.hasPassword || Self.touchIDAvailable
    }

    static var touchIDAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// True while the prompt is on screen.
    var isPromptOpen: Bool { panel != nil }

    /// True while a check passed and Indra has stayed in focus since (so changing several settings never asks twice).
    var isOpen: Bool { !isEnabled || passedThisFocus }

    /// Ends the "already passed" state, so the next crucial change asks again.
    func lockAgain() { passedThisFocus = false }

    /// Runs `action` once the user has passed fingerprint or password. `force` ignores a recent successful check.
    func require(title: String = "Face Lock is locked", force: Bool = false, allowCancel: Bool = true,
                 onCancel: (() -> Void)? = nil, always: Bool = false, action: (() -> Void)? = nil) {
        // `always` ignores the "ask before opening" switch (used for quitting Face Lock): it asks whenever a way to verify exists.
        let needsCheck = always ? canVerify : isEnabled
        if !needsCheck || (!force && passedThisFocus) {
            action?()
            return
        }
        // A gate that was just passed is still fading out: run the action now instead of queueing it forever.
        if force, panel != nil, model.succeeded {
            action?()
            return
        }
        if let onCancel { cancelHandlers.append(onCancel) }
        if let action { pending.append(action) }
        present(title: title, allowCancel: allowCancel)
    }

    private func present(title: String, allowCancel: Bool) {
        // A gate that is already open keeps what was queued: it runs (or cancels) when that gate finishes.
        guard panel == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            // Nothing can be shown: whoever was waiting (for example "Quit Indra") must hear a "no", not wait forever.
            pending = []
            let handlers = cancelHandlers
            cancelHandlers = []
            handlers.forEach { $0() }
            return
        }
        gateID += 1
        model.title = title
        model.allowCancel = allowCancel
        model.status = ""
        model.showPassword = false
        model.canRetryFace = false
        model.succeeded = false
        model.touching = false
        model.onPassword = { [weak self] password in
            guard FaceLockSecrets.verify(password) else { return false }
            self?.succeed()
            return true
        }
        model.onTouch = { [weak self] in self?.touch() }
        model.onFace = {}
        model.onCancel = { [weak self] in self?.cancel() }

        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let main = GatePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        main.level = Self.gateLevel
        main.collectionBehavior = behavior
        main.isOpaque = false
        main.backgroundColor = .clear
        main.hasShadow = false
        main.hidesOnDeactivate = false
        main.contentView = NSHostingView(rootView: GateView(model: model))
        main.setFrame(screen.frame, display: true)
        panel = main

        for other in NSScreen.screens where other != screen {
            let cover = NSPanel(contentRect: other.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            cover.level = Self.gateLevel
            cover.collectionBehavior = behavior
            cover.isOpaque = false
            cover.backgroundColor = .clear
            cover.hasShadow = false
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: other.frame.size))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            cover.contentView = blur
            cover.setFrame(other.frame, display: true)
            cover.orderFrontRegardless()
            extraPanels.append(cover)
        }

        main.orderFrontRegardless()
        main.makeKey()
        showEdgeStrips()
        NSApp.activate(ignoringOtherApps: true)
        let shown = [main] + extraPanels
        shown.forEach { $0.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shown.forEach { $0.animator().alphaValue = 1 }
        }
    }

    // MARK: Fingerprint

    private func touch() {
        guard panel != nil, !authenticating else { return }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            model.status = "Touch ID isn't available. Use your password."
            return
        }
        authenticating = true
        FaceLockLog.note("gate: fingerprint prompt")
        model.touching = true
        let reason = model.title.hasPrefix("Quit") ? model.title : "Change Face Lock settings"
        Task { @MainActor [weak self] in
            var ok = false
            var message: String?
            do {
                ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
            } catch let err as LAError {
                switch err.code {
                case .userCancel, .systemCancel, .appCancel: break
                case .biometryLockout: message = "Touch ID is locked. Use your password."
                default: message = "Fingerprint not recognized. Try again or use your password."
                }
            } catch {}
            guard let self else { return }
            self.authenticating = false
            self.model.touching = false
            if ok {
                self.succeed()
            } else if let message {
                self.model.status = message
            }
        }
    }


    private var edgePanels: [NSPanel] = []

    /// While Touch ID is showing, the gate sits low so the system dialog stays visible, which lets the
    /// menu bar and Dock show through. Blur strips at the top level cover just those areas.
    private func showEdgeStrips() {
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        guard edgePanels.isEmpty else { return }
        let f = screen.frame, v = screen.visibleFrame
        // Each strip reaches `fade` points into the main blur and fades out there, so the two blurs merge smoothly.
        enum Side { case top, bottom, left, right }
        let fade: CGFloat = 170
        let bars: [(Side, CGFloat, NSRect)] = [
            (.top, f.maxY - v.maxY, NSRect(x: f.minX, y: v.maxY - fade, width: f.width, height: f.maxY - v.maxY + fade)),
            (.bottom, v.minY - f.minY, NSRect(x: f.minX, y: f.minY, width: f.width, height: v.minY - f.minY + fade)),
            (.left, v.minX - f.minX, NSRect(x: f.minX, y: v.minY, width: v.minX - f.minX + fade, height: v.height)),
            (.right, f.maxX - v.maxX, NSRect(x: v.maxX - fade, y: v.minY, width: f.maxX - v.maxX + fade, height: v.height))
        ].filter { $0.1 > 0.5 }
        for (side, _, r) in bars {
            let strip = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            strip.isOpaque = false
            strip.backgroundColor = .clear
            strip.hasShadow = false
            strip.level = Self.stripLevel
            strip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            strip.isReleasedWhenClosed = false
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: r.size))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            blur.maskImage = NSImage(size: r.size, flipped: false) { rect in
                NSColor.black.setFill()
                rect.fill()
                let zone: NSRect
                let angle: CGFloat
                switch side {
                case .top:    zone = NSRect(x: 0, y: 0, width: rect.width, height: fade); angle = 90
                case .bottom: zone = NSRect(x: 0, y: rect.height - fade, width: rect.width, height: fade); angle = 270
                case .left:   zone = NSRect(x: rect.width - fade, y: 0, width: fade, height: rect.height); angle = 180
                case .right:  zone = NSRect(x: 0, y: 0, width: fade, height: rect.height); angle = 0
                }
                NSColor.clear.setFill()
                zone.fill(using: .copy)
                // Eased (smoothstep) fade: no visible start or end, so the strip melts into the main blur.
                let steps = 12
                var locations: [CGFloat] = []
                var colors: [NSColor] = []
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    locations.append(t)
                    colors.append(NSColor.black.withAlphaComponent(t * t * (3 - 2 * t)))
                }
                NSGradient(colors: colors, atLocations: &locations, colorSpace: .deviceRGB)?.draw(in: zone, angle: angle)
                return true
            }
            // Cancels the extra darkness caused by the strip stacking on top of the main blur.
            let lift = NSView(frame: NSRect(origin: .zero, size: r.size))
            lift.wantsLayer = true
            lift.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            let liftMask = CAGradientLayer()
            liftMask.frame = lift.bounds
            let along: CGFloat = (side == .top || side == .bottom) ? r.height : r.width
            let frac = min(1, fade / max(along, 1))
            var liftColors: [CGColor] = []
            var liftLocations: [NSNumber] = []
            for i in 0...12 {
                let t = CGFloat(i) / 12
                liftColors.append(NSColor.black.withAlphaComponent(t * t * (3 - 2 * t)).cgColor)
                liftLocations.append(NSNumber(value: Double(t * frac)))
            }
            liftColors.append(NSColor.black.cgColor)
            liftLocations.append(1)
            liftMask.colors = liftColors
            liftMask.locations = liftLocations
            switch side {
            case .top:    liftMask.startPoint = CGPoint(x: 0.5, y: 0); liftMask.endPoint = CGPoint(x: 0.5, y: 1)
            case .bottom: liftMask.startPoint = CGPoint(x: 0.5, y: 1); liftMask.endPoint = CGPoint(x: 0.5, y: 0)
            case .left:   liftMask.startPoint = CGPoint(x: 1, y: 0.5); liftMask.endPoint = CGPoint(x: 0, y: 0.5)
            case .right:  liftMask.startPoint = CGPoint(x: 0, y: 0.5); liftMask.endPoint = CGPoint(x: 1, y: 0.5)
            }
            lift.layer?.mask = liftMask
            blur.addSubview(lift)
            strip.contentView = blur
            strip.orderFrontRegardless()
            edgePanels.append(strip)
        }
    }

    private func hideEdgeStrips() {
        for strip in edgePanels { strip.orderOut(nil) }
        edgePanels.removeAll()
    }
    private var gateLevelToken = 0

    // MARK: Result

    private func succeed() {
        // v494: a fingerprint that finishes after the gate was cancelled must not mark the check as passed
        // (or run anything), because nobody is looking at a gate any more.
        guard panel != nil, !model.succeeded else { return }
        cancelHandlers = []
        passedThisFocus = true
        lastPassAt = Date()
        model.succeeded = true
        let actions = pending
        pending = []
        // A short checkmark plays before the screen goes away.
        let id = gateID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if let self, self.gateID == id { self.closePanels() }
            actions.forEach { $0() }
        }
    }

    private func cancel() {
        pending = []
        let handlers = cancelHandlers
        cancelHandlers = []
        handlers.forEach { $0() }
        closePanels()
    }

    private func closePanels() {
        let closing: [NSPanel] = (panel.map { [$0] } ?? []) + extraPanels
        panel = nil
        extraPanels.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            closing.forEach { $0.orderOut(nil) }
            // Only if no newer gate has opened meanwhile; otherwise its strips would be removed.
            MainActor.assumeIsolated { if self?.panel == nil { self?.hideEdgeStrips() } }
        })
        // v501 failsafe: these windows cover whole screens at a very high level. The fade's completion handler is the only
        // thing that removed them, and it does not run if the animation is interrupted (display sleep, a screen change,
        // the window server busy). A cover that never leaves swallows every click and key. This removes them regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            closing.forEach { $0.alphaValue = 0; $0.ignoresMouseEvents = true; $0.orderOut(nil) }
            MainActor.assumeIsolated { if self?.panel == nil { self?.hideEdgeStrips() } }
        }
    }
}

// MARK: - v502: gating crucial changes

extension Binding {
    /// A binding whose writes only happen after fingerprint or password (a no-op prompt when the app was already
    /// unlocked this focus). Until then `get` keeps returning the old value, so a switch snaps back if the check is cancelled.
    @MainActor
    func gated(title: String = "Face Lock is locked") -> Binding<Value> {
        let source = self
        return Binding(
            get: { source.wrappedValue },
            set: { newValue in
                FaceLockGate.shared.require(title: title) { source.wrappedValue = newValue }
            }
        )
    }
}
