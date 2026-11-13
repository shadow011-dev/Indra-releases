import SwiftUI

/// The to-do page when Reminders is on: the same page as the to-do list, in yellow, but its tasks are the open
/// reminders of the native Reminders app.
struct RemindersView: View {
    @ObservedObject var store: RemindersStore
    let onEditingChange: (Bool) -> Void
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    var layoutWidth: CGFloat = CalendarLayout.size.width
    private var fieldWidth: CGFloat { layoutWidth - 80 }

    private let accent = Color(red: 1.0, green: 0.80, blue: 0.0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("REMINDERS")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
                .staggered(0)
                .offset(x: CalendarLayout.leftX, y: 19)
            Text("\(store.items.count)")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 60, alignment: .trailing)
                .staggered(0)
                .offset(x: layoutWidth - 43 - 60, y: 19)
            if store.hasAccess {
                addField
                    .staggered(1)
                    .offset(x: CalendarLayout.leftX - 2, y: 36)
                list
                    .offset(x: CalendarLayout.leftX - 2, y: 66)
            } else {
                noAccess
                    .offset(x: CalendarLayout.leftX - 2, y: 40)
            }
        }
        .frame(width: layoutWidth, height: CalendarLayout.size.height, alignment: .topLeading)
        .onAppear { store.activate() }
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
            TextField("", text: $draft, prompt: Text("Add a reminder").foregroundStyle(Color.white.opacity(0.35)))
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

    /// Shown until the Reminders permission is given.
    private var noAccess: some View {
        VStack(spacing: 7) {
            Image(systemName: "bell.slash")
                .font(.system(size: 18, weight: .medium))
            Text(store.isDenied ? "Reminders access is off" : "Waiting for access to Reminders")
                .font(.system(size: 12, weight: .medium))
            if store.isDenied {
                Button {
                    RemindersStore.openPrivacySettings()
                } label: {
                    Text("Open System Settings")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Color.white.opacity(0.5))
        .frame(width: fieldWidth, height: 110)
    }

    @ViewBuilder
    private var list: some View {
        if store.rows.isEmpty {
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
                    ForEach(Array(store.rows.enumerated()), id: \.element.id) { position, row in
                        TodoRow(title: row.item.title, accent: accent, position: position, done: row.done,
                                tickColor: Color.black.opacity(0.8),
                                onToggle: { store.toggleDone(row) },
                                onDelete: { store.delete(row) })
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .leading))))
                    }
                }
            }
            .frame(width: fieldWidth, height: 92)
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
