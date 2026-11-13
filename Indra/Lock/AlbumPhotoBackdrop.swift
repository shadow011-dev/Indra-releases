import AppKit
import CoreImage
import SwiftUI

/// The lock screen backdrop: the album photo fills the screen, softened by a blur you set in the app
/// (Lock screen > Background > Album blur), with a layer of clear glass on top. The colour gradient stays underneath,
/// so the wallpaper never shows through while a new song's photo fades in.
///
/// The blur is applied once, off the main thread, to a small copy of the photo (a blur hides all detail, so a
/// small picture stretched up looks the same). What is drawn is a plain picture with no live blur filter, so a
/// song change only crossfades two bitmaps instead of re-blurring two full-screen images on every frame.
struct AlbumPhotoBackdrop: View {
    let artwork: NSImage?
    /// Changes with every new song, so the old photo fades out while the new one fades in.
    let artworkID: Int
    let tones: [Color]
    var progress: (() -> Double)?
    var paused = false
    /// The album's animated cover, when it has one: it plays over the photo (which stays as its first frame).
    var motionURL: URL?
    var motionPlaying = false
    /// The blurred photo is on screen: the video may come out of the blur (see MotionVideoBackdrop).
    var motionReveal = false
    /// True while the lyrics are open on the vinyl.
    var lyricsActive = false
    @AppStorage(Preferences.lockBackdropBlurKey) private var blur = Preferences.lockBackdropBlurDefault
    @AppStorage(Preferences.lockBlurVideoKey) private var blurVideo = Preferences.lockBlurVideoDefault
    @AppStorage(Preferences.lockBackdropDarknessKey) private var darkness = Preferences.lockBackdropDarknessDefault
    /// The finished, already blurred pictures, oldest first. A new song's photo is added on top and fades in while the
    /// old one stays fully opaque underneath, so there is never a half-transparent moment where the gradient shows
    /// through (that dip is what made the background change look abrupt). Once the fade is over the old ones go.
    @State private var layers: [PhotoLayer] = []
    @State private var nextLayerID = 0
    @State private var trimToken = 0

    private struct PhotoLayer: Identifiable {
        let id: Int
        let image: NSImage
    }

    private struct Job: Equatable {
        let id: Int
        let blur: Double
        let hasArtwork: Bool
    }

    var body: some View {
        ZStack {
            // The static base (solid colour, gradient, photos) is flattened into one picture: fading the whole
            // backdrop in and out of the small card then blends a single bitmap instead of re-drawing every layer
            // on every frame, which is what made opening and closing the vinyl stutter on the lock screen.
            ZStack {
                // Solid colour at the very bottom: whatever happens at the edges, the wallpaper can never show.
                Rectangle().fill(tones.first ?? Color.black)
                CrossfadeBackdrop(tones: tones, progress: progress, paused: paused || !layers.isEmpty, crossfade: layers.isEmpty)
                ForEach(layers) { layer in
                    FadingIn(duration: 1.1) { photo(layer.image) }
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .drawingGroup(opaque: true)
            .animation(.easeInOut(duration: 0.8), value: layers.map(\.id))
            if let motionURL, Preferences.lockMotionArt {
                // The video gets 18% of the album blur (the slider still moves it up and down), so the movement stays
                // easy to see. With "Blur the video" on it is always blurred; with it off the video is sharp and the
                // same blur only comes in while the lyrics are open.
                MotionVideoBackdrop(url: motionURL, blur: (blurVideo || lyricsActive) ? blur * 0.18 : 0,
                                    playing: motionPlaying, reveal: motionReveal)
                    .id(motionURL)
                    .transition(.opacity)
            }
            // Darkness slider (Lock screen > Background): a black layer over the photo, under the glass sheen.
            Rectangle().fill(Color.black.opacity(min(max(darkness, 0), 1) * 0.8))
            glass
                .drawingGroup()
        }
        .animation(.easeInOut(duration: 0.6), value: motionURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: Job(id: artworkID, blur: blur, hasArtwork: artwork != nil)) { await prepare() }
    }

    /// Builds the blurred picture in the background and fades it in over the current one when it is ready.
    private func prepare() async {
        guard let artwork else {
            // No cover any more: the photos fade away into the gradient instead of cutting off.
            if !layers.isEmpty { layers = [] }
            return
        }
        guard let cg = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let radius = min(max(blur, 0), 120)
        let width = NSScreen.main?.frame.width ?? 1512
        let result: CGImage? = await Task.detached(priority: .userInitiated) {
            BackdropRender.make(cg, blur: radius, displayWidth: width)
        }.value
        guard !Task.isCancelled, let result else { return }
        let image = NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
        layers.append(PhotoLayer(id: nextLayerID, image: image))
        nextLayerID &+= 1
        // Skipping through songs quickly: the oldest pictures are fully covered by then, so dropping them is invisible.
        if layers.count > 4 { layers.removeFirst(layers.count - 4) }
        trimToken += 1
        let token = trimToken
        Task { @MainActor in
            // After the fade only the newest picture is kept (removed without animation: it is already covered).
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard token == trimToken, layers.count > 1 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { layers.removeFirst(layers.count - 1) }
        }
    }

    private func photo(_ image: NSImage) -> some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                // Enlarged a little so the soft edges stay off screen.
                .scaleEffect(1 + min(blur, 120) / 400)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Clear glass: a soft sheen along the top, a faint even veil, and a gentle fall-off at the corners.
    private var glass: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.04))
            Rectangle().fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.01), Color.clear],
                                            startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
            Rectangle().fill(RadialGradient(colors: [Color.clear, Color.black.opacity(0.16)],
                                            center: UnitPoint(x: 0.5, y: 0.45), startRadius: 450, endRadius: 1100))
        }
    }
}

/// Fades its content in from nothing when it first appears.
private struct FadingIn<Content: View>: View {
    let duration: Double
    @ViewBuilder let content: () -> Content
    @State private var opacity = 0.0

    var body: some View {
        content()
            .opacity(opacity)
            .onAppear { withAnimation(.easeInOut(duration: duration)) { opacity = 1 } }
    }
}

/// Makes the backdrop picture: a small copy of the album photo, blurred and slightly more colourful.
enum BackdropRender {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func make(_ source: CGImage, blur: Double, displayWidth: CGFloat) -> CGImage? {
        // The photo is shown about as wide as the screen. With a strong blur a very small copy is enough.
        let longest = CGFloat(max(source.width, source.height))
        let target: CGFloat = blur >= 12 ? 420 : (blur >= 4 ? 700 : 1100)
        let scale = min(1, target / longest)
        let width = max(CGFloat(source.width) * scale, 1)
        let sigma = blur * Double(width / max(displayWidth, 1))

        var image = CIImage(cgImage: source)
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = image.extent
        if sigma > 0.05 {
            image = image.clampedToExtent()
            image = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            image = image.cropped(to: extent)
        }
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.12])
        return context.createCGImage(image, from: extent)
    }
}
