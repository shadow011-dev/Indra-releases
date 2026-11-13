import SwiftUI

private struct StaggerEpochKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Bumped every time the notch opens, so staggered rows play again.
    var staggerEpoch: Int {
        get { self[StaggerEpochKey.self] }
        set { self[StaggerEpochKey.self] = newValue }
    }
}

/// Each element fades and rises one after another once it appears,
/// starting just after the notch has finished opening. Plays again on every open.
struct StaggerAppear: ViewModifier {
    let index: Int
    var base: Double = 0.14
    var step: Double = 0.055
    @State private var shown = false
    @Environment(\.staggerEpoch) private var epoch

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .animation(.spring(response: 0.52, dampingFraction: 0.86)
                        .delay(base + step * Double(min(index, 9))),
                       value: shown)
            .onAppear { shown = true }
            .onChange(of: epoch) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { shown = false }
                DispatchQueue.main.async { shown = true }
            }
    }
}

extension View {
    func staggered(_ index: Int, base: Double = 0.14, step: Double = 0.055) -> some View {
        modifier(StaggerAppear(index: index, base: base, step: step))
    }
}
