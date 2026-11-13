//
//  ScanAnimationView.swift
//  Indra Face Lock
//
//  Plays a scan animation once and holds its final frame — deliberately not
//  looping, since each video ends on a meaningful resolved state.
//

import SwiftUI
import AVFoundation
import AppKit
import CoreImage

/// Which media the overlay is showing. `.idle` is a still image (the first
/// frame of the success video) so the transition into a playing video is
/// seamless.
enum ScanMedia: Equatable {
    case idle
    case success
    case failure

    var videoResourceName: String? {
        switch self {
        case .idle: return nil
        case .success: return "unlockanimation"
        case .failure: return "unsuccessfulunlockanimation"
        }
    }
}

struct ScanAnimationView: NSViewRepresentable {
    let media: ScanMedia

    func makeNSView(context: Context) -> ScanAnimationHostView {
        let view = ScanAnimationHostView()
        view.setTransparent(FaceScanLook.translucent)
        view.apply(media: media)
        return view
    }

    func updateNSView(_ nsView: ScanAnimationHostView, context: Context) {
        nsView.setTransparent(FaceScanLook.translucent)
        nsView.apply(media: media)
        nsView.refreshForColourChange()
    }
}

final class ScanAnimationHostView: NSView {
    private var player: AVPlayer?
    private let playerLayer = AVPlayerLayer()
    private let stillImageLayer = CALayer()
    private var currentMedia: ScanMedia?
    private var stillKey = ""
    /// v485: the colour the video that is playing (or held on its last frame) was recoloured with.
    private var videoKey = ""
    /// True when the black plate of the video and still is made see-through (see `faceScanLumaToAlpha`).
    private var transparent = false
    private var currentStillKey: String { FaceScanColor.cacheKey + (transparent ? "|t" : "") }

    func setTransparent(_ value: Bool) {
        guard value != transparent else { return }
        transparent = value
        stillKey = ""
        // Rebuild what is showing with (or without) the transparency.
        let media = currentMedia
        currentMedia = nil
        if let media { apply(media: media) } else { refreshStill() }
    }
    private var readyObservation: NSKeyValueObservation?
    private var fallbackRevealWorkItem: DispatchWorkItem?

    private static let ciContext = SharedCI.context

    /// The user's chosen animation color (same key the settings picker writes).
    /// v468: the album colour while the lock screen vinyl is open, else the colour chosen in the app (see `FaceScanColor`).
    private static var selectedColor: AnimationColor { FaceScanColor.effective }

    private static let hosts = NSHashTable<ScanAnimationHostView>.weakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.hosts.add(self)
        wantsLayer = true
        layer = CALayer()

        stillImageLayer.contentsGravity = .resizeAspect
        refreshStill()
        layer?.addSublayer(stillImageLayer)

        playerLayer.videoGravity = .resizeAspect
        // BGRA output so the see-through version of the video (glass / translucent notch) keeps its alpha.
        playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        playerLayer.isOpaque = false
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillImageLayer.frame = bounds
        CATransaction.commit()
    }

    func apply(media: ScanMedia) {
        guard media != currentMedia else { return }
        currentMedia = media
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()

        guard let resource = media.videoResourceName else {
            teardownPlayer()
            refreshStill()
            // v495: without this the layer swap cross-faded over CALayer's default 0.25 s (the video fading out while the
            // still faded in, a visible ghost on a retry), unlike the instant swap the reveal below does on purpose.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.isHidden = true
            stillImageLayer.isHidden = false
            CATransaction.commit()
            return
        }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
            assertionFailure("\(resource).mp4 missing from bundle — check glance/Resources/")
            return
        }

        teardownPlayer()

        let asset = Self.preparedAsset(for: url)
        let item = AVPlayerItem(asset: asset)
        // Recolor both the success and failure videos with the chosen color (prepared ahead of time, see prewarmStill).
        if let composition = Self.recoloredComposition(for: asset, transparent: transparent) {
            item.videoComposition = composition
        }
        videoKey = currentStillKey
        let newPlayer = AVPlayer(playerItem: item)
        // This can play at the lock screen — never make noise.
        newPlayer.isMuted = true
        // Leaves the player paused on its final frame rather than rewinding.
        newPlayer.actionAtItemEnd = .none

        playerLayer.player = newPlayer
        player = newPlayer

        // Waits for `isReadyForDisplay` rather than a fixed delay, which raced the
        // real decode time and produced a black-frame flash.
        let reveal: () -> Void = { [weak self] in
            guard let self else { return }
            // Without disabling implicit actions, toggling `isHidden` cross-fades both
            // layers over CALayer's default duration instead of swapping instantly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.playerLayer.isHidden = false
            self.stillImageLayer.isHidden = true
            CATransaction.commit()
        }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                self?.fallbackRevealWorkItem?.cancel()
                reveal()
                self?.readyObservation = nil
            }
        }
        // Safety net only — if isReadyForDisplay never fires for some
        // reason, don't get stuck on the still forever.
        let fallback = DispatchWorkItem { reveal() }
        fallbackRevealWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)

        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    private func teardownPlayer() {
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()
        player?.pause()
        player = nil
        playerLayer.player = nil
    }

    /// Reloads the still frame, recolored to match the chosen animation color.
    /// The idle still is only rebuilt when the colour in use has changed (the album colour, or the app's choice).
    func refreshStillIfColourChanged() {
        guard currentMedia == nil || currentMedia == .idle, stillKey != currentStillKey else { return }
        refreshStill()
    }

    /// v485: the colour in use changed (the song changed while the lock screen vinyl is open, or the colour was picked in the
    /// app). The idle still is rebuilt as before; a success / failure video that is playing or held on its last frame is
    /// given the new colour table right now. Before, only the idle still followed, so a failed scan that stayed on screen kept
    /// the previous song's colour until the next scan.
    func refreshForColourChange() {
        refreshStillIfColourChanged()
        refreshVideoIfColourChanged()
    }

    private func refreshVideoIfColourChanged() {
        guard currentMedia == .success || currentMedia == .failure,
              let player, let item = player.currentItem,
              let asset = item.asset as? AVURLAsset,
              videoKey != currentStillKey else { return }
        videoKey = currentStillKey
        guard let composition = Self.recoloredComposition(for: asset, transparent: transparent) else { return }
        item.videoComposition = composition
        // v487: a video held on its last frame is not redrawn by itself, so the frame it is on is asked for again. v485 only
        // did that when `player.rate == 0`, but the player is created with `actionAtItemEnd = .none`, which keeps the rate
        // at 1 after the video has ended, so the held failure frame was never redrawn and stayed in the old song's colour.
        // Now: at the end (or when not playing) the player is paused and put back on the last real frame, which makes it
        // render that frame with the new colours. A video that is still playing picks the new colours up by itself.
        let duration = item.duration
        let now = item.currentTime()
        let atEnd = duration.isNumeric && duration.seconds > 0 && now.seconds >= duration.seconds - 0.08
        if atEnd || player.rate == 0 {
            var time = now
            if atEnd {
                time = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
                player.pause()
            }
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func refreshStill() {
        stillKey = currentStillKey
        // Recoloring the still is slow, and this used to run on the main thread every time the notch opened.
        // Build it once per colour and reuse it.
        if let image = Self.coloredStill(transparent: transparent) {
            // v495: `contents` animates implicitly (a 0.25 s cross-fade); the still is meant to change colour at once.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillImageLayer.contents = image
            CATransaction.commit()
        }
    }

    private static var stillCache: (key: String, image: Any)?

    private static func coloredStill(transparent: Bool) -> Any? {
        let key = FaceScanColor.cacheKey + (transparent ? "|t" : "")
        if let cache = stillCache, cache.key == key { return cache.image }
        guard let base = loadStillFromBundle() else { return nil }
        let image = tinted(base, with: selectedColor, transparent: transparent)
        stillCache = (key, image)
        return image
    }

    /// Gets everything the scan needs for the colour in use ready ahead of time (at launch, when the chosen colour changes,
    /// and when the album colour changes): the colour table is built in the background, then the still on screen and both
    /// videos are rebuilt. v476: before this, a colour change was only noticed at the next scan, on the main thread.
    static func prewarmStill() {
        let hexes = FaceScanColor.recolorHexes
        AnimationColor.prepareRecolors(hexes: hexes) {
            // The colour may have changed again while the tables were building: only use them if they are still the ones in use.
            guard FaceScanColor.recolorHexes == hexes else { return }
            let transparent = FaceScanLook.translucent
            _ = coloredStill(transparent: transparent)
            // The still on screen switches to the new colour right away, not at the next scan.
            for host in hosts.allObjects { host.refreshForColourChange() }
            // Load both videos and build their recolour filter now, so nothing heavy happens while the notch is animating.
            Task { @MainActor in
                for name in ["unlockanimation", "unsuccessfulunlockanimation"] {
                    guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { continue }
                    let asset = preparedAsset(for: url)
                    _ = try? await asset.load(.tracks, .duration)
                    _ = recoloredComposition(for: asset, transparent: transparent)
                }
            }
        }
    }

    private static var assetCache: [String: AVURLAsset] = [:]
    private static var compositionCache: [String: AVVideoComposition] = [:]

    private static func preparedAsset(for url: URL) -> AVURLAsset {
        if let cached = assetCache[url.path] { return cached }
        let asset = AVURLAsset(url: url)
        assetCache[url.path] = asset
        return asset
    }

    private static func recoloredComposition(for asset: AVURLAsset, transparent: Bool) -> AVVideoComposition? {
        let key = asset.url.path + "|" + FaceScanColor.cacheKey + (transparent ? "|t" : "")
        if let cached = compositionCache[key] { return cached }
        // v477: one colour, or the album gradient.
        let recolor = FaceScanColor.recolorFunction(for: FaceScanColor.recolorHexes)
        if recolor == nil && !transparent { return nil }
        // Compositions of colours that are no longer in use are dropped.
        if compositionCache.count > 12 { compositionCache.removeAll() }
        let composition = AVVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            var output = source
            if let recolor { output = recolor(source).cropped(to: source.extent) }
            if transparent { output = faceScanLumaToAlpha(output) }
            request.finish(with: output, context: nil)
        }
        compositionCache[key] = composition
        return composition
    }

    private static func tinted(_ image: NSImage, with color: AnimationColor, transparent: Bool) -> Any {
        let recolor = FaceScanColor.recolorFunction(for: FaceScanColor.recolorHexes)
        guard recolor != nil || transparent,
              let tiff = image.tiffRepresentation,
              let input = CIImage(data: tiff) else { return image }
        var output = input
        if let recolor { output = recolor(input).cropped(to: input.extent) }
        if transparent { output = faceScanLumaToAlpha(output) }
        return ciContext.createCGImage(output, from: input.extent) ?? image
    }

    /// The asset lives in Resources/ rather than an asset catalog, so
    /// `NSImage(named:)` won't find it — load by URL instead.
    private static func loadStillFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Turns the black plate of the scan videos and the still into transparency, keeping every colour as bright as it is on
/// the black plate (used when the notch body is glass or translucent).
/// v478: the alpha is the picture's brightest colour channel and the colour is scaled up to match, so the picture
/// composited over anything is the original colour plus the backdrop showing through the dark parts. Before, the colour
/// was multiplied by a luma-based alpha as well, which dimmed every colour and made the chosen colour look faded.
nonisolated func faceScanLumaToAlpha(_ image: CIImage) -> CIImage {
    let extent = image.extent
    guard let cube = CIFilter(name: "CIColorCube", parameters: [
            "inputCubeDimension": 64,
            "inputCubeData": faceScanNormalizeCube,
            kCIInputImageKey: image.settingAlphaOne(in: extent)
          ])?.outputImage else { return image }
    // White where the picture is bright, transparent where it is black.
    let mask = image.settingAlphaOne(in: extent)
        .applyingFilter("CIMaximumComponent")
        .applyingFilter("CIMaskToAlpha")
    return cube
        .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        .cropped(to: extent)
}

/// Colour table that scales every colour so its brightest channel is 1 (black stays black).
nonisolated private let faceScanNormalizeCube: Data = {
    let n = 64
    var values = [Float]()
    values.reserveCapacity(n * n * n * 4)
    for b in 0..<n {
        for g in 0..<n {
            for r in 0..<n {
                let rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
                let m = max(rf, gf, bf)
                if m < 0.0001 { values.append(contentsOf: [0, 0, 0, 1]) }
                else { values.append(contentsOf: [rf / m, gf / m, bf / m, 1]) }
            }
        }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
}()

/// Whether the scan body is see-through right now (desktop scan with the glass or translucent notch look).
enum FaceScanLook {
    @MainActor
    static var translucent: Bool {
        guard NotchOverlayController.shared.scanOnDesktop else { return false }
        if #available(macOS 26.0, *), Preferences.liquidGlass { return true }
        return (UserDefaults.standard.object(forKey: Preferences.translucentNotchKey) as? Bool) ?? true
    }
}
