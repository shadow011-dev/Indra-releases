import AVFoundation
import AppKit
import SwiftUI

struct MirrorView: View {
    @ObservedObject var controller: MirrorController
    /// A rounded rectangle that fills the open notch (used at the Duo size) instead of the round preview.
    var rectangular = false
    private let diameter: CGFloat = 170
    @State private var shown = false
    @State private var hovering = false
    @State private var pressed = false
    var body: some View {
        Group {
            if rectangular { rectangleLayout } else { circleLayout }
        }
        // The box rises into place: a little scale, a clearing blur, a soft spring.
        .scaleEffect(shown ? 1 : 0.76, anchor: .top)
        .offset(y: shown ? 0 : -10)
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : 10)
        .animation(.spring(response: 0.56, dampingFraction: 0.82).delay(0.08), value: shown)
        .onAppear { shown = true }
    }

    private var circleLayout: some View {
        let shape = Circle()
        return surface(shape)
            .frame(width: diameter, height: diameter)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }

    /// 16:9, as tall as the open notch allows, centred.
    private var rectangleLayout: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = min(geo.size.width, height * 16 / 9)
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            surface(shape)
                .frame(width: width, height: height)
                .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The box: it shows the prompt until it is clicked, then the camera takes its place.
    private func surface<S: Shape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(Color.white.opacity(controller.activated ? 0.08 : (hovering ? 0.15 : 0.09)))
            feed(clippedTo: shape)
        }
        .contentShape(shape)
        .scaleEffect(pressed && !controller.activated ? 0.97 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: pressed)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.smooth(duration: 0.45), value: controller.activated)
        .onHover { hovering = $0 }
        .onTapGesture { tapped() }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !controller.activated { pressed = true } }
            .onEnded { _ in pressed = false })
    }

    /// A click on the box switches the camera on; the next one switches it off again (round box and Duo box alike).
    private func tapped() {
        pressed = false
        Haptics.hf2()
        if controller.activated {
            controller.stop()
        } else {
            controller.start()
        }
    }

    @ViewBuilder
    private func feed<S: Shape>(clippedTo shape: S) -> some View {
        if !controller.activated {
            ActivatePrompt(hovering: hovering, compact: !rectangular)
                .transition(.opacity.combined(with: .scale(scale: 1.08)))
        } else if controller.status == .authorized {
            if let session = controller.session {
                MirrorPreview(session: session)
                    .id(ObjectIdentifier(session))
                    .scaleEffect(x: -1, y: 1) // mirror image
                    .clipShape(shape)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            } else {
                ProgressView().controlSize(.small)
                    .transition(.opacity)
            }
        } else if controller.status == .notDetermined {
            ProgressView().controlSize(.small)
                .transition(.opacity)
        } else {
            deniedContent
        }
    }

    private var deniedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 20, weight: .semibold))
            Text("Camera access is off")
                .font(.system(size: 11, weight: .medium))
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
        }
        .foregroundStyle(Color.white.opacity(0.6))
    }
}

struct MirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer?.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer?.session !== session {
            nsView.previewLayer?.session = session
        }
    }
}

final class PreviewNSView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer?.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func makeBackingLayer() -> CALayer {
        AVCaptureVideoPreviewLayer()
    }
}

/// What the box says before the camera is switched on.
private struct ActivatePrompt: View {
    let hovering: Bool
    let compact: Bool
    @State private var breathe = false

    var body: some View {
        VStack(spacing: compact ? 9 : 11) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: compact ? 30 : 34, weight: .light))
                .scaleEffect(breathe ? 1.05 : 0.95)
                .symbolEffect(.bounce, value: hovering)
            Text("Click to activate mirror")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 118)
        }
        .foregroundStyle(Color.white.opacity(hovering ? 0.96 : 0.7))
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
