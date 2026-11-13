import AppKit

/// Menu bar glyph: red while the Mac is locked, white otherwise.
@MainActor
final class MenuBarIconTinter {
    static let shared = MenuBarIconTinter()

    private weak var button: NSStatusBarButton?
    private var started = false
    private var isLocked = false
    private var lastShown: Bool?
    private var pollTimer: Timer?

    /// Re-checks the secure session about twice a second and recolors the icon when it changes.
    private func refresh() {
        let locked = !SecureCredentialManager.isSessionUnlocked
        if locked != lastShown { apply() }
    }
    private var covers = Set<ObjectIdentifier>()

    /// Called by each app-lock cover when it appears or disappears. Red while any cover is up.
    func setCover(_ owner: AnyObject, shown: Bool) {
        let id = ObjectIdentifier(owner)
        if shown { covers.insert(id) } else { covers.remove(id) }
        apply()
    }

    /// Re-draws the icon right away (after the session is locked or unlocked from the menu).
    func refreshNow() { apply() }

    func attach(to button: NSStatusBarButton?) {
        self.button = button
        isLocked = LockMonitor.isScreenActuallyLocked()
        apply()
        guard !started else { return }
        started = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTimer?.tolerance = 0.4   // v507: was every 0.5 s with no slack; wake-ups are what costs idle CPU
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = true; self?.apply() }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = false; self?.apply() }
        }
    }

    private func apply() {
        let sessionLocked = !SecureCredentialManager.isSessionUnlocked
        lastShown = sessionLocked
        button?.image = Self.icon(locked: sessionLocked)
    }

    /// The menu bar symbol. Default is a face-unlock glyph; to try another one, quit Indra and run, for example:
    ///   defaults write com.indra.Indra menuBarSymbol -string "lock.shield.fill"
    /// (any SF Symbol name works; `defaults delete com.indra.Indra menuBarSymbol` returns to the default).
    /// Which icon to show. Default is "viewfinder". Change it by quitting Indra and running, for example:
    ///   defaults write com.indra.Indra menuBarSymbol -string "viewfinder"
    /// Built in: viewfinder, sunlock, monogram, eye. Any other value is treated as an SF Symbol name.
    /// `defaults delete com.indra.Indra menuBarSymbol` returns to the default.
    static func icon(locked: Bool) -> NSImage? {
        // Red while the Face Lock session is locked, otherwise the menu bar's own text colour (readable on light and dark).
        let color: NSColor = locked ? .systemRed : .labelColor
        let choice = UserDefaults.standard.string(forKey: "menuBarSymbol") ?? ""
        switch choice {
        // v529: the default is Indra's own menu bar icon (the MenuBarIcon asset), drawn in the red / label colour like the others.
        case "": return bundledIcon(color: color) ?? viewfinderIcon(color: color)
        case "viewfinder": return viewfinderIcon(color: color)
        case "sunlock": return sunLockIcon(color: color)
        case "monogram": return monogramIcon(color: color)
        case "eye", "lumen": return lumenEyeIcon(color: color)
        default: break
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let symbol = NSImage(systemSymbolName: choice, accessibilityDescription: "Indra")?.withSymbolConfiguration(config) {
            symbol.isTemplate = false
            return symbol
        }
        return sunLockIcon(color: color)
    }

    /// v529: Indra's own menu bar icon: the white shape in the MenuBarIcon asset, filled with `color` (red while locked, otherwise the
    /// menu bar's text colour, so it is readable on light and dark menu bars). Its see-through parts stay see-through.
    private static func bundledIcon(color: NSColor) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon"), base.size.width > 0, base.size.height > 0 else { return nil }
        // v568: the asset is the notch alone (98 x 50 px, the notch itself 82 px wide: the pill with its square and round cut-outs, no side pieces; its outline is the external notch's island curve, NotchShape exponent 2.6, corner radius = half the height), drawn so that the notch is 24
        // points wide in the menu bar.
        let scale: CGFloat = 24.0 / 82.0
        let size = NSSize(width: base.size.width * scale, height: base.size.height * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A small sun (Indra is light) with a keyhole cut out of its centre: light that guards.
    private static func sunLockIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            color.set()
            let rays = NSBezierPath()
            rays.lineWidth = 1.35
            rays.lineCapStyle = .round
            for k in 0..<8 {
                let a = CGFloat(k) * CGFloat.pi / 4
                rays.move(to: NSPoint(x: 9 + 6.7 * cos(a), y: 9 + 6.7 * sin(a)))
                rays.line(to: NSPoint(x: 9 + 8.3 * cos(a), y: 9 + 8.3 * sin(a)))
            }
            rays.stroke()

            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)).fill()

            // The keyhole is punched out, so the menu bar shows through it.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 7.65, y: 8.35, width: 2.7, height: 2.7)).fill()
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 8.3, y: 9.2))
            stem.line(to: NSPoint(x: 9.7, y: 9.2))
            stem.line(to: NSPoint(x: 10.3, y: 6.9))
            stem.line(to: NSPoint(x: 7.7, y: 6.9))
            stem.close()
            stem.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Four scan-frame corners around a light dot: the face scan.
    private static func viewfinderIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            color.set()
            let frame = NSBezierPath()
            frame.lineWidth = 1.7
            frame.lineCapStyle = .round
            frame.lineJoinStyle = .round
            for (sx, sy) in [(CGFloat(1), CGFloat(1)), (-1, 1), (1, -1), (-1, -1)] {
                let cx = 9 + sx * 7.4
                let cy = 9 + sy * 7.4
                frame.move(to: NSPoint(x: cx - sx * 4.6, y: cy))
                frame.line(to: NSPoint(x: cx, y: cy))
                frame.line(to: NSPoint(x: cx, y: cy - sy * 4.6))
            }
            frame.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.4, y: 6.4, width: 5.2, height: 5.2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A bold "L" with a four-point spark of light.
    private static func monogramIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            color.set()
            let letter = NSBezierPath()
            letter.lineWidth = 2.1
            letter.lineCapStyle = .round
            letter.lineJoinStyle = .round
            letter.move(to: NSPoint(x: 4.6, y: 15.6))
            letter.line(to: NSPoint(x: 4.6, y: 5.2))
            letter.curve(to: NSPoint(x: 6.2, y: 3.6), controlPoint1: NSPoint(x: 4.6, y: 4.3), controlPoint2: NSPoint(x: 5.3, y: 3.6))
            letter.line(to: NSPoint(x: 13.2, y: 3.6))
            letter.stroke()

            let spark = NSBezierPath()
            for k in 0..<8 {
                let a = CGFloat(k) * CGFloat.pi / 4 + CGFloat.pi / 2
                let r: CGFloat = k % 2 == 0 ? 3.6 : 0.9
                let point = NSPoint(x: 13.2 + r * cos(a), y: 12.6 + r * sin(a))
                if k == 0 { spark.move(to: point) } else { spark.line(to: point) }
            }
            spark.close()
            spark.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// An almond-shaped eye outline with a keyhole as the pupil: Indra watching, and locking. Drawn in code, so it stays
    /// sharp at any scale and takes the red / white colour directly.
    private static func lumenEyeIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { _ in
            color.set()

            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 1.2, y: 7))
            eye.curve(to: NSPoint(x: 18.8, y: 7), controlPoint1: NSPoint(x: 6, y: 13.6), controlPoint2: NSPoint(x: 14, y: 13.6))
            eye.curve(to: NSPoint(x: 1.2, y: 7), controlPoint1: NSPoint(x: 14, y: 0.4), controlPoint2: NSPoint(x: 6, y: 0.4))
            eye.close()
            eye.lineWidth = 1.6
            eye.lineJoinStyle = .round
            eye.stroke()

            let keyhole = NSBezierPath(ovalIn: NSRect(x: 7.8, y: 5.4, width: 4.4, height: 4.4))
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 9.0, y: 6.4))
            stem.line(to: NSPoint(x: 11.0, y: 6.4))
            stem.line(to: NSPoint(x: 11.9, y: 3.9))
            stem.line(to: NSPoint(x: 8.1, y: 3.9))
            stem.close()
            keyhole.append(stem)
            keyhole.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The old crescent-moon image, kept only as a fallback if the symbol name is not found.
    private static func legacyIcon(locked: Bool) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon"), base.size.height > 0 else { return nil }
        let height: CGFloat = 16
        let size = NSSize(width: height * base.size.width / base.size.height, height: height)
        let rect = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: rect)
        (locked ? NSColor.systemRed : NSColor.white).set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
