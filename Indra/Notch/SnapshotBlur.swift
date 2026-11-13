import AppKit
import CoreImage
import ScreenCaptureKit

/// Builds the "clear glass" backdrop off the main thread, so the notch's opening animation is never held up.
///
/// A one-shot picture of the desktop behind the notch (without Indra's own windows) is blurred at six
/// strengths. Every pixel then gets the blur that belongs to its distance from the notch outline: the
/// strongest blur right at the notch, easing steadily to sharp. The result is ONE finished image (the
/// blend is done here, pixel by pixel, no layer masks), with a soft dark tint baked in at the notch edge (all numbers: BlurTuning.swift).
/// Where the blur has faded out the image is transparent, so the live desktop shows through.
enum SnapshotBlurRenderer {
    struct Request {
        var displayID: CGDirectDisplayID?
        var screenFrame: CGRect
        var frame: CGRect
        var scale: CGFloat
        var notch: CGSize
        var corner: CGFloat
        var reach: CGFloat
        var radius: CGFloat
    }

    /// Number of blur strengths blended together. More = smoother gradient.
    private static let tierCount = 6
    /// The picture is taken and blurred at half resolution: the result is soft anyway, and it is 4x cheaper.
    private static let quality: CGFloat = 0.5

    private static let context = SharedCI.context
    nonisolated(unsafe) private static var cachedFilter: (id: CGDirectDisplayID?, filter: SCContentFilter, at: Date)?
    nonisolated(unsafe) private static var weightKey = ""
    nonisolated(unsafe) private static var weightCache: (wanted: [Float], shadow: [UInt8])?

    /// Which windows to leave out (Indra's own) is looked up once and reused for a while, because
    /// asking the system for it is slow.
    private static func contentFilter(for id: CGDirectDisplayID?) async throws -> SCContentFilter? {
        if let cached = cachedFilter, cached.id == id, Date().timeIntervalSince(cached.at) < 30 {
            return cached.filter
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        cachedFilter = (id, filter, Date())
        return filter
    }

    /// Per pixel: which blur strength is wanted (0 = none ... tierCount = strongest) and how dark the halo is.
    /// Depends only on the geometry, so it is built once and reused.
    private static func weights(width: Int, height: Int, k: CGFloat, request r: Request) -> (wanted: [Float], shadow: [UInt8]) {
        let key = "\(width)x\(height)-\(Int(r.notch.width * k))x\(Int(r.notch.height * k))-\(Int(r.reach * k))-\(Int(r.corner * k))"
        if key == weightKey, let weightCache { return weightCache }
        let notch = CGSize(width: r.notch.width * k, height: r.notch.height * k)
        let corner = r.corner * k
        let reach = max(r.reach * k, 2)
        let haloReach = max(BlurTuning.darkTintReach * k, 2)
        let centerX = CGFloat(width) / 2
        let halfWidth = notch.width / 2
        // Rounded box whose top corners sit above the screen edge, so the top stays flush.
        let boxCenterY = (notch.height - corner) / 2
        let halfHeight = (notch.height + corner) / 2
        var wanted = [Float](repeating: 0, count: width * height)
        var shadow = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let py = CGFloat(y) + 0.5
            for x in 0..<width {
                let px = CGFloat(x) + 0.5
                let qx = abs(px - centerX) - (halfWidth - corner)
                let qy = abs(py - boxCenterY) - (halfHeight - corner)
                let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - corner
                let t = min(max(distance / reach, 0), 1)
                let h = min(max(distance / haloReach, 0), 1)
                let index = y * width + x
                wanted[index] = Float(pow(1 - t, BlurTuning.softness) * CGFloat(tierCount))
                shadow[index] = UInt8(min(max(pow(1 - h, 2) * BlurTuning.darkTint, 0), 1) * 255)
            }
        }
        weightKey = key
        weightCache = (wanted, shadow)
        return (wanted, shadow)
    }

    /// Raw RGBA bytes of an image (first row = top).
    private static func pixels(of image: CGImage, width: Int, height: Int, space: CGColorSpace) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let bitmap = CGContext(data: raw.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    static func render(_ r: Request) async throws -> CGImage? {
        guard let filter = try await contentFilter(for: r.displayID) else { return nil }
        let k = r.scale * quality
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: r.frame.minX - r.screenFrame.minX,
                                   y: r.screenFrame.maxY - r.frame.maxY,
                                   width: r.frame.width,
                                   height: r.frame.height)
        config.width = max(Int((r.frame.width * k).rounded()), 2)
        config.height = max(Int((r.frame.height * k).rounded()), 2)
        config.showsCursor = false
        let shot: CGImage
        do {
            shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            cachedFilter = nil
            throw error
        }
        let width = shot.width
        let height = shot.height
        let count = width * height

        // Keep the desktop's own colour space so the blurred picture matches the live desktop exactly.
        let space: CGColorSpace = {
            if let own = shot.colorSpace,
               CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: own,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) != nil { return own }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()

        let input = CIImage(cgImage: shot)
        let extent = input.extent
        let clamped = input.clampedToExtent()
        var tiers: [[UInt8]] = []
        for level in 1...tierCount {
            let sigma = Double(r.radius * k) * Double(level) / Double(tierCount)
            let blurred = clamped.applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            guard let image = context.createCGImage(blurred, from: extent, format: .RGBA8, colorSpace: space),
                  let bytes = pixels(of: image, width: width, height: height, space: space) else {
                BackdropPanel.status = "snapshot: blur failed"
                return nil
            }
            tiers.append(bytes)
        }

        let map = weights(width: width, height: height, k: k, request: r)
        var out = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            let wanted = map.wanted[i]
            let edgeHalo = Float(map.shadow[i]) / 255
            // Dark layer over the whole blurred area: follows the blur, so it fades out with it.
            let areaTint = Float(BlurTuning.backgroundTintOpacity) * min(wanted / Float(tierCount), 1)
            let halo = 1 - (1 - edgeHalo) * (1 - areaTint)
            var red: Float = 0
            var green: Float = 0
            var blue: Float = 0
            var alpha: Float = 0
            if wanted > 0 {
                let base = i * 4
                if wanted < 1 {
                    // Fading out: the lightest blur, becoming see-through so the live desktop takes over.
                    red = Float(tiers[0][base])
                    green = Float(tiers[0][base + 1])
                    blue = Float(tiers[0][base + 2])
                    alpha = wanted
                } else {
                    // Between two blur strengths: mix the two neighbours.
                    let lower = min(Int(wanted), tierCount - 1)
                    let mix = min(wanted - Float(lower), 1)
                    let a = tiers[lower - 1]
                    let b = tiers[lower]
                    red = Float(a[base]) + (Float(b[base]) - Float(a[base])) * mix
                    green = Float(a[base + 1]) + (Float(b[base + 1]) - Float(a[base + 1])) * mix
                    blue = Float(a[base + 2]) + (Float(b[base + 2]) - Float(a[base + 2])) * mix
                    alpha = 1
                }
            }
            // Black halo over the blur (premultiplied result).
            let keep = 1 - halo
            let o = i * 4
            out[o] = UInt8(min(max(red * alpha * keep, 0), 255))
            out[o + 1] = UInt8(min(max(green * alpha * keep, 0), 255))
            out[o + 2] = UInt8(min(max(blue * alpha * keep, 0), 255))
            out[o + 3] = UInt8(min(max((alpha + halo * (1 - alpha)) * 255, 0), 255))
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else {
            BackdropPanel.status = "snapshot: could not build the image"
            return nil
        }
        return result
    }
}

/// "Clear glass" progressive blur around the open notch: shows the finished image from the renderer.
/// Needs the Screen Recording permission.
final class SnapshotBlurView: NSView {
    private let glassLayer = CALayer()
    private var generation = 0
    private var lastImage: CGImage?
    private var lastKey = ""
    private var lastAt = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        glassLayer.contentsGravity = .resize
        glassLayer.opacity = 0
        layer?.addSublayer(glassLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassLayer.frame = bounds
        CATransaction.commit()
    }

    /// Takes a new picture and blurs it in the background. `frame` is the backdrop window in screen coordinates.
    func refresh(screen: NSScreen, frame: NSRect, notch: CGSize, corner: CGFloat, reach: CGFloat, radius: CGFloat) {
        generation += 1
        let mine = generation
        let key = "\(Int(frame.width))x\(Int(frame.height))-\(Int(notch.width))x\(Int(notch.height))-\(Int(reach))-\(Int(radius * 10))"
        // A picture from a few seconds ago appears at once (no pop-in); a fresh one replaces it quietly.
        let cached: CGImage? = (key == lastKey && Date().timeIntervalSince(lastAt) < 8) ? lastImage : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassLayer.opacity = 0
        glassLayer.contents = nil
        CATransaction.commit()
        guard ScreenAccess.shared.isGranted(), frame.width > 2, frame.height > 2 else { return }
        if let cached { show(cached, key: key, animated: false) }

        let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
        let request = SnapshotBlurRenderer.Request(
            displayID: screen.deviceDescription[displayKey] as? CGDirectDisplayID,
            screenFrame: screen.frame,
            frame: frame,
            scale: screen.backingScaleFactor,
            notch: notch,
            corner: corner,
            reach: reach,
            radius: radius)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let image = try await SnapshotBlurRenderer.render(request) else { return }
                await MainActor.run {
                    guard let self, self.generation == mine else { return }
                    self.show(image, key: key, animated: cached == nil)
                }
            } catch {
                BackdropPanel.status = "snapshot failed: \(error.localizedDescription)"
                IndraLog.error("Notch blur: screen snapshot failed", error)
            }
        }
    }

    /// Only this small step runs on the main thread.
    private func show(_ image: CGImage, key: String, animated: Bool) {
        lastImage = image
        lastKey = key
        lastAt = Date()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassLayer.frame = bounds
        glassLayer.contents = image
        glassLayer.opacity = 1
        CATransaction.commit()
        BackdropPanel.status = "snapshot blur active"
        guard animated else { return }
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.3
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glassLayer.add(fadeIn, forKey: "fadeIn")
    }
}
