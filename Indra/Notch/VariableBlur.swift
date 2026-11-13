import AppKit

/// Progressive falloff mask: fully opaque at the notch outline, fading out with the
/// distance from it. Used as the blur-radius map (alpha = how strong the blur is).
enum BlurMaskFactory {
    static func make(size: CGSize, notch: CGSize, corner: CGFloat, reach: CGFloat, peak: CGFloat, gray: Bool = false, tail: CGFloat? = nil, exponent: CGFloat = 1.15) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 2, height > 2, reach > 1 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let centerX = CGFloat(width) / 2
        let halfWidth = notch.width / 2
        // Rounded box whose top corners sit above the screen edge, so the top stays flush.
        let boxCenterY = (notch.height - corner) / 2
        let halfHeight = (notch.height + corner) / 2

        for y in 0..<height {
            let py = CGFloat(y) + 0.5
            for x in 0..<width {
                let px = CGFloat(x) + 0.5
                let qx = abs(px - centerX) - (halfWidth - corner)
                let qy = abs(py - boxCenterY) - (halfHeight - corner)
                let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - corner
                let t = min(max(distance / reach, 0), 1)
                let falloff = 1 - t
                let alpha: CGFloat
                if let tail, !gray {
                    // Opaque almost everywhere; only the very end fades, so the picture has no visible edge.
                    alpha = min(falloff / tail, 1) * peak
                } else {
                    // Slow, steady fade: strongest at the outline, easing out to nothing at `reach`.
                    alpha = pow(falloff, exponent) * peak
                }
                let value = UInt8(min(max(alpha, 0), 1) * 255)
                let index = (y * width + x) * 4
                if gray {
                    // Opaque grey (white = full blur) for Core Image's masked variable blur.
                    pixels[index] = value
                    pixels[index + 1] = value
                    pixels[index + 2] = value
                    pixels[index + 3] = 255
                } else {
                    pixels[index + 3] = value
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

extension BlurMaskFactory {
    /// One alpha-only mask per blur level. Level k is fully visible where the wanted blur has reached
    /// level k and fades in from level k-1, so stacking the levels (most blurred on top) gives a smooth,
    /// steady blur gradient: strongest at the notch outline, sharp again at `reach`.
    static func makeTiers(size: CGSize, notch: CGSize, corner: CGFloat, reach: CGFloat,
                          count: Int, exponent: CGFloat) -> [CGImage]? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 2, height > 2, reach > 1, count > 0 else { return nil }

        var buffers = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height * 4), count: count)
        let centerX = CGFloat(width) / 2
        let halfWidth = notch.width / 2
        let boxCenterY = (notch.height - corner) / 2
        let halfHeight = (notch.height + corner) / 2

        for y in 0..<height {
            let py = CGFloat(y) + 0.5
            for x in 0..<width {
                let px = CGFloat(x) + 0.5
                let qx = abs(px - centerX) - (halfWidth - corner)
                let qy = abs(py - boxCenterY) - (halfHeight - corner)
                let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - corner
                let t = min(max(distance / reach, 0), 1)
                let wanted = pow(1 - t, exponent) * CGFloat(count)
                let index = (y * width + x) * 4 + 3
                for level in 0..<count {
                    let amount = min(max(wanted - CGFloat(level), 0), 1)
                    buffers[level][index] = UInt8(amount * 255)
                }
            }
        }
        var images: [CGImage] = []
        for pixels in buffers {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else { return nil }
            images.append(image)
        }
        return images
    }
}

/// A live, untinted, progressive blur of whatever is behind the window.
///
/// This uses the same system blur filter ("variableBlur") that the system's own backdrop
/// layers use. It is not documented by Apple, so it is looked up at runtime and every
/// step is checked: if anything is missing, `isActive` stays false and the caller uses a
/// regular system blur instead. No screen capture and no extra permission is involved.
final class VariableBlurView: NSVisualEffectView {
    private(set) var isActive = false
    private var filter: NSObject?
    private var backdropLayer: CALayer?
    private var builtKey = ""

    var notchSize = CGSize(width: 390, height: 175)
    var corner: CGFloat = 38
    var margin: CGFloat = 100
    var maxRadius: CGFloat = 28

    /// Shown in Settings so a failure can be reported.
    nonisolated(unsafe) static var status = "not started"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        appearance = NSAppearance(named: .darkAqua)
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reassertFilter()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reassertFilter()
    }

    /// The system can rebuild the material layers (window moves, appearance changes) and bring
    /// back its white-ish tint; put the untinted blur back whenever that happens.
    func reassertFilter() {
        guard isActive, let filter, let root = layer,
              let backdrop = VariableBlurView.findBackdrop(in: root, depth: 0) else { return }
        backdropLayer = backdrop
        if (backdrop.filters ?? []).count != 1 || backdrop.filters?.first as? NSObject !== filter {
            backdrop.filters = [filter]
        }
        stripTint(root: root, backdrop: backdrop)
    }

    /// The material paints its dark / light tint with layers next to the backdrop layer.
    /// Hide those, so only the plain blur of what is behind the window remains.
    private func stripTint(root: CALayer, backdrop: CALayer) {
        @discardableResult
        func strip(_ layer: CALayer) -> Bool {
            if layer === backdrop { return true }
            var containsBackdrop = false
            for sublayer in layer.sublayers ?? [] where strip(sublayer) { containsBackdrop = true }
            if containsBackdrop {
                if layer.backgroundColor != nil { layer.backgroundColor = nil }
                if layer.contents != nil { layer.contents = nil }
                if layer.compositingFilter != nil { layer.compositingFilter = nil }
                if layer.filters != nil { layer.filters = nil }
            } else if !layer.isHidden {
                layer.isHidden = true
            }
            return containsBackdrop
        }
        strip(root)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Returns true when the progressive blur could be set up.
    @discardableResult
    func activate() -> Bool {
        if isActive { return true }
        guard let root = layer else { VariableBlurView.status = "no layer"; return false }
        guard let backdrop = VariableBlurView.findBackdrop(in: root, depth: 0) else {
            VariableBlurView.status = "blur layer not found"
            return false
        }
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else {
            VariableBlurView.status = "CAFilter missing"
            return false
        }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
              let created = filterClass.perform(selector, with: "variableBlur")?.takeUnretainedValue() as? NSObject else {
            VariableBlurView.status = "variableBlur filter missing"
            return false
        }
        created.setValue(maxRadius, forKey: "inputRadius")
        created.setValue(true, forKey: "inputNormalizeEdges")
        filter = created
        backdropLayer = backdrop
        isActive = true
        VariableBlurView.status = "active"
        rebuildMask(force: true)
        return true
    }

    override func layout() {
        super.layout()
        rebuildMask(force: false)
        reassertFilter()
    }

    /// Applies a changed `maxRadius` to the live filter.
    func updateRadius() {
        guard isActive, let filter else { return }
        filter.setValue(maxRadius, forKey: "inputRadius")
    }

    func rebuildMask(force: Bool) {
        guard isActive, let filter, let backdrop = backdropLayer, bounds.width > 2 else { return }
        let key = "\(Int(bounds.width))x\(Int(bounds.height))-\(Int(notchSize.width))x\(Int(notchSize.height))-\(Int(margin))-\(Int(maxRadius))"
        guard force || key != builtKey else { return }
        guard let mask = BlurMaskFactory.make(size: bounds.size, notch: notchSize,
                                              corner: corner, reach: margin, peak: 1) else { return }
        builtKey = key
        filter.setValue(mask, forKey: "inputMaskImage")
        // Replace the standard material filters (blur + tint curves) with only the variable blur.
        backdrop.filters = [filter]
        if let root = layer { stripTint(root: root, backdrop: backdrop) }
    }

    /// The layer that blurs what is behind the window is a private "backdrop" layer;
    /// it is either this view's own layer or one of its sublayers.
    private static func findBackdrop(in layer: CALayer, depth: Int) -> CALayer? {
        if String(describing: type(of: layer)).contains("Backdrop") { return layer }
        guard depth < 3 else { return nil }
        for sublayer in layer.sublayers ?? [] {
            if let found = findBackdrop(in: sublayer, depth: depth + 1) { return found }
        }
        return nil
    }
}
