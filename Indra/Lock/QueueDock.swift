import SwiftUI

/// A shelf of record sleeves on the right edge of the lock screen, shown while the vinyl is open. The sleeves
/// fan out as a column: the three songs before the current one, the current one (its record is on the
/// turntable, so its sleeve is empty and dim), and the three after. Each sleeve shows the cover and has a
/// black record peeking out of it. Pointing at a sleeve slides its record further out (with a little spin)
/// and shows the name. Clicking plays that song: the record leaves, the shelf re-deals so the chosen sleeve
/// takes the middle, and a new sleeve slides in at the end.
struct QueueDock: View {
    @ObservedObject var media: MediaController
    /// Height of the strip along the right edge.
    let length: CGFloat

    /// Width of the strip (room for the lifted card).
    static let thickness: CGFloat = 150
    private let sleeve: CGFloat = 55            // the cover square (20% larger than before)
    private let disc: CGFloat = 50              // the record
    private let peekRest: CGFloat = 0           // at rest the record is hidden inside its sleeve
    private let peekHover: CGFloat = 62         // ... and slides out to the left when the pointer is on it
    private let discZoom: CGFloat = 1.3         // the hovered record is magnified
    // Quick, slightly springy pull out; an even quicker push back in.
    private let pullOut = Animation.spring(response: 0.23, dampingFraction: 0.66)
    private let pushIn = Animation.snappy(duration: 0.17)
    private let launchAway = Animation.easeIn(duration: 0.28)
    private let edgeMargin: CGFloat = 10        // gap between the covers and the screen edge
    private let hoverScale: CGFloat = 1.25      // the cover under the pointer grows
    private let slide = Animation.spring(response: 0.5, dampingFraction: 0.82)

    /// The card under the pointer. Only this index is state (not the pointer position), so moving the mouse
    /// does not rebuild the whole shelf on every event.
    @State private var hoveredIdx: Int?
    @State private var hovering = false
    @State private var leaveTask: Task<Void, Never>?
    /// The song just chosen: its record slides away while the shelf re-deals.
    @State private var launching: String?

    private struct Slot: Identifiable {
        let id: String
        let entry: QueueEntry
        let isCurrent: Bool
    }

    private var slots: [Slot] {
        let before = media.queue.filter { $0.id < media.queueCurrent }
        let after = media.queue.filter { $0.id > media.queueCurrent }
        guard !before.isEmpty || !after.isEmpty else { return [] }
        var result = before.map { Slot(id: $0.key, entry: $0, isCurrent: false) }
        if let current = media.queueCurrentEntry {
            result.append(Slot(id: current.key, entry: current, isCurrent: true))
        }
        result += after.map { Slot(id: $0.key, entry: $0, isCurrent: false) }
        return result
    }

    private var visible: Bool { hovering && !slots.isEmpty }

    /// Distance between neighbouring covers: a straight column, squeezed a little if the screen is short.
    private func pitch(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return min(sleeve + 12, (length - sleeve - 16) / CGFloat(count - 1))
    }

    /// Position of a cover along the edge (vertical centre).
    private func restY(_ index: Int, of count: Int) -> CGFloat {
        length / 2 + (CGFloat(index) - CGFloat(count - 1) / 2) * pitch(count: count)
    }

    /// Horizontal centre of a cover: all of them sit in one straight line along the screen edge.
    private func restX(_ index: Int, of count: Int) -> CGFloat {
        QueueDock.thickness - edgeMargin - sleeve / 2
    }

    /// The card nearest the pointer height, if it is close enough to one.
    private func nearestIndex(toY y: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<count {
            let distance = abs(restY(index, of: count) - y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best, best.distance < 34 else { return nil }
        return best.index
    }

    private func hoveredIndex(count: Int) -> Int? {
        guard visible, let hoveredIdx, hoveredIdx < count else { return nil }
        return hoveredIdx
    }

    var body: some View {
        let items = slots
        let hovered = hoveredIndex(count: items.count)
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, slot in
                cardView(slot, index: index, count: items.count, hovered: hovered)
                    .transition(.asymmetric(
                        insertion: .offset(x: 30, y: 80).combined(with: .opacity),
                        removal: .offset(x: 30, y: -80).combined(with: .opacity)))
            }
            if hovering, items.isEmpty, let note = media.queueNote {
                Text(note)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .frame(width: 100, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.28))
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .position(x: QueueDock.thickness - 14 - 62, y: length / 2)
                    .transition(.opacity.combined(with: .offset(x: 12)))
            }
        }
        .animation(slide, value: items.map { $0.id })
        .animation(.spring(response: 0.26, dampingFraction: 0.74), value: hovered)
        .animation(.smooth(duration: 0.3), value: hovering)
        .frame(width: QueueDock.thickness, height: length, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let index = hovered, items.indices.contains(index), !items[index].isCurrent else { return }
            let key = items[index].id
            Haptics.hf1(scope: .lock)   // a song chosen from the side bar
            launching = key
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if launching == key { launching = nil }
            }
            media.playQueueEntry(items[index].entry)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                leaveTask?.cancel()
                let found = nearestIndex(toY: point.y, count: slots.count)
                if found != hoveredIdx {
                    hoveredIdx = found
                    // A new album comes into focus: the strongest tap. Played as a hover tap with no lockout wait.
                    if found != nil { Haptics.tap(.peak, lockout: 0.0, scope: .lock) }
                }
                if !hovering {
                    hovering = true
                    media.refreshQueue()
                }
            case .ended:
                if hoveredIdx != nil { hoveredIdx = nil }
                leaveTask?.cancel()
                leaveTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    hovering = false
                }
            }
        }
        .onChange(of: media.track?.identity) { _, _ in
            if hovering { media.refreshQueue() }
        }
    }

    private func cardView(_ slot: Slot, index: Int, count: Int, hovered: Int?) -> some View {
        let isHovered = hovered == index
        let isLaunching = launching == slot.id
        // The hovered cover grows; the neighbours make a little room.
        var spread: CGFloat = 0
        if let hovered, hovered != index {
            let gap = index - hovered
            spread = (gap > 0 ? 1 : -1) * 14 / CGFloat(abs(gap))
        }
        let x = restX(index, of: count) - sleeve / 2
        let y = restY(index, of: count) + spread - sleeve / 2
        let middle = Double(count - 1) / 2
        let delay = visible ? abs(Double(index) - middle) * 0.045 : 0
        // How far the record pokes out of the sleeve, to the left. A chosen record slides well away.
        let out: CGFloat = isLaunching ? peekHover + 90 : (isHovered ? peekHover : peekRest)
        let recordMotion = isLaunching ? launchAway : (isHovered ? pullOut : pushIn)
        // The magnified record grows a little past its resting edge; keep the name clear of it.
        let zoomMargin = disc * (discZoom - 1) / 2
        let sleeveScale: CGFloat = isLaunching ? 0.93 : (isHovered ? hoverScale : 1)

        return ZStack {
            // The current song's record is on the turntable: its sleeve stays behind empty.
            if !slot.isCurrent {
                record(slot.entry, spinning: isHovered || isLaunching, lifted: isHovered)
                    .scaleEffect(isHovered ? discZoom : 1)
                    .offset(x: -sleeve / 2 - out + disc / 2)
                    .opacity(isLaunching ? 0 : 1)
                    .animation(recordMotion, value: out)
                    .animation(recordMotion, value: isHovered)
                    .animation(.easeIn(duration: 0.3), value: isLaunching)
            }
            // Pulled off the shelf: the open edge tilts toward you.
            sleeveFace(slot.entry, current: slot.isCurrent, lifted: isHovered)
        }
        .frame(width: sleeve, height: sleeve)
        .overlay(alignment: .trailing) {
            // The song on the turntable has no name tag: its record is already the big one.
            if isHovered && !slot.isCurrent {
                label(slot.entry)
                    .offset(x: -(sleeve + peekHover + 8 + zoomMargin))
                    .transition(.opacity.combined(with: .offset(x: 10)))
            }
        }
        .scaleEffect(sleeveScale)
        .zIndex(isHovered ? 100 : Double(index))
        .offset(x: x, y: y)
        // Fan in from the edge, middle first, when the pointer arrives; tuck away fast when it leaves.
        .offset(x: visible ? 0 : 150)
        .scaleEffect(visible ? 1 : 0.8)
        .opacity(visible ? 1 : 0)
        .animation(visible ? .spring(response: 0.42, dampingFraction: 0.7).delay(delay)
                           : .easeIn(duration: 0.16),
                   value: visible)
    }

    /// The cover as a record sleeve.
    private func sleeveFace(_ entry: QueueEntry, current: Bool, lifted: Bool) -> some View {
        ZStack {
            Color(white: 0.2)
            if let image = entry.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            if current { Color.black.opacity(0.5) }
        }
        .frame(width: sleeve, height: sleeve)
        .clipShape(CoverCurve.shape(sleeve))
        .overlay(CoverCurve.shape(sleeve)
            .stroke(Color.white.opacity(current ? 0.1 : 0.28), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.4), radius: 6, x: -2, y: 2)
        // One cached picture (the shadow is baked in); lifting only moves, tilts and scales it.
        .padding(12)
        .drawingGroup()
        .padding(-12)
        .animation(.easeOut(duration: 0.25), value: entry.image == nil)
        // Resting covers are tinted dark; the colour comes back only under the pointer.
        .overlay {
            CoverCurve.shape(sleeve)
                .fill(Color.black.opacity(lifted || current ? 0 : 0.6))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.22), value: lifted)
        }
    }

    /// A black record with the cover as its label. It gives a little spin as it slides out.
    private func record(_ entry: QueueEntry, spinning: Bool, lifted: Bool) -> some View {
        recordPicture(entry)
            .rotationEffect(.degrees(spinning ? 270 : 0))
            .animation(.easeOut(duration: 0.55), value: spinning)
    }

    /// The flat record, flattened into one cached picture: the pull-out and the spin only move that picture.
    private func recordPicture(_ entry: QueueEntry) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.07))
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 0.6).padding(disc * 0.12)
            Circle().stroke(Color.white.opacity(0.05), lineWidth: 0.6).padding(disc * 0.22)
            ZStack {
                Color(white: 0.25)
                if let image = entry.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: disc * 0.44, height: disc * 0.44)
            .clipShape(Circle())
            // v523: no centre hole on the side records either.
        }
        .frame(width: disc, height: disc)
        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.35), radius: 4, x: -1, y: 1)
        .padding(8)
        .drawingGroup()
        .padding(-8)
    }

    /// Long names show only their beginning, so the name tag stays small and on screen.
    private static func shortened(_ text: String, limit: Int = 22) -> String {
        text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    private func label(_ entry: QueueEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(QueueDock.shortened(entry.title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
            if !entry.artist.isEmpty {
                Text(QueueDock.shortened(entry.artist))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            // Exactly the glass of the player card (same tint, same material, same opacity).
            ZStack {
                Capsule().fill(Color.black.opacity(0.10))
                Capsule().fill(.ultraThinMaterial).opacity(0.45)
            }
        }
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .allowsHitTesting(false)
    }
}
