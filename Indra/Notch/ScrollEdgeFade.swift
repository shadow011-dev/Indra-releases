import SwiftUI

private struct ScrollEdgeState: Equatable {
    var atTop = true
    var atBottom = true
}

/// Rows fade out softly where the list continues beyond the top or bottom edge,
/// and stay fully visible at the start / end of the list.
struct ScrollEdgeFade: ViewModifier {
    @State private var edges = ScrollEdgeState()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollEdgeState.self) { geometry in
                let offset = geometry.contentOffset.y
                let maxOffset = geometry.contentSize.height - geometry.containerSize.height
                return ScrollEdgeState(atTop: offset <= 1,
                                       atBottom: maxOffset <= 1 || offset >= maxOffset - 1)
            } action: { _, newValue in
                edges = newValue
            }
            .mask(
                LinearGradient(stops: [.init(color: edges.atTop ? Color.black : Color.clear, location: 0),
                                       .init(color: Color.black, location: 0.2),
                                       .init(color: Color.black, location: 0.8),
                                       .init(color: edges.atBottom ? Color.black : Color.clear, location: 1)],
                               startPoint: .top,
                               endPoint: .bottom)
            )
            .animation(.easeOut(duration: 0.18), value: edges)
    }
}

extension View {
    func scrollEdgeFade() -> some View {
        modifier(ScrollEdgeFade())
    }
}
