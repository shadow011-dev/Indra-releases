import AppKit
import SwiftUI

enum DropZone: String, Identifiable {
    case tray
    case airDrop
    case blip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tray: return "Files Tray"
        case .airDrop: return "AirDrop"
        case .blip: return "Blip"
        }
    }

    var symbol: String {
        switch self {
        case .tray: return "tray.and.arrow.down.fill"
        case .airDrop: return DropZone.airDropSymbol
        case .blip: return "paperplane.fill"
        }
    }

    var tint: Color {
        switch self {
        case .tray: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .airDrop: return Color(red: 0.30, green: 0.65, blue: 1.0)
        case .blip: return Color(red: 0.62, green: 0.45, blue: 1.0)
        }
    }

    private static let airDropSymbol: String =
        NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil
        ? "airdrop"
        : "dot.radiowaves.left.and.right"
}

/// Shown while a file is dragged over the notch. The zone under the file lights up with a solid border
/// and a soft glow; the others stay calm and a little dimmer.
struct DropZonesView: View {
    let zones: [DropZone]
    let active: DropZone?

    static let spacing: CGFloat = 10
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        HStack(spacing: DropZonesView.spacing) {
            ForEach(zones) { zone in
                zoneView(zone)
            }
        }
        // A little air above (below the hardware notch) and below (room for the zone to grow into).
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: active)
    }

    private func zoneView(_ zone: DropZone) -> some View {
        let isActive = active == zone
        let dimmed = active != nil && !isActive
        return VStack(spacing: 5) {
            Image(systemName: zone.symbol)
                .font(.system(size: 20, weight: .semibold))
                .symbolEffect(.bounce, value: isActive)
                .scaleEffect(isActive ? 1.18 : 1, anchor: .center)
                .offset(y: isActive ? 1 : 0)
            Text(zone.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(zone.tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(zone.tint.opacity(isActive ? 0.34 : 0.14)))
        // A faint dashed outline marks every zone as a drop target.
        .overlay(shape.strokeBorder(zone.tint.opacity(isActive ? 0 : 0.28),
                                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
        // The border of the zone the file is over.
        .overlay(
            shape
                .strokeBorder(zone.tint, lineWidth: isActive ? 2.5 : 0.5)
                .opacity(isActive ? 1 : 0)
                .shadow(color: zone.tint.opacity(isActive ? 0.6 : 0), radius: 9)
        )
        // The magnification is anchored at the top edge, so the zone only ever grows downwards and sideways: it can
        // never push up into the physical notch (the band at the top of the screen that the hardware covers).
        .scaleEffect(isActive ? 1.04 : (dimmed ? 0.965 : 1), anchor: .top)
        .opacity(dimmed ? 0.65 : 1)
        .blur(radius: dimmed ? 0.6 : 0)
        .zIndex(isActive ? 1 : 0)
    }
}
