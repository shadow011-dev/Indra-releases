import SwiftUI

struct TrayView: View {
    @ObservedObject var tray: TrayStore
    let isDropTargeted: Bool
    /// True at the Duo size (a wider, taller notch): the drop box gets the extra room and the buttons grow with it.
    var roomy = false
    @AppStorage(Preferences.blipEnabledKey) private var blipEnabled = true

    private var blipAvailable: Bool { blipEnabled && FileSharing.blipURL != nil }
    private var allURLs: [URL] { tray.items.map(\.url) }

    var body: some View {
        HStack(spacing: roomy ? 16 : 12) {
            itemsArea
            actions
        }
        .padding(.top, 2)
        .animation(.smooth(duration: 0.25), value: roomy)
        .animation(.smooth(duration: 0.22), value: isDropTargeted)
        .animation(.smooth(duration: 0.25), value: tray.items.isEmpty)
    }

    // MARK: - Items

    @ViewBuilder
    private var itemsArea: some View {
        if tray.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("Drop files here")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(isDropTargeted ? 0.9 : 0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dropBackground)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tray.items) { item in
                        TrayTile(item: item,
                                 blipAvailable: blipAvailable,
                                 onRemove: { tray.remove(item) })
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 4)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: tray.items.count)
            }
            .lockScrollAxis(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dropBackground)
        }
    }

    private var dropBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(isDropTargeted ? 0.7 : 0.22),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isDropTargeted ? 0.08 : 0))
            )
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: roomy ? 5 : 6) {
            TrayActionButton(symbol: "square.and.arrow.up", title: "AirDrop", roomy: roomy) { FileSharing.airDrop(allURLs) }
            if blipAvailable {
                TrayActionButton(symbol: "paperplane.fill", title: "Blip", roomy: roomy) { FileSharing.blip(allURLs) }
            }
            TrayActionButton(symbol: "trash", title: "Clear", roomy: roomy) {
                withAnimation(.smooth(duration: 0.22)) { tray.removeAll() }
            }
                .disabled(tray.items.isEmpty)
                .opacity(tray.items.isEmpty ? 0.4 : 1)
                .animation(.smooth(duration: 0.25), value: tray.items.isEmpty)
        }
    }
}

/// A pill button on the tray page; it brightens while the pointer is over it.
private struct TrayActionButton: View {
    let symbol: String
    let title: String
    var roomy = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            Haptics.hf1()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(width: roomy ? 100 : 82, height: roomy ? 24 : 26)
            .background(Capsule().fill(Color.white.opacity(hovering && enabled ? 0.24 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.93))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}

/// One file in the tray. A remove (x) button appears while the pointer is over it.
private struct TrayTile: View {
    let item: TrayItem
    let blipAvailable: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The gestures live on the tile itself, not on the whole stack: a double-click or drag
            // recogniser around the x button made every click on it wait before it was handled.
            VStack(spacing: 4) {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(item.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 62)
            }
            .frame(width: 66, height: 72)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0))
            )
            .scaleEffect(hovering ? 1.05 : 1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { FileSharing.open(item.url) }
            .onDrag {
                MainActor.assumeIsolated { FileSharing.trayDragStartedAt = Date() }
                return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
            }
            .contextMenu {
                Button("Open") { FileSharing.open(item.url) }
                Button("Show in Finder") { FileSharing.reveal(item.url) }
                Button("AirDrop") { FileSharing.airDrop([item.url]) }
                if blipAvailable {
                    Button("Send with Blip") { FileSharing.blip([item.url]) }
                }
                Divider()
                Button("Remove from Tray") { onRemove() }
            }

            if hovering {
                Button(action: {
                    onRemove()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white, Color(white: 0.38))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.85))
                .offset(x: -1, y: 1)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 66, height: 72)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
    }
}
