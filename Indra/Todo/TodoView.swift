import SwiftUI

/// Your own to-do list: type one in, click the circle to finish it, scroll with two fingers.
struct TodoView: View {
    @ObservedObject var store: TodoStore
    let onEditingChange: (Bool) -> Void
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    /// Width of the page; wider than the standard page when the notch has the Duo size.
    var layoutWidth: CGFloat = CalendarLayout.size.width
    private var fieldWidth: CGFloat { layoutWidth - 80 }

    private let accent = Color(red: 0.882, green: 0.310, blue: 0.384)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("TO DO")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
                .staggered(0)
                .offset(x: CalendarLayout.leftX, y: 19)
            Text("\(store.openItems.count)")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 60, alignment: .trailing)
                .staggered(0)
                .offset(x: layoutWidth - 43 - 60, y: 19)
            addField
                .staggered(1)
                .offset(x: CalendarLayout.leftX - 2, y: 36)
            list
                .offset(x: CalendarLayout.leftX - 2, y: 66)
        }
        .frame(width: layoutWidth, height: CalendarLayout.size.height, alignment: .topLeading)
        .onChange(of: fieldFocused) { _, focused in
            onEditingChange(focused)
        }
        .onDisappear {
            fieldFocused = false
            onEditingChange(false)
        }
    }

    private var addField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))
            TextField("", text: $draft, prompt: Text("Add a to-do").foregroundStyle(Color.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .focused($fieldFocused)
                .onSubmit {
                    withAnimation(NotchMotion.list) {
                        store.add(draft)
                    }
                    draft = ""
                }
        }
        .padding(.horizontal, 9)
        .frame(width: fieldWidth, height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09)))
    }

    @ViewBuilder
    private var list: some View {
        if store.items.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 18, weight: .medium))
                Text("All done")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.42))
            .frame(width: fieldWidth, height: 92)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { position, item in
                        TodoRow(title: item.title, accent: accent, position: position, done: item.done,
                                onToggle: { store.toggleDone(item) },
                                onDelete: { store.delete(item) })
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .leading))))
                    }
                }
            }
            .frame(width: fieldWidth, height: 92)
            // One tick for every line that scrolls past.
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int(max(0, geometry.contentOffset.y) / 28)
            } action: { old, new in
                if old != new { Haptics.hf2(lockout: 0.03) }
            }
            .lockScrollAxis(.vertical)
            .scrollEdgeFade()
        }
    }
}

/// One to-do (or reminder). Tapping the circle fills it with a tick, strikes the text through and fades the row;
/// the row stays where it is. Tap the circle again to bring it back. The bin at the end deletes it for good.
struct TodoRow: View {
    let title: String
    let accent: Color
    let position: Int
    let done: Bool
    /// The tick is drawn dark on a light accent (the yellow of Reminders) and white on a dark one.
    var tickColor = Color.white
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var hoveringDelete = false

    var body: some View {
        HStack(spacing: 9) {
            Button {
                if !done { SoftSound.taskDone() }
                withAnimation(NotchMotion.tap) {
                    onToggle()
                }
            } label: {
                TaskTick(done: done, accent: accent, tickColor: tickColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(done ? 0.38 : 1))
                .strikethrough(done, color: Color.white.opacity(0.55))
                .lineLimit(1)
                .animation(.easeOut(duration: 0.25), value: done)
            Spacer(minLength: 0)
            Button {
                withAnimation(NotchMotion.listRow) {
                    onDelete()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hoveringDelete ? Color(red: 1.0, green: 0.38, blue: 0.36) : Color.white.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringDelete = $0 }
            .help("Delete")
        }
        .frame(height: 28)
        .staggered(position + 2)
        .contextMenu {
            Button(done ? "Not done" : "Done") { withAnimation(NotchMotion.tap) { onToggle() } }
            Button("Delete") { withAnimation(NotchMotion.listRow) { onDelete() } }
        }
    }
}

/// The tick path: a short stroke down, then a long one up, so it can be drawn on with `trim`.
private struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// The round tick of a to-do or reminder. Empty it is a clean ring; when done the circle fills with a soft
/// gradient, the tick is drawn on stroke by stroke with round ends, and a thin ring ripples outward once.
struct TaskTick: View {
    let done: Bool
    let accent: Color
    let tickColor: Color
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0

    private let side: CGFloat = 17

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(accent.opacity(done ? 0 : 0.95), lineWidth: 1.5)
                .frame(width: side, height: side)
            Circle()
                .fill(LinearGradient(colors: [accent, accent.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                .frame(width: side, height: side)
                .shadow(color: accent.opacity(done ? 0.45 : 0), radius: 3, y: 1)
                .scaleEffect(done ? 1 : 0.2)
                .opacity(done ? 1 : 0)
            TickShape()
                .trim(from: 0, to: done ? 1 : 0)
                .stroke(tickColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 8.5, height: 6.5)
                .animation(.easeOut(duration: 0.26).delay(done ? 0.07 : 0), value: done)
            Circle()
                .stroke(accent, lineWidth: 1.2)
                .frame(width: side, height: side)
                .scaleEffect(rippleScale)
                .opacity(rippleOpacity)
        }
        .onChange(of: done) { _, isDone in
            guard isDone else { return }
            rippleScale = 1
            rippleOpacity = 0.6
            withAnimation(.easeOut(duration: 0.5)) {
                rippleScale = 1.8
                rippleOpacity = 0
            }
        }
    }
}
