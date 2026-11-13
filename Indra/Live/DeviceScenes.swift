import SwiftUI
import SceneKit
import AppKit

// MARK: - Wallpapers

/// Each device shows a wallpaper in the style of its own system default (painted here, not read from the Mac).
@MainActor
enum NativeWallpaper {
    private static var cache: [String: NSImage] = [:]

    static func texture(_ kind: BluetoothKind, aspect: CGFloat) -> NSImage {
        let key = "\(kind.rawValue)-\(Int(aspect * 1000))"
        if let cached = cache[key] { return cached }
        let w = 640
        let h = max(1, Int(CGFloat(w) / aspect))
        let image = bitmap(w, h) { ctx in
            let size = CGSize(width: w, height: h)
            switch kind {
            case .phone: bloom(ctx, size, sky: [(0.03, 0.05, 0.26), (0.10, 0.22, 0.70), (0.30, 0.45, 0.95)],
                               blobs: [(0.20, 0.78, 0.75, (0.20, 0.85, 1.00)), (0.85, 0.40, 0.70, (0.95, 0.25, 0.75)),
                                       (0.35, 0.08, 0.70, (1.00, 0.60, 0.25)), (0.75, 0.92, 0.55, (0.55, 0.35, 1.00))])
                lockScreenUI(ctx, size, clock: 1, buttons: true)
            case .tablet: bloom(ctx, size, sky: [(0.02, 0.10, 0.25), (0.05, 0.30, 0.55), (0.20, 0.55, 0.80)],
                                blobs: [(0.80, 0.80, 0.80, (0.30, 0.95, 0.85)), (0.15, 0.45, 0.75, (0.45, 0.35, 1.00)),
                                        (0.70, 0.12, 0.70, (1.00, 0.45, 0.55)), (0.30, 0.95, 0.50, (0.30, 0.70, 1.00))])
                lockScreenUI(ctx, size, clock: 0.82, buttons: false)
            case .desktop: bloom(ctx, size, sky: [(0.90, 0.92, 0.98), (0.80, 0.84, 0.97), (0.86, 0.80, 0.96)],
                                 blobs: [(0.15, 0.30, 0.80, (0.25, 0.50, 1.00)), (0.60, 0.80, 0.70, (0.75, 0.35, 0.95)),
                                         (0.90, 0.25, 0.70, (1.00, 0.45, 0.60)), (0.45, 0.10, 0.60, (1.00, 0.75, 0.30)),
                                         (0.95, 0.90, 0.55, (0.30, 0.85, 0.95))])
                desktopUI(ctx, size, lightBackground: true)
            default:
                dunes(ctx, size)
                desktopUI(ctx, size, lightBackground: false)
            }
        }
        cache[key] = image
        return image
    }

    /// Dark-to-bright gradient with big soft glowing colour blobs (x, y, radius, colour; all relative to the picture).
    private static func bloom(_ ctx: CGContext, _ size: CGSize, sky: [(CGFloat, CGFloat, CGFloat)],
                              blobs: [(CGFloat, CGFloat, CGFloat, (CGFloat, CGFloat, CGFloat))]) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = sky.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
        let u = max(size.width, size.height)
        for blob in blobs {
            let c = blob.3
            let glow = CGGradient(colorsSpace: space,
                                  colors: [CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.95),
                                           CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0)] as CFArray,
                                  locations: [0, 1])!
            let center = CGPoint(x: blob.0 * size.width, y: blob.1 * size.height)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: blob.2 * u * 0.6, options: [])
        }
    }

    /// Soft layered dunes under a dusk sky, like a macOS default.
    private static func dunes(_ ctx: CGContext, _ size: CGSize) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = size.width, h = size.height
        let sky = CGGradient(colorsSpace: space,
                             colors: [CGColor(red: 0.10, green: 0.16, blue: 0.45, alpha: 1),
                                      CGColor(red: 0.45, green: 0.40, blue: 0.80, alpha: 1),
                                      CGColor(red: 0.98, green: 0.72, blue: 0.62, alpha: 1)] as CFArray,
                             locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.35), options: [.drawsAfterEndLocation])
        let layers: [(CGFloat, CGFloat, CGColor, CGColor)] = [
            (0.46, 0.10, CGColor(red: 0.62, green: 0.48, blue: 0.80, alpha: 1), CGColor(red: 0.40, green: 0.32, blue: 0.70, alpha: 1)),
            (0.34, 0.14, CGColor(red: 0.42, green: 0.32, blue: 0.72, alpha: 1), CGColor(red: 0.22, green: 0.20, blue: 0.55, alpha: 1)),
            (0.20, 0.12, CGColor(red: 0.22, green: 0.20, blue: 0.55, alpha: 1), CGColor(red: 0.08, green: 0.10, blue: 0.32, alpha: 1)),
        ]
        for (index, layer) in layers.enumerated() {
            let base = h * layer.0, amp = h * layer.1
            let shift = CGFloat(index) * 0.9
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: base))
            let steps = 24
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                path.addLine(to: CGPoint(x: t * w, y: base + sin(t * 5.2 + shift) * amp * 0.5 + sin(t * 11 + shift * 2) * amp * 0.12))
            }
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let fill = CGGradient(colorsSpace: space, colors: [layer.2, layer.3] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: base + amp), end: CGPoint(x: 0, y: 0), options: [])
            ctx.restoreGState()
        }
    }
}

/// Draws into a bitmap (origin bottom-left, so the top of the picture is the top of the surface it is mapped on).
private func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: h))
}


// MARK: - Detail helpers

/// Text into a bitmap context (origin bottom-left). `x` is the left edge, or the centre when `centered`.
private func drawText(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                  weight: NSFont.Weight = .regular, color: NSColor = .white, centered: Bool = false) {
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let attributed = NSAttributedString(string: string,
                                        attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: color])
    let width = attributed.size().width
    attributed.draw(at: CGPoint(x: centered ? x - width / 2 : x, y: y))
    NSGraphicsContext.restoreGraphicsState()
}

/// The Apple logo in one colour (from the system symbol), centred on `center`.
private func logo(_ ctx: CGContext, center: CGPoint, height: CGFloat, color: NSColor) {
    guard let symbol = NSImage(systemSymbolName: "applelogo", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 80, weight: .regular)),
          symbol.size.height > 0 else { return }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        guard let g = NSGraphicsContext.current?.cgContext else { return false }
        symbol.draw(in: rect)
        g.setBlendMode(.sourceAtop)
        g.setFillColor(color.cgColor)
        g.fill(rect)
        return true
    }
    let width = symbol.size.width * height / symbol.size.height
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    tinted.draw(in: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
}

private func roundedRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, fill: CGColor) {
    ctx.setFillColor(fill)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
    ctx.fillPath()
}

/// A lock screen: date, big clock and (on the phone) the two corner buttons and the home bar.
private func lockScreenUI(_ ctx: CGContext, _ size: CGSize, clock: CGFloat, buttons: Bool) {
    let w = size.width, h = size.height
    drawText(ctx, "Sunday 25 October", x: w / 2, y: h * 0.845 - w * 0.058 * 0.6, size: w * 0.058, weight: .medium,
         color: NSColor(white: 1, alpha: 0.88), centered: true)
    drawText(ctx, "9:41", x: w / 2, y: h * 0.735 - w * 0.36 * clock * 0.6, size: w * 0.36 * clock, weight: .semibold,
         color: NSColor(white: 1, alpha: 0.94), centered: true)

    if buttons {
        for (cx, kind) in [(w * 0.15, 0), (w * 0.85, 1)] {
            let c = CGPoint(x: cx, y: h * 0.07)
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.38))
            ctx.fillEllipse(in: CGRect(x: c.x - w * 0.085, y: c.y - w * 0.085, width: w * 0.17, height: w * 0.17))
            if kind == 0 {   // torch
                roundedRect(ctx, CGRect(x: c.x - w * 0.018, y: c.y - w * 0.002, width: w * 0.036, height: w * 0.05), w * 0.008, fill: CGColor(gray: 1, alpha: 0.95))
                roundedRect(ctx, CGRect(x: c.x - w * 0.012, y: c.y - w * 0.05, width: w * 0.024, height: w * 0.044), w * 0.006, fill: CGColor(gray: 1, alpha: 0.95))
            } else {         // camera
                roundedRect(ctx, CGRect(x: c.x - w * 0.045, y: c.y - w * 0.03, width: w * 0.09, height: w * 0.065), w * 0.014, fill: CGColor(gray: 1, alpha: 0.95))
                ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.9))
                ctx.fillEllipse(in: CGRect(x: c.x - w * 0.018, y: c.y - w * 0.014, width: w * 0.036, height: w * 0.036))
            }
        }
        roundedRect(ctx, CGRect(x: w * 0.32, y: h * 0.014, width: w * 0.36, height: w * 0.012), w * 0.006, fill: CGColor(gray: 1, alpha: 0.75))
    }
}

/// A macOS desktop: a Finder window and the Dock.
private func desktopUI(_ ctx: CGContext, _ size: CGSize, lightBackground: Bool) {
    let w = size.width, h = size.height
    // Finder window with traffic lights, sidebar and a grid of folders.
    let win = CGRect(x: w * 0.20, y: h * 0.22, width: w * 0.60, height: h * 0.58)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.02), blur: h * 0.07, color: CGColor(gray: 0, alpha: 0.38))
    roundedRect(ctx, win, h * 0.03, fill: CGColor(gray: 0.97, alpha: 0.96))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: win, cornerWidth: h * 0.03, cornerHeight: h * 0.03, transform: nil))
    ctx.clip()
    ctx.setFillColor(CGColor(gray: 0.90, alpha: 1))
    ctx.fill(CGRect(x: win.minX, y: win.minY, width: win.width * 0.27, height: win.height))
    ctx.restoreGState()
    let lights: [(CGFloat, CGFloat, CGFloat)] = [(1.0, 0.36, 0.33), (1.0, 0.74, 0.20), (0.22, 0.80, 0.34)]
    for (i, c) in lights.enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        let r = h * 0.013
        ctx.fillEllipse(in: CGRect(x: win.minX + h * 0.03 + CGFloat(i) * h * 0.036, y: win.maxY - h * 0.045, width: r * 2, height: r * 2))
    }
    for i in 0..<5 {
        let y = win.maxY - h * 0.11 - CGFloat(i) * h * 0.065
        roundedRect(ctx, CGRect(x: win.minX + win.width * 0.035, y: y, width: h * 0.026, height: h * 0.026), h * 0.007,
                    fill: CGColor(red: 0.25, green: 0.52, blue: 0.95, alpha: 1))
        roundedRect(ctx, CGRect(x: win.minX + win.width * 0.035 + h * 0.04, y: y + h * 0.007, width: win.width * (0.10 + 0.01 * CGFloat(i % 3)), height: h * 0.012),
                    h * 0.005, fill: CGColor(gray: 0.55, alpha: 0.7))
    }
    let gridX = win.minX + win.width * 0.34
    for row in 0..<2 {
        for column in 0..<3 {
            let fx = gridX + CGFloat(column) * win.width * 0.2
            let fy = win.maxY - h * 0.2 - CGFloat(row) * h * 0.21
            roundedRect(ctx, CGRect(x: fx, y: fy, width: win.width * 0.13, height: h * 0.105), h * 0.015,
                        fill: CGColor(red: 0.36, green: 0.68, blue: 0.98, alpha: 1))
            roundedRect(ctx, CGRect(x: fx, y: fy + h * 0.085, width: win.width * 0.06, height: h * 0.028), h * 0.01,
                        fill: CGColor(red: 0.28, green: 0.58, blue: 0.94, alpha: 1))
            roundedRect(ctx, CGRect(x: fx + win.width * 0.01, y: fy - h * 0.034, width: win.width * 0.11, height: h * 0.012), h * 0.005,
                        fill: CGColor(gray: 0.5, alpha: 0.7))
        }
    }

    // Dock.
    let dockH = h * 0.12
    let dock = CGRect(x: w * 0.2, y: h * 0.012, width: w * 0.6, height: dockH)
    roundedRect(ctx, dock, dockH * 0.3, fill: CGColor(gray: 1, alpha: lightBackground ? 0.5 : 0.28))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
    ctx.setLineWidth(max(1, h * 0.003))
    ctx.addPath(CGPath(roundedRect: dock, cornerWidth: dockH * 0.3, cornerHeight: dockH * 0.3, transform: nil))
    ctx.strokePath()
    let icons: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.56, 1.0), (1.0, 0.36, 0.32), (0.25, 0.80, 0.46), (1.0, 0.76, 0.22),
                                                (0.62, 0.38, 0.96), (0.28, 0.80, 0.92), (1.0, 0.52, 0.26), (0.96, 0.38, 0.66), (0.56, 0.60, 0.68)]
    let icon = dockH * 0.74
    let gap = (dock.width - icon * CGFloat(icons.count)) / CGFloat(icons.count + 1)
    for (i, c) in icons.enumerated() {
        let rect = CGRect(x: dock.minX + gap + CGFloat(i) * (icon + gap), y: dock.minY + (dockH - icon) / 2, width: icon, height: icon)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: icon * 0.24, cornerHeight: icon * 0.24, transform: nil))
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let lighter = CGColor(red: min(1, c.0 + 0.16), green: min(1, c.1 + 0.16), blue: min(1, c.2 + 0.16), alpha: 1)
        let darker = CGColor(red: c.0 * 0.82, green: c.1 * 0.82, blue: c.2 * 0.82, alpha: 1)
        let shade = CGGradient(colorsSpace: space, colors: [lighter, darker] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shade, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }
}

/// A picture of a plate with the Apple logo on it (backs of the phone and the tablet, lid and back of the computers).
private func printedMaterial(aspect: CGFloat, base: (CGFloat, CGFloat, CGFloat), mark: NSColor, markHeight: CGFloat,
                             ring: Bool = false, rough: CGFloat = 0.62) -> SCNMaterial {
    let w = 640, h = max(1, Int(CGFloat(640) / aspect))
    let image = bitmap(w, h) { ctx in
        ctx.setFillColor(CGColor(red: base.0, green: base.1, blue: base.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        if ring {   // the faint wireless-charging ring
            ctx.setStrokeColor(mark.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(3)
            let r = CGFloat(w) * 0.30
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        logo(ctx, center: center, height: CGFloat(h) * markHeight, color: mark)
    }
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = image
    m.metalness.contents = 0.0
    m.roughness.contents = rough
    return m
}

/// A keyboard-shaped wedge (thicker at the back, -z) with rounded corners seen from above.
private func roundedWedge(width w: CGFloat, depth d: CGFloat, front hF: CGFloat, back hB: CGFloat,
                          radius r: CGFloat, _ material: SCNMaterial) -> SCNGeometry {
    var outline: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []   // x, z, and the corner centre it hangs from
    let corners: [(CGFloat, CGFloat, CGFloat)] = [(w / 2 - r, d / 2 - r, 0), (-(w / 2 - r), d / 2 - r, CGFloat.pi / 2),
                                                  (-(w / 2 - r), -(d / 2 - r), CGFloat.pi), (w / 2 - r, -(d / 2 - r), CGFloat.pi * 3 / 2)]
    for (cx, cz, start) in corners {
        for k in 0...10 {
            let angle = start + CGFloat(k) / 10 * CGFloat.pi / 2
            outline.append((cx + r * cos(angle), cz + r * sin(angle), cx, cz))
        }
    }
    let n = outline.count
    func top(_ z: CGFloat) -> CGFloat { hB + (hF - hB) * (z + d / 2) / d }
    let tilt = (hB - hF) / d
    let tiltLength = sqrt(1 + tilt * tilt)
    var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
    for o in outline {   // wall tops, then wall feet, then the top surface ring
        vertices.append(SCNVector3(o.0, top(o.1), o.1))
        normals.append(SCNVector3((o.0 - o.2) / r, 0, (o.1 - o.3) / r))
    }
    for o in outline {
        vertices.append(SCNVector3(o.0, 0, o.1))
        normals.append(SCNVector3((o.0 - o.2) / r, 0, (o.1 - o.3) / r))
    }
    for o in outline {
        vertices.append(SCNVector3(o.0, top(o.1), o.1))
        normals.append(SCNVector3(0, 1 / tiltLength, tilt / tiltLength))
    }
    vertices.append(SCNVector3(0, top(0), 0))
    normals.append(SCNVector3(0, 1 / tiltLength, tilt / tiltLength))
    var indices: [Int32] = []
    for k in 0..<n {
        let next = (k + 1) % n
        let t0 = Int32(k), t1 = Int32(next), b0 = Int32(n + k), b1 = Int32(n + next)
        indices += [t0, b0, t1, t1, b0, b1]
        indices += [Int32(2 * n + n), Int32(2 * n + next), Int32(2 * n + k)]
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    material.isDoubleSided = true
    geometry.materials = [material]
    return geometry
}

/// Just the logo, on a clear background.
private func logoOnly(_ color: NSColor) -> SCNMaterial {
    let image = bitmap(256, 256) { ctx in
        logo(ctx, center: CGPoint(x: 128, y: 128), height: 200, color: color)
    }
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = image
    m.isDoubleSided = true
    return m
}

/// A small lit-by-itself colour (camera dots, lens coatings, ports).
private func flat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = NSColor(red: r, green: g, blue: b, alpha: 1)
    return m
}

private func disc(_ radius: CGFloat, _ material: SCNMaterial) -> SCNGeometry {
    plane(radius * 2, radius * 2, radius: radius, material)
}

// MARK: - Materials and shapes

private func metal(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, rough: CGFloat, metalness: CGFloat = 1) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = NSColor(red: r, green: g, blue: b, alpha: 1)
    // Satin, never a mirror: no metalness, and a high roughness that only lets the lights leave a soft sheen.
    m.metalness.contents = 0.0
    m.roughness.contents = min(1, 0.46 + rough * 0.5)
    return m
}

/// A lit display: the picture glows on its own, it is not shaded by the lights.
private func screenMaterial(_ image: NSImage) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = image
    return m
}

/// Black glossy glass (device fronts, notch, camera lenses).
private func blackGlass() -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = NSColor(white: 0.015, alpha: 1)
    m.metalness.contents = 0.0
    m.roughness.contents = 0.3   // lets a glint of the key light sweep across the glass as the device turns
    return m
}

private func place(_ geometry: SCNGeometry, _ x: CGFloat = 0, _ y: CGFloat = 0, _ z: CGFloat = 0) -> SCNNode {
    let node = SCNNode(geometry: geometry)
    node.position = SCNVector3(x, y, z)
    return node
}

private func plane(_ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0, _ material: SCNMaterial) -> SCNGeometry {
    let p = SCNPlane(width: w, height: h)
    p.cornerRadius = radius
    p.materials = [material]
    return p
}

/// A rounded slab facing +z, centred on the origin, with softly rounded edges.
private func roundedSlab(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, radius: CGFloat, bevel: CGFloat, _ material: SCNMaterial) -> SCNNode {
    let path = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: -h / 2, width: w, height: h), xRadius: radius, yRadius: radius)
    path.flatness = 0.002
    let shape = SCNShape(path: path, extrusionDepth: d)
    shape.chamferRadius = bevel
    shape.chamferMode = .both
    shape.materials = [material]
    let node = SCNNode(geometry: shape)
    node.pivot = SCNMatrix4MakeTranslation(0, 0, d / 2)
    return node
}

private func cylinder(radius: CGFloat, height: CGFloat, _ material: SCNMaterial) -> SCNGeometry {
    let c = SCNCylinder(radius: radius, height: height)
    c.radialSegmentCount = 48
    c.materials = [material]
    return c
}

private func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, chamfer: CGFloat, _ material: SCNMaterial) -> SCNGeometry {
    let b = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
    b.materials = [material]
    return b
}


// MARK: - Mesh helpers

private func sgn(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

/// A smooth, flat-topped dome (the top of a Magic Mouse): a rounded-rectangle outline whose height falls
/// to zero with a vertical edge. `taper` narrows the front (+z), `backBoost` makes the back (-z) higher.
private func domeGeometry(a: CGFloat, b: CGFloat, height: CGFloat, taper: CGFloat, backBoost: CGFloat,
                          _ material: SCNMaterial) -> SCNGeometry {
    let rings = 30, segments = 112
    let squareness: CGFloat = 4.0
    var vertices: [SCNVector3] = []
    vertices.reserveCapacity((rings + 1) * segments)
    for i in 0...rings {
        let t = CGFloat(i) / CGFloat(rings)
        for j in 0..<segments {
            let theta = CGFloat(j) / CGFloat(segments) * 2 * .pi
            let c = cos(theta), s = sin(theta)
            let oz = b * sgn(s) * pow(abs(s), 2 / squareness)
            let ox = a * sgn(c) * pow(abs(c), 2 / squareness) * (1 - taper * oz / b)
            let x = ox * t, z = oz * t
            let profile = pow(max(0, 1 - pow(t, 3.4)), 0.55)
            vertices.append(SCNVector3(x, height * profile * (1 + backBoost * (-z / b)), z))
        }
    }
    var indices: [Int32] = []
    var normals = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: vertices.count)
    let below = SCNVector3(0, -height, 0)
    for i in 0..<rings {
        for j in 0..<segments {
            let j2 = (j + 1) % segments
            let v00 = Int32(i * segments + j), v01 = Int32(i * segments + j2)
            let v10 = Int32((i + 1) * segments + j), v11 = Int32((i + 1) * segments + j2)
            for var tri in [[v00, v10, v11], [v00, v11, v01]] {
                let p0 = vertices[Int(tri[0])], p1 = vertices[Int(tri[1])], p2 = vertices[Int(tri[2])]
                var n = cross(sub(p1, p0), sub(p2, p0))
                if dot(n, sub(p0, below)) < 0 { tri.swapAt(1, 2); n = SCNVector3(-n.x, -n.y, -n.z) }
                for v in tri {
                    let k = Int(v)
                    normals[k] = SCNVector3(normals[k].x + n.x, normals[k].y + n.y, normals[k].z + n.z)
                }
                indices.append(contentsOf: tri)
            }
        }
    }
    for k in normals.indices {
        let n = normals[k]
        let len = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1e-9)
        normals[k] = SCNVector3(n.x / len, n.y / len, n.z / len)
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    material.isDoubleSided = true
    geometry.materials = [material]
    return geometry
}

private func sub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
private func dot(_ a: SCNVector3, _ b: SCNVector3) -> CGFloat { a.x * b.x + a.y * b.y + a.z * b.z }
private func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

// MARK: - Device models

/// How the devices turn. The AirPods Pro pair looks the same every half turn, so it seems to repeat every 3 s;
/// a single device is turned once every 3.26 s (8% slower than a plain 3 s); v192 slows that by another 5% and v193 by 10% more.
enum DeviceSpin {
    static let seconds: TimeInterval = 3.26 / 0.95 / 0.9
}

@MainActor
enum DeviceScene {
    static func make(_ kind: BluetoothKind) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let model: SCNNode
        switch kind {
        case .phone: model = phone()
        case .tablet: model = tablet()
        case .laptop: model = laptop()
        case .desktop: model = desktop()
        case .mouse: model = mouse()
        case .keyboard: model = keyboard()
        case .watch: model = watch()
        case .speaker: model = speaker()
        default: model = phone()
        }

        // Fit every model in the same sphere and spin it around its own centre.
        let (center, radius) = model.boundingSphere
        let fit: CGFloat = kind == .keyboard ? 1.15 : (kind == .mouse ? 1.05 : (kind == .watch ? 1.18 : 1))
        let sphereRadius = CGFloat(radius)   // Float or CGFloat depending on the SDK
        var scale = 0.92 * fit / max(sphereRadius, 0.001)
        if kind == .laptop {
            // Wide and low: the sphere around it leaves the frame empty above and below, so size it by how far
            // its corners swing out sideways as it turns instead.
            let box = model.boundingBox
            let cx = CGFloat(center.x), cz = CGFloat(center.z)
            let dx = max(abs(CGFloat(box.max.x) - cx), abs(CGFloat(box.min.x) - cx))
            let dz = max(abs(CGFloat(box.max.z) - cz), abs(CGFloat(box.min.z) - cz))
            scale = 0.95 / max(sqrt(dx * dx + dz * dz), 0.001)
        }
        model.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        model.scale = SCNVector3(scale, scale, scale)
        let holder = SCNNode()
        holder.addChildNode(model)
        let seenFromAbove = kind == .keyboard || kind == .mouse
        let viewWidth: CGFloat = 2.108   // how much of the scene the camera sees across, at the distance used below
        if kind == .keyboard {
            // Not turning: seen from straight above, it slowly zooms in a little and slides up and to the right,
            // stopping with the keyboard's top-right corner at the corner of the picture. The picture is the
            // size of the album artwork, so the right-hand part of the keyboard fills it and its curved right
            // edge and top edge are in view.
            let keyboardWidth: CGFloat = 2.6
            let rest = 0.9 * viewWidth / keyboardWidth
            let zoomed = viewWidth / (0.45 * keyboardWidth) / 1.1   // 10% less zoom than showing the right 45%
            let margin = 0.06 * viewWidth
            let box = model.boundingBox
            let rightEdge = CGFloat(box.max.x) - CGFloat(center.x)   // from the keyboard's centre, in model units
            let topEdge = CGFloat(box.min.z) - CGFloat(center.z)     // the far (top) edge
            model.scale = SCNVector3(rest, rest, rest)
            model.runAction(.customAction(duration: 5) { node, elapsed in
                let c = min(max(elapsed / 5, 0), 1)
                let zoom = c * c * (3 - 2 * c)
                let s = rest + (zoomed - rest) * zoom
                node.scale = SCNVector3(s, s, s)
                let cornerX = viewWidth / 2 - margin   // where the top-right corner ends up on the picture
                let cornerZ = -(viewWidth / 2 - margin) + 0.05 * viewWidth   // a little lower than the corner
                node.position = SCNVector3(zoom * (cornerX - s * rightEdge), 0, zoom * (cornerZ - s * topEdge))
            })
        } else if kind == .mouse {
            model.eulerAngles.y = CGFloat.pi   // its narrow end toward the top of the picture
        } else {
            model.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: DeviceSpin.seconds)))
            // A slow, small nod so the top and the sides catch the light.
            let nodDown = SCNAction.rotateTo(x: 0.10, y: 0, z: 0, duration: 3, usesShortestUnitArc: true)
            let nodUp = SCNAction.rotateTo(x: -0.06, y: 0, z: 0, duration: 3, usesShortestUnitArc: true)
            nodDown.timingMode = .easeInEaseOut
            nodUp.timingMode = .easeInEaseOut
            holder.runAction(.repeatForever(.sequence([nodDown, nodUp])))
        }
        scene.rootNode.addChildNode(holder)

        // Soft studio light: an ambient fill, a warm key from above left, a cool fill from the right,
        // a rim light from behind and a faint bounce from below so no side goes flat.
        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, color: NSColor? = nil, euler: SCNVector3? = nil) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.intensity = intensity
            if let color { node.light?.color = color }
            if let euler { node.eulerAngles = euler }
            scene.rootNode.addChildNode(node)
        }
        light(.ambient, 380)
        light(.directional, 820, color: NSColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1), euler: SCNVector3(-0.7, -0.6, 0))
        light(.directional, 260, color: NSColor(red: 0.86, green: 0.92, blue: 1.0, alpha: 1), euler: SCNVector3(-0.25, 0.9, 0))
        light(.directional, 320, color: NSColor(red: 1.0, green: 0.93, blue: 0.85, alpha: 1), euler: SCNVector3(-0.3, 2.4, 0))
        light(.directional, 110, euler: SCNVector3(0.9, 0.2, 0))

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 24
        camera.camera?.zNear = 1
        camera.camera?.zFar = 20
        if seenFromAbove {
            // Straight down; the far edge of the device is the top of the picture.
            camera.position = SCNVector3(0, 4.96, 0)
            camera.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        } else {
            camera.position = SCNVector3(0, 0.7, 4.9)
            let target = SCNNode()
            scene.rootNode.addChildNode(target)
            camera.constraints = [SCNLookAtConstraint(target: target)]
        }
        scene.rootNode.addChildNode(camera)
        return scene
    }

    // MARK: iPhone

    private static func phone() -> SCNNode {
        let w: CGFloat = 0.97, h: CGFloat = 2.04, d: CGFloat = 0.105
        let root = SCNNode()
        let titanium = metal(0.86, 0.87, 0.89, rough: 0.30)
        root.addChildNode(roundedSlab(w, h, d, radius: 0.17, bevel: 0.03, titanium))

        // Frosted back glass.
        let backGlass = printedMaterial(aspect: (w - 0.04) / (h - 0.04), base: (0.87, 0.88, 0.90),
                                        mark: NSColor(red: 0.69, green: 0.70, blue: 0.74, alpha: 1), markHeight: 0.07, ring: true)
        let back = place(plane(w - 0.04, h - 0.04, radius: 0.15, backGlass), 0, 0, -d / 2 - 0.002)
        back.eulerAngles.y = .pi
        root.addChildNode(back)

        // Camera plateau and three lenses (top-left when you look at the back).
        let plateauZ = -d / 2 - 0.016
        let plateau = roundedSlab(0.55, 0.55, 0.026, radius: 0.13, bevel: 0.008, metal(0.89, 0.90, 0.92, rough: 0.25, metalness: 0.25))
        plateau.position = SCNVector3(w / 2 - 0.30, h / 2 - 0.30, plateauZ)
        root.addChildNode(plateau)
        let lensSpots: [(CGFloat, CGFloat)] = [(0.12, 0.13), (0.12, -0.13), (-0.11, 0)]
        for (lx, ly) in lensSpots {
            let ring = place(cylinder(radius: 0.098, height: 0.03, metal(0.74, 0.74, 0.76, rough: 0.22)),
                             w / 2 - 0.30 + lx, h / 2 - 0.30 + ly, plateauZ - 0.016)
            ring.eulerAngles.x = .pi / 2
            root.addChildNode(ring)
            let glass = place(cylinder(radius: 0.074, height: 0.03, blackGlass()),
                              w / 2 - 0.30 + lx, h / 2 - 0.30 + ly, plateauZ - 0.026)
            glass.eulerAngles.x = .pi / 2
            root.addChildNode(glass)
            // Deep blue lens coating with a small glint, like the rendered lenses on the product shots.
            let coating = place(disc(0.05, flat(0.07, 0.09, 0.25)), w / 2 - 0.30 + lx, h / 2 - 0.30 + ly, plateauZ - 0.0415)
            coating.eulerAngles.y = .pi
            root.addChildNode(coating)
            let glint = place(disc(0.011, flat(0.80, 0.86, 1.0)), w / 2 - 0.30 + lx + 0.02, h / 2 - 0.30 + ly + 0.024, plateauZ - 0.042)
            glint.eulerAngles.y = .pi
            root.addChildNode(glint)
        }
        let lidar = place(cylinder(radius: 0.034, height: 0.02, blackGlass()),
                          w / 2 - 0.30 - 0.11, h / 2 - 0.30 - 0.17, plateauZ - 0.012)
        lidar.eulerAngles.x = .pi / 2
        root.addChildNode(lidar)
        let flash = place(cylinder(radius: 0.028, height: 0.02, metal(0.95, 0.90, 0.70, rough: 0.3, metalness: 0)),
                          w / 2 - 0.30 - 0.11, h / 2 - 0.30 + 0.17, plateauZ - 0.014)
        flash.eulerAngles.x = .pi / 2
        root.addChildNode(flash)

        // Front: black glass, the wallpaper, the Dynamic Island and a pane of reflections.
        root.addChildNode(place(plane(w - 0.03, h - 0.03, radius: 0.155, blackGlass()), 0, 0, d / 2 + 0.002))
        let screenW = w - 0.075, screenH = h - 0.075
        root.addChildNode(place(plane(screenW, screenH, radius: 0.125,
                                      screenMaterial(NativeWallpaper.texture(.phone, aspect: screenW / screenH))), 0, 0, d / 2 + 0.004))
        root.addChildNode(place(plane(0.30, 0.09, radius: 0.045, blackGlass()), 0, h / 2 - 0.115, d / 2 + 0.006))
        // Inside the island: the front camera and the Face ID sensor.
        root.addChildNode(place(disc(0.017, flat(0.12, 0.13, 0.18)), 0.085, h / 2 - 0.115, d / 2 + 0.0072))
        root.addChildNode(place(disc(0.011, flat(0.06, 0.08, 0.24)), 0.085, h / 2 - 0.115, d / 2 + 0.0078))
        root.addChildNode(place(disc(0.0035, flat(0.60, 0.70, 1.0)), 0.081, h / 2 - 0.110, d / 2 + 0.0082))
        root.addChildNode(place(disc(0.012, flat(0.10, 0.10, 0.13)), -0.085, h / 2 - 0.115, d / 2 + 0.0072))

        // Side buttons.
        let button = metal(0.84, 0.85, 0.87, rough: 0.3)
        root.addChildNode(place(box(0.014, 0.30, 0.05, chamfer: 0.006, button), w / 2 + 0.004, 0.32, 0))
        root.addChildNode(place(box(0.014, 0.12, 0.05, chamfer: 0.006, button), -w / 2 - 0.004, 0.66, 0))
        root.addChildNode(place(box(0.014, 0.19, 0.05, chamfer: 0.006, button), -w / 2 - 0.004, 0.40, 0))
        root.addChildNode(place(box(0.014, 0.19, 0.05, chamfer: 0.006, button), -w / 2 - 0.004, 0.14, 0))
        return root
    }

    // MARK: iPad

    private static func tablet() -> SCNNode {
        let w: CGFloat = 1.42, h: CGFloat = 1.98, d: CGFloat = 0.052
        let root = SCNNode()
        let aluminium = metal(0.87, 0.88, 0.90, rough: 0.34)
        root.addChildNode(roundedSlab(w, h, d, radius: 0.11, bevel: 0.014, aluminium))

        root.addChildNode(place(plane(w - 0.02, h - 0.02, radius: 0.095, blackGlass()), 0, 0, d / 2 + 0.002))
        let screenW = w - 0.15, screenH = h - 0.15
        root.addChildNode(place(plane(screenW, screenH, radius: 0.045,
                                      screenMaterial(NativeWallpaper.texture(.tablet, aspect: screenW / screenH))), 0, 0, d / 2 + 0.004))

        // Back plate with the logo, the front camera, and the speaker holes along both sides.
        let backPlate = place(plane(w - 0.03, h - 0.03, radius: 0.10,
                                    printedMaterial(aspect: (w - 0.03) / (h - 0.03), base: (0.87, 0.88, 0.90),
                                                    mark: NSColor(red: 0.66, green: 0.67, blue: 0.71, alpha: 1), markHeight: 0.05)),
                              0, 0, -d / 2 - 0.002)
        backPlate.eulerAngles.y = .pi
        root.addChildNode(backPlate)
        root.addChildNode(place(disc(0.016, flat(0.12, 0.13, 0.18)), 0, h / 2 - 0.037, d / 2 + 0.0056))
        root.addChildNode(place(disc(0.010, flat(0.06, 0.08, 0.24)), 0, h / 2 - 0.037, d / 2 + 0.0062))
        let hole = flat(0.30, 0.31, 0.34)
        for side in [CGFloat(-1), CGFloat(1)] {
            for row in 0..<4 {
                for anchor in [CGFloat(1), CGFloat(-1)] {
                    let dot = place(disc(0.0065, hole), side * (w / 2 + 0.0012), anchor * (h / 2 - 0.16 - CGFloat(row) * 0.026), 0)
                    dot.eulerAngles.y = side * CGFloat.pi / 2
                    root.addChildNode(dot)
                }
            }
        }

        // Rear camera (top-left when you look at the back) and the power button on top.
        let cameraX = w / 2 - 0.15, cameraY = h / 2 - 0.15
        let housing = place(cylinder(radius: 0.085, height: 0.02, metal(0.88, 0.88, 0.90, rough: 0.22)), cameraX, cameraY, -d / 2 - 0.008)
        housing.eulerAngles.x = .pi / 2
        root.addChildNode(housing)
        let lens = place(cylinder(radius: 0.058, height: 0.02, blackGlass()), cameraX, cameraY, -d / 2 - 0.016)
        lens.eulerAngles.x = .pi / 2
        root.addChildNode(lens)
        root.addChildNode(place(box(0.20, 0.012, 0.03, chamfer: 0.005, metal(0.78, 0.78, 0.80, rough: 0.3)), -w / 2 + 0.3, h / 2 + 0.003, 0))
        return root
    }

    // MARK: MacBook

    private static func laptop() -> SCNNode {
        let w: CGFloat = 1.95, depth: CGFloat = 1.30, baseH: CGFloat = 0.07, lidT: CGFloat = 0.05
        let root = SCNNode()
        let silver = metal(0.80, 0.80, 0.82, rough: 0.28)

        root.addChildNode(place(box(w, baseH, depth, chamfer: 0.02, silver), 0, 0, 0))
        let keyboardAspect = (w - 0.04) / (depth - 0.04)
        let deck = place(plane(w - 0.04, depth - 0.04, keyboardMaterial(aspect: keyboardAspect)), 0, baseH / 2 + 0.002, 0)
        deck.eulerAngles.x = -.pi / 2
        root.addChildNode(deck)

        // Dark hinge barrel along the back edge and the three ports on the left side.
        let barrel = place(cylinder(radius: 0.02, height: w - 0.30, metal(0.30, 0.30, 0.33, rough: 0.5)),
                           0, baseH / 2 + 0.002, -depth / 2 + 0.02)
        barrel.eulerAngles.z = CGFloat.pi / 2
        root.addChildNode(barrel)
        for (z, length) in [(CGFloat(-0.32), CGFloat(0.05)), (CGFloat(-0.20), CGFloat(0.045)), (CGFloat(-0.08), CGFloat(0.045))] {
            let port = place(plane(length, 0.012, radius: 0.006, flat(0.07, 0.07, 0.08)), -w / 2 - 0.001, 0, z)
            port.eulerAngles.y = -CGFloat.pi / 2
            root.addChildNode(port)
        }

        // The lid hinges on the back edge and leans back a little past upright.
        let hinge = SCNNode()
        hinge.position = SCNVector3(0, baseH / 2 + 0.004, -depth / 2 + 0.02)
        hinge.eulerAngles.x = -105 * .pi / 180
        root.addChildNode(hinge)

        let whiteLid = metal(0.95, 0.95, 0.96, rough: 0.32)
        hinge.addChildNode(place(box(w, lidT, depth, chamfer: 0.016, whiteLid), 0, lidT / 2, depth / 2))
        // The logo on the outside of the lid (its top edge toward the open edge of the lid).
        let lidPlate = place(plane(w - 0.04, depth - 0.04, radius: 0.012,
                                   printedMaterial(aspect: (w - 0.04) / (depth - 0.04), base: (0.95, 0.95, 0.96),
                                                   mark: NSColor(white: 0.66, alpha: 1), markHeight: 0.15, rough: 0.45)),
                             0, lidT + 0.002, depth / 2)
        lidPlate.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, CGFloat.pi)
        hinge.addChildNode(lidPlate)
        let bezel = place(plane(w - 0.05, depth - 0.04, radius: 0.03, blackGlass()), 0, -0.002, depth / 2)
        bezel.eulerAngles.x = .pi / 2
        hinge.addChildNode(bezel)
        let screenW = w - 0.10, screenH = depth - 0.09
        let screen = place(plane(screenW, screenH, radius: 0.012,
                                 screenMaterial(NativeWallpaper.texture(.laptop, aspect: screenW / screenH))), 0, -0.004, depth / 2 - 0.01)
        screen.eulerAngles.x = .pi / 2
        hinge.addChildNode(screen)
        let notch = place(plane(0.22, 0.048, radius: 0.016, blackGlass()), 0, -0.006, depth - 0.065)
        notch.eulerAngles.x = .pi / 2
        hinge.addChildNode(notch)
        let camera = place(disc(0.0085, flat(0.07, 0.09, 0.26)), 0, -0.0072, depth - 0.065)
        camera.eulerAngles.x = .pi / 2
        hinge.addChildNode(camera)
        return root
    }

    /// The deck of the laptop: keys, trackpad and a silver surface, drawn as one picture.
    private static func keyboardMaterial(aspect: CGFloat) -> SCNMaterial {
        let w = 1200, h = Int(1200 / aspect)
        let image = bitmap(w, h) { ctx in
            ctx.setFillColor(CGColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let regionW = CGFloat(w) * 0.78
            let left = (CGFloat(w) - regionW) / 2
            let unit = regionW / 14
            var top = CGFloat(h) * 0.07
            // Speaker grilles either side of the keys.
            ctx.setFillColor(CGColor(gray: 0.46, alpha: 1))
            for side in [CGFloat(0), CGFloat(1)] {
                for column in 0..<4 {
                    let x = side == 0 ? left * 0.28 + CGFloat(column) * left * 0.17
                                      : CGFloat(w) - left * 0.28 - CGFloat(column) * left * 0.17
                    var y = CGFloat(h) * 0.47
                    while y < CGFloat(h) * 0.92 {
                        ctx.fillEllipse(in: CGRect(x: x - 2.5, y: y, width: 5, height: 5))
                        y += 13
                    }
                }
            }
            ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
            for row in 0..<6 {
                let rowH = (row == 0 ? 0.6 : 1.0) * unit
                for column in 0..<14 {
                    let rect = CGRect(x: left + CGFloat(column) * unit + 4,
                                      y: CGFloat(h) - top - rowH + 4,
                                      width: unit - 8, height: rowH - 8)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
                    ctx.fillPath()
                }
                top += rowH
            }
            let pad = CGRect(x: CGFloat(w) * 0.31, y: CGFloat(h) * 0.05, width: CGFloat(w) * 0.38, height: CGFloat(h) * 0.30)
            ctx.setFillColor(CGColor(red: 0.84, green: 0.84, blue: 0.86, alpha: 1))
            ctx.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
            ctx.setLineWidth(3)
            ctx.addPath(CGPath(roundedRect: pad, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.drawPath(using: .fillStroke)
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image
        m.metalness.contents = 0.0
        m.roughness.contents = 1.0
        return m
    }

    // MARK: iMac

    private static func desktop() -> SCNNode {
        let w: CGFloat = 1.90, h: CGFloat = 1.42, d: CGFloat = 0.06, chin: CGFloat = 0.31
        let root = SCNNode()
        let bodyColor = metal(0.95, 0.95, 0.96, rough: 0.38, metalness: 0.35)
        root.addChildNode(roundedSlab(w, h, d, radius: 0.04, bevel: 0.012, bodyColor))

        // White bezel, coloured chin, then the screen.
        let bezel = metal(0.96, 0.96, 0.97, rough: 0.35, metalness: 0)
        root.addChildNode(place(plane(w - 0.02, h - 0.02, radius: 0.03, bezel), 0, 0, d / 2 + 0.002))
        let chinPlane = printedMaterial(aspect: (w - 0.02) / chin, base: (0.50, 0.67, 0.86),
                                        mark: NSColor(white: 1, alpha: 0.94), markHeight: 0.42, rough: 0.5)
        root.addChildNode(place(plane(w - 0.02, chin, chinPlane), 0, -h / 2 + chin / 2 + 0.01, d / 2 + 0.004))
        // Camera in the top bezel.
        root.addChildNode(place(disc(0.016, flat(0.12, 0.13, 0.18)), 0, h / 2 - 0.035, d / 2 + 0.0068))
        root.addChildNode(place(disc(0.010, flat(0.06, 0.08, 0.24)), 0, h / 2 - 0.035, d / 2 + 0.0074))
        let screenW = w - 0.16, screenH = h - chin - 0.09
        root.addChildNode(place(plane(screenW, screenH,
                                      screenMaterial(NativeWallpaper.texture(.desktop, aspect: screenW / screenH))),
                                0, h / 2 - 0.07 - screenH / 2, d / 2 + 0.006))

        // Back panel, neck and foot.
        let backPanel = printedMaterial(aspect: (w - 0.02) / (h - 0.02), base: (0.60, 0.75, 0.91),
                                        mark: NSColor(white: 1, alpha: 0.95), markHeight: 0.13, rough: 0.5)
        let back = place(plane(w - 0.02, h - 0.02, radius: 0.03, backPanel), 0, 0, -d / 2 - 0.002)
        back.eulerAngles.y = .pi
        root.addChildNode(back)
        let stand = metal(0.93, 0.93, 0.94, rough: 0.33, metalness: 0.5)
        root.addChildNode(place(box(0.22, 0.66, 0.035, chamfer: 0.01, stand), 0, -h / 2 - 0.16, -0.08))
        root.addChildNode(place(box(0.66, 0.03, 0.52, chamfer: 0.012, stand), 0, -h / 2 - 0.50, -0.02))
        return root
    }

    // MARK: Magic Mouse

    private static func mouse() -> SCNNode {
        let a: CGFloat = 0.52, b: CGFloat = 1.0, height: CGFloat = 0.20
        let root = SCNNode()
        let white = metal(0.96, 0.96, 0.97, rough: 0.45)
        let silver = metal(0.80, 0.81, 0.83, rough: 0.6)
        let seam = metal(0.14, 0.14, 0.15, rough: 1)

        // Aluminium base plate with a dark gap line above it, then the white multi-touch shell.
        let outline = NSBezierPath()
        let steps = 112
        for k in 0..<steps {
            let theta = CGFloat(k) / CGFloat(steps) * 2 * .pi
            let c = cos(theta), s = sin(theta)
            let oz = b * sgn(s) * pow(abs(s), 0.5)
            let ox = a * sgn(c) * pow(abs(c), 0.5) * (1 - 0.10 * oz / b)
            let point = CGPoint(x: ox, y: -oz)   // flipped: the shape is laid down by a quarter turn below
            if k == 0 { outline.move(to: point) } else { outline.line(to: point) }
        }
        outline.close()
        outline.flatness = 0.002
        func plate(_ scale: CGFloat, _ thickness: CGFloat, _ material: SCNMaterial, y: CGFloat) -> SCNNode {
            let shape = SCNShape(path: outline, extrusionDepth: thickness)
            shape.chamferRadius = 0.006
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            node.scale = SCNVector3(scale, scale, 1)
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(0, y, 0)
            return node
        }
        root.addChildNode(plate(0.985, 0.045, silver, y: -0.045))
        // Two rails and the charging port under the base.
        for side in [CGFloat(-1), CGFloat(1)] {
            root.addChildNode(place(box(0.03, 0.012, 1.3, chamfer: 0.004, metal(0.34, 0.35, 0.38, rough: 0.6)), side * 0.28, -0.074, 0))
        }
        let port = place(plane(0.12, 0.03, radius: 0.015, flat(0.06, 0.06, 0.07)), 0, -0.0679, 0.85)
        port.eulerAngles.x = CGFloat.pi / 2
        root.addChildNode(port)
        root.addChildNode(plate(0.995, 0.012, seam, y: -0.004))
        root.addChildNode(place(domeGeometry(a: a, b: b, height: height, taper: 0.10, backBoost: 0.18, white), 0, 0, 0))
        // The logo on top, toward the wide end.
        let mark = place(plane(0.2, 0.2, logoOnly(NSColor(white: 0.66, alpha: 1))), 0, 0.215, -0.5)
        mark.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, CGFloat.pi)
        root.addChildNode(mark)
        return root
    }

    // MARK: Apple Watch

    private static func watch() -> SCNNode {
        let w: CGFloat = 0.82, h: CGFloat = 0.98, d: CGFloat = 0.17
        let root = SCNNode()
        let aluminium = metal(0.80, 0.81, 0.83, rough: 0.3)
        root.addChildNode(roundedSlab(w, h, d, radius: 0.22, bevel: 0.04, aluminium))

        // Front: black glass and a screen with the three activity rings.
        root.addChildNode(place(plane(w - 0.03, h - 0.03, radius: 0.20, blackGlass()), 0, 0, d / 2 + 0.002))
        let screenW = w - 0.10, screenH = h - 0.10
        root.addChildNode(place(plane(screenW, screenH, radius: 0.15, watchFace(aspect: screenW / screenH)), 0, 0, d / 2 + 0.004))

        // Digital Crown with its red ring, and the side button.
        let crown = place(cylinder(radius: 0.058, height: 0.07, metal(0.76, 0.77, 0.79, rough: 0.35)), w / 2 + 0.03, 0.17, 0)
        crown.eulerAngles.z = CGFloat.pi / 2
        root.addChildNode(crown)
        let ring = place(cylinder(radius: 0.063, height: 0.014, flat(0.92, 0.22, 0.20)), w / 2 + 0.012, 0.17, 0)
        ring.eulerAngles.z = CGFloat.pi / 2
        root.addChildNode(ring)
        root.addChildNode(place(box(0.035, 0.20, 0.07, chamfer: 0.012, aluminium), w / 2 + 0.012, -0.12, 0))
        // Speaker holes on the other side.
        for row in 0..<3 {
            let hole = place(disc(0.01, flat(0.25, 0.26, 0.29)), -w / 2 - 0.0012, 0.12 - CGFloat(row) * 0.04, 0)
            hole.eulerAngles.y = -CGFloat.pi / 2
            root.addChildNode(hole)
        }
        // Sensor window on the back.
        let sensor = place(disc(0.26, flat(0.20, 0.21, 0.24)), 0, 0, -d / 2 - 0.0025)
        sensor.eulerAngles.y = CGFloat.pi
        root.addChildNode(sensor)
        for k in 0..<4 {
            let angle = CGFloat(k) * CGFloat.pi / 2 + CGFloat.pi / 4
            let dot = place(disc(0.035, flat(0.45, 0.50, 0.46)), cos(angle) * 0.14, sin(angle) * 0.14, -d / 2 - 0.0028)
            dot.eulerAngles.y = CGFloat.pi
            root.addChildNode(dot)
        }

        // Woven band: leaves the top and bottom of the case and loops round behind it.
        let band = metal(0.93, 0.93, 0.94, rough: 0.95)
        let segments = 56
        let centerZ: CGFloat = -0.085, reachY: CGFloat = 0.50, reachZ: CGFloat = 0.62
        func point(_ i: Int) -> (CGFloat, CGFloat) {
            let t = CGFloat(i) / CGFloat(segments) * CGFloat.pi
            return (reachY * cos(t), centerZ - reachZ * sin(t))
        }
        for i in 0..<segments {
            let a = point(i), b = point(i + 1)
            let dy = b.0 - a.0, dz = b.1 - a.1
            let length = sqrt(dy * dy + dz * dz)
            let piece = place(box(0.62, 0.04, length + 0.012, chamfer: 0.012, band), 0, (a.0 + b.0) / 2, (a.1 + b.1) / 2)
            piece.eulerAngles.x = atan2(-dy, dz)
            root.addChildNode(piece)
        }
        return root
    }

    /// The watch screen: three activity rings and the time.
    private static func watchFace(aspect: CGFloat) -> SCNMaterial {
        let w = 512, h = max(1, Int(CGFloat(512) / aspect))
        let image = bitmap(w, h) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.44)
            let stroke = CGFloat(w) * 0.085
            let rings: [(CGFloat, (CGFloat, CGFloat, CGFloat), CGFloat)] = [
                (CGFloat(w) * 0.42, (0.98, 0.17, 0.33), 0.78), (CGFloat(w) * 0.32, (0.60, 0.98, 0.10), 0.62), (CGFloat(w) * 0.22, (0.10, 0.90, 0.95), 0.88)]
            ctx.setLineCap(.round)
            ctx.setLineWidth(stroke)
            for (radius, c, fraction) in rings {
                ctx.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.28))
                ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: false)
                ctx.strokePath()
                ctx.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
                ctx.addArc(center: center, radius: radius, startAngle: CGFloat.pi / 2,
                           endAngle: CGFloat.pi / 2 - fraction * CGFloat.pi * 2, clockwise: true)
                ctx.strokePath()
            }
            drawText(ctx, "9:41", x: CGFloat(w) * 0.07, y: CGFloat(h) * 0.90 - CGFloat(w) * 0.07, size: CGFloat(w) * 0.12, weight: .semibold,
                     color: NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1))
        }
        return screenMaterial(image)
    }

    // MARK: HomePod

    private static func speaker() -> SCNNode {
        // The round one: a ball with flat top and bottom, wrapped in diamond mesh.
        let radius: CGFloat = 0.82, squash: CGFloat = 0.88, cut: CGFloat = 0.66
        let rings = 28, around = 72
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uvs: [CGPoint] = []
        var indices: [Int32] = []
        for i in 0...rings {
            let theta = cut + (CGFloat.pi - 2 * cut) * CGFloat(i) / CGFloat(rings)
            let r = radius * sin(theta), y = radius * squash * cos(theta)
            for j in 0...around {
                let phi = CGFloat.pi * 2 * CGFloat(j) / CGFloat(around)
                let x = r * cos(phi), z = r * sin(phi)
                vertices.append(SCNVector3(x, y, z))
                let nx = x / (radius * radius), ny = y / (radius * squash * radius * squash), nz = z / (radius * radius)
                let length = max(sqrt(nx * nx + ny * ny + nz * nz), 0.0001)
                normals.append(SCNVector3(nx / length, ny / length, nz / length))
                uvs.append(CGPoint(x: CGFloat(j) / CGFloat(around), y: CGFloat(i) / CGFloat(rings)))
            }
        }
        for i in 0..<rings {
            for j in 0..<around {
                let a = Int32(i * (around + 1) + j), b = a + Int32(around + 1)
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                             SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: uvs)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let fabric = SCNMaterial()
        fabric.lightingModel = .physicallyBased
        fabric.diffuse.contents = meshTexture()
        fabric.diffuse.wrapS = .repeat
        fabric.diffuse.wrapT = .repeat
        fabric.diffuse.contentsTransform = SCNMatrix4MakeScale(26, 9, 1)
        fabric.metalness.contents = 0.0
        fabric.roughness.contents = 0.9
        fabric.isDoubleSided = true
        geometry.materials = [fabric]
        let root = SCNNode(geometry: geometry)

        // Flat top with a rounded lip and the Siri glow; a matching lip at the foot.
        let topR = radius * sin(cut), topY = radius * squash * cos(cut)
        let lip = metal(0.95, 0.95, 0.96, rough: 0.4)
        for sign in [CGFloat(1), CGFloat(-1)] {
            let torus = SCNTorus(ringRadius: topR, pipeRadius: 0.035)
            torus.materials = [lip]
            root.addChildNode(place(torus, 0, sign * topY, 0))
        }
        let cap = place(plane(topR * 2, topR * 2, radius: topR, lip), 0, topY + 0.002, 0)
        cap.eulerAngles.x = -CGFloat.pi / 2
        root.addChildNode(cap)
        let glow = place(plane(topR * 1.7, topR * 1.7, radius: topR * 0.85, screenMaterial(glowTexture())), 0, topY + 0.005, 0)
        glow.eulerAngles.x = -CGFloat.pi / 2
        root.addChildNode(glow)
        return root
    }

    private static func meshTexture() -> NSImage {
        bitmap(64, 64) { ctx in
            ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: -4, y: -4)); ctx.addLine(to: CGPoint(x: 68, y: 68))
            ctx.move(to: CGPoint(x: -4, y: 68)); ctx.addLine(to: CGPoint(x: 68, y: -4))
            ctx.strokePath()
        }
    }

    private static func glowTexture() -> NSImage {
        bitmap(256, 256) { ctx in
            ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let blobs: [(CGFloat, CGFloat, CGFloat, (CGFloat, CGFloat, CGFloat))] = [
                (110, 140, 95, (0.62, 0.30, 1.0)), (150, 110, 90, (1.0, 0.32, 0.70)),
                (125, 95, 80, (0.20, 0.78, 1.0)), (130, 130, 55, (1.0, 1.0, 1.0))]
            for blob in blobs {
                let c = blob.3
                let g = CGGradient(colorsSpace: space,
                                   colors: [CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.95),
                                            CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0)] as CFArray,
                                   locations: [0, 1])!
                let center = CGPoint(x: blob.0, y: blob.1)
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: blob.2, options: [])
            }
        }
    }

    // MARK: Magic Keyboard

    private static func keyboard() -> SCNNode {
        let w: CGFloat = 2.6, d: CGFloat = 1.0, hFront: CGFloat = 0.035, hBack: CGFloat = 0.10
        let root = SCNNode()
        let silver = metal(0.82, 0.83, 0.85, rough: 0.6)

        // Thin wedge, thicker at the back, with rounded corners.
        root.addChildNode(SCNNode(geometry: roundedWedge(width: w, depth: d, front: hFront, back: hBack, radius: 0.13, silver)))

        // The key surface lies on the slope.
        let slope = atan((hBack - hFront) / d)
        let planeH = sqrt(d * d + (hBack - hFront) * (hBack - hFront)) - 0.03
        let planeW = w - 0.05
        let keys = place(plane(planeW, planeH, radius: 0.10, keycaps(aspect: planeW / planeH)), 0, (hFront + hBack) / 2 + 0.0035, 0)
        keys.eulerAngles.x = -.pi / 2 + slope
        root.addChildNode(keys)
        return root
    }

    /// Silver deck with white keys and every legend, one picture.
    private static func keycaps(aspect: CGFloat) -> SCNMaterial {
        let W = 1600, H = Int(1600 / aspect)
        let image = bitmap(W, H) { ctx in
            ctx.setFillColor(CGColor(red: 0.80, green: 0.81, blue: 0.83, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            func ones(_ n: Int) -> [CGFloat] { [CGFloat](repeating: 1, count: n) }
            let fnLabels = ["esc"] + (1...12).map { "F\($0)" } + [""]
            let numberLabels = ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "delete"]
            let tabLabels = ["tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"]
            let capsLabels = ["caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "return"]
            let shiftLabels = ["shift", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "shift"]
            let bottomLabels = ["fn", "control", "option", "command", "", "command", "option", "<", "ud", ">"]
            let fnRow: [CGFloat] = [1.5] + ones(12) + [1.5]
            let numberRow: [CGFloat] = ones(13) + [2]
            let tabRow: [CGFloat] = [1.5] + ones(12) + [1.5]
            let capsRow: [CGFloat] = [1.75] + ones(11) + [2.25]
            let shiftRow: [CGFloat] = [2.25] + ones(10) + [2.75]
            let bottomRow: [CGFloat] = [1, 1, 1, 1.25, 5, 1.25, 1, 1, 1, 1.5]
            var rows: [(CGFloat, [CGFloat], [String])] = []
            rows.append((0.62, fnRow, fnLabels))
            rows.append((1, numberRow, numberLabels))
            rows.append((1, tabRow, tabLabels))
            rows.append((1, capsRow, capsLabels))
            rows.append((1, shiftRow, shiftLabels))
            rows.append((1, bottomRow, bottomLabels))
            let marginX = CGFloat(W) * 0.03
            let unit = (CGFloat(W) - 2 * marginX) / 15
            var top = (CGFloat(H) - unit * 5.62) / 2
            let legend = NSColor(white: 0.22, alpha: 1)

            func triangle(_ center: CGPoint, _ size: CGFloat, pointing: Int) {   // 0 left, 1 right, 2 up, 3 down
                let path = CGMutablePath()
                switch pointing {
                case 0: path.addLines(between: [CGPoint(x: center.x - size, y: center.y), CGPoint(x: center.x + size * 0.7, y: center.y + size), CGPoint(x: center.x + size * 0.7, y: center.y - size)])
                case 1: path.addLines(between: [CGPoint(x: center.x + size, y: center.y), CGPoint(x: center.x - size * 0.7, y: center.y + size), CGPoint(x: center.x - size * 0.7, y: center.y - size)])
                case 2: path.addLines(between: [CGPoint(x: center.x, y: center.y + size * 0.8), CGPoint(x: center.x - size, y: center.y - size * 0.6), CGPoint(x: center.x + size, y: center.y - size * 0.6)])
                default: path.addLines(between: [CGPoint(x: center.x, y: center.y - size * 0.8), CGPoint(x: center.x - size, y: center.y + size * 0.6), CGPoint(x: center.x + size, y: center.y + size * 0.6)])
                }
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(legend.cgColor)
                ctx.fillPath()
            }

            for (rowIndex, (heightUnits, widths, labels)) in rows.enumerated() {
                let rowH = heightUnits * unit
                var x = marginX
                for (index, width) in widths.enumerated() {
                    let rect = CGRect(x: x + 4, y: CGFloat(H) - top - rowH + 4, width: width * unit - 8, height: rowH - 8)
                    ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
                    ctx.addPath(CGPath(roundedRect: rect.offsetBy(dx: 0, dy: -3), cornerWidth: 14, cornerHeight: 14, transform: nil))
                    ctx.fillPath()
                    ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
                    ctx.fillPath()
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))   // a lighter face inside a slightly darker rim
                    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 7, dy: 7).offsetBy(dx: 0, dy: 2), cornerWidth: 10, cornerHeight: 10, transform: nil))
                    ctx.fillPath()

                    let label = index < labels.count ? labels[index] : ""
                    if rowIndex == 0 && index == widths.count - 1 {
                        // Touch ID: a dark sensor ring in the corner key.
                        ctx.setFillColor(CGColor(gray: 0.20, alpha: 1))
                        let r = min(rect.width, rect.height) * 0.36
                        ctx.fillEllipse(in: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
                        ctx.setFillColor(CGColor(gray: 0.34, alpha: 1))
                        ctx.fillEllipse(in: CGRect(x: rect.midX - r * 0.62, y: rect.midY - r * 0.62, width: r * 1.24, height: r * 1.24))
                    } else if label == "<" {
                        triangle(CGPoint(x: rect.midX, y: rect.midY), rowH * 0.10, pointing: 0)
                    } else if label == ">" {
                        triangle(CGPoint(x: rect.midX, y: rect.midY), rowH * 0.10, pointing: 1)
                    } else if label == "ud" {
                        // Up and down are two half-height keys.
                        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
                        ctx.fill(CGRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4))
                        triangle(CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.26), rowH * 0.08, pointing: 2)
                        triangle(CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.26), rowH * 0.08, pointing: 3)
                    } else if !label.isEmpty {
                        let isWord = label.count > 1 && !(rowIndex == 0 && label.hasPrefix("F"))
                        let fontSize = isWord ? rowH * 0.25 : rowH * (rowIndex == 0 ? 0.40 : 0.42)
                        drawText(ctx, label, x: rect.midX, y: rect.midY - fontSize * 0.6, size: fontSize,
                                 weight: .medium, color: legend, centered: true)
                    }
                    x += width * unit
                }
                top += rowH
            }
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image
        m.metalness.contents = 0.0
        m.roughness.contents = 0.7
        return m
    }
}

// MARK: - SwiftUI host

/// Safety net for the 3D models. While one is being built and shown, a marker is kept in the preferences; it is
/// removed again once the model has been on screen for a few seconds. If the app stops before that, the marker is
/// still there at the next launch: Indra then turns the 3D models off by itself and shows the flat animations,
/// so a device that cannot be drawn can never keep taking the app down. (Settings > Bluetooth turns 3D back on.)
enum SceneGuard {
    private static let pendingKey = "scene3DPending"
    private static let resetKey = "scene3DResetV537"
    private static var generation = 0

    /// Call once, first thing at launch.
    static func recoverFromCrash() {
        let defaults = UserDefaults.standard
        // v537: earlier versions switched 3D off for good whenever the app was stopped within 3 s of a model appearing
        // (Settings > Bluetooth builds eight at once, and re-running from Xcode does exactly that), and nothing in
        // Settings could turn it back on, so the old flat animations stayed. Once, 3D is switched back on.
        if !defaults.bool(forKey: resetKey) {
            defaults.set(true, forKey: resetKey)
            defaults.set(true, forKey: Preferences.bluetooth3DKey)
            defaults.set(false, forKey: pendingKey)
            defaults.synchronize()
            Trace.log("SCENE: 3D device renders switched back on (v537 one-time reset)")
            return
        }
        guard defaults.bool(forKey: pendingKey) else { return }
        Trace.log("SCENE: the app stopped while a 3D model was starting; 3D is off until Settings > Bluetooth > 3D device renders is switched on")
        defaults.set(false, forKey: Preferences.bluetooth3DKey)
        defaults.set(false, forKey: pendingKey)
        defaults.synchronize()
    }

    /// A 3D model is about to be built.
    static func begin() {
        generation += 1
        let mine = generation
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: pendingKey)
        defaults.synchronize()   // written now, so it survives the app stopping a moment later
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard mine == generation else { return }
            defaults.set(false, forKey: pendingKey)
            defaults.synchronize()
        }
    }
}

/// Keeps a paused SceneKit view alive for a moment after it has left the screen, so its drawing thread can finish
/// the frame it is on before the scene is torn down.
@MainActor
enum SceneGraveyard {
    private static var buried: [SCNView] = []

    static func bury(_ view: SCNView) {
        buried.append(view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                view.scene = nil
                buried.removeAll { $0 === view }
            }
        }
    }
}

/// Realistic 3D device on a turntable, with the user's wallpaper on its screen.
struct DeviceSceneView: NSViewRepresentable {
    let kind: BluetoothKind

    func makeNSView(context: Context) -> SCNView {
        SceneGuard.begin()
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        let scene = DeviceScene.make(kind)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
        view.isPlaying = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    static func dismantleNSView(_ view: SCNView, coordinator: ()) {
        // SceneKit draws on its own thread. Emptying the scene while a frame is being drawn (which happens when
        // devices connect one after another and a model is replaced quickly) crashed inside SceneKit. So the
        // scene is paused first and the view is kept alive a little longer, then released once it is idle.
        view.isPlaying = false
        view.scene?.isPaused = true
        view.pause(nil)
        SceneGraveyard.bury(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SCNView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 26, height: proposal.height ?? 26)
    }
}
