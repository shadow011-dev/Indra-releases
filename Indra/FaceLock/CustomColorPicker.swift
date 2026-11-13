import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The user's own notch color, stored as a hex string. Used when the animation color is "custom".
enum CustomColor {
    /// What the user picked in the app (the settings page always shows this).
    static var storedHex: String { UserDefaults.standard.string(forKey: "faceLockAnimationHex") ?? "0A84FF" }

    /// What the animation uses right now: the album colour while the lock screen vinyl is open (see `FaceScanColor`),
    /// otherwise the picked colour.
    static var hex: String { FaceScanColor.albumActive ?? storedHex }

    static var nsColor: NSColor {
        let value = UInt32(hex, radix: 16) ?? 0x0A84FF
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    static var color: Color { Color(nsColor: nsColor) }
    /// The picked colour only (the swatch in settings).
    static var storedNSColor: NSColor {
        let value = UInt32(storedHex, radix: 16) ?? 0x0A84FF
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    static var storedColor: Color { Color(nsColor: storedNSColor) }

    /// Hue in degrees (0-360), the same scale the recolor uses.
    static var hue: Double {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Double(h) * 360
    }
    /// Grays and near-grays have no real hue, so the animation turns grayscale instead.
    static var isNeutral: Bool {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s < 0.12
    }

    static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Row under the color dots: choose a color from any photo, or from the current wallpaper.
struct CustomColorControl: View {
    @AppStorage("faceLockAnimationColor") private var selected = AnimationColor.blue.rawValue
    @AppStorage("faceLockAnimationHex") private var customHex = "0A84FF"
    @State private var pickerImage: NSImage?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 10) {
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Pick from photo…") { choosePhoto() }
            Button("Use wallpaper") { useWallpaper() }
            Button {
                selected = "custom"
            } label: {
                Circle()
                    .fill(CustomColor.color)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(selected == "custom" ? 0.95 : 0), lineWidth: 2)
                            .padding(-4)
                    )
                    .id(customHex)
            }
            .buttonStyle(.plain)
            .help("Your picked color #\(customHex)")
        }
        .sheet(isPresented: Binding(get: { pickerImage != nil }, set: { if !$0 { pickerImage = nil } })) {
            if let image = pickerImage {
                ColorPickSheet(image: image) { picked in
                    customHex = CustomColor.hexString(picked)
                    selected = "custom"
                    pickerImage = nil
                } onCancel: {
                    pickerImage = nil
                }
            }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a photo to pick a color from"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let image = NSImage(contentsOf: url) {
            message = nil
            pickerImage = image
        } else {
            message = "Couldn't open that image."
        }
    }

    private func useWallpaper() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              var url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            message = "Couldn't find the wallpaper. Use Pick from photo."
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = files.first(where: { ["jpg", "jpeg", "png", "heic", "tiff"].contains($0.pathExtension.lowercased()) })
            else { message = "Couldn't read the wallpaper. Use Pick from photo."; return }
            url = first
        }
        if let image = NSImage(contentsOf: url) {
            message = nil
            pickerImage = image
        } else {
            message = "Couldn't read the wallpaper. Use Pick from photo."
        }
    }
}

private final class PixelSource {
    let rep: NSBitmapImageRep?
    let size: CGSize
    init(image: NSImage) {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            rep = NSBitmapImageRep(cgImage: cg)
            size = CGSize(width: cg.width, height: cg.height)
        } else {
            rep = nil
            size = image.size
        }
    }
    func color(atFraction fx: CGFloat, _ fy: CGFloat) -> NSColor? {
        guard let rep else { return nil }
        let x = min(max(Int(fx * CGFloat(rep.pixelsWide)), 0), rep.pixelsWide - 1)
        let y = min(max(Int(fy * CGFloat(rep.pixelsHigh)), 0), rep.pixelsHigh - 1)
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
}

private struct ColorPickSheet: View {
    let image: NSImage
    let onUse: (NSColor) -> Void
    let onCancel: () -> Void

    @State private var source: PixelSource
    @State private var picked: NSColor?
    @State private var marker: CGPoint?
    private let boxSize = CGSize(width: 520, height: 330)

    init(image: NSImage, onUse: @escaping (NSColor) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onUse = onUse
        self.onCancel = onCancel
        _source = State(initialValue: PixelSource(image: image))
    }

    private var fitted: CGRect {
        let iw = max(source.size.width, 1), ih = max(source.size.height, 1)
        let scale = min(boxSize.width / iw, boxSize.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (boxSize.width - w) / 2, y: (boxSize.height - h) / 2, width: w, height: h)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Click anywhere on the picture to pick a color")
                .font(.system(size: 13, weight: .medium))
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: boxSize.width, height: boxSize.height)
                if let marker {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .background(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .position(marker)
                }
            }
            .frame(width: boxSize.width, height: boxSize.height)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in sample(value.location) })

            HStack(spacing: 10) {
                Circle()
                    .fill(picked.map { Color(nsColor: $0) } ?? Color.gray.opacity(0.3))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                Text(picked.map { "#" + CustomColor.hexString($0) } ?? "No color picked")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Use color") { if let picked { onUse(picked) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil)
            }
        }
        .padding(20)
        .frame(width: boxSize.width + 40)
    }

    private func sample(_ location: CGPoint) {
        let r = fitted
        guard r.contains(location) else { return }
        let fx = (location.x - r.minX) / r.width
        let fy = (location.y - r.minY) / r.height
        if let color = source.color(atFraction: fx, fy) {
            picked = color
            marker = location
        }
    }
}
