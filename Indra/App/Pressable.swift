import SwiftUI

/// Small springy press-down used by buttons across the app.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Gentle grow while the pointer is over a control.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.06
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Fade and a slight settle used when a settings page appears (no blur: it is what made page changes lag).
struct PageReveal: ViewModifier {
    /// 0 = shown, 1 = hidden.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .offset(y: 8 * amount)
            .scaleEffect(1 - 0.012 * amount, anchor: .top)
    }
}

extension AnyTransition {
    static var pageReveal: AnyTransition {
        .asymmetric(insertion: .modifier(active: PageReveal(amount: 1), identity: PageReveal(amount: 0)),
                    removal: .opacity)
    }
}

extension View {
    func hoverLift(_ scale: CGFloat = 1.06) -> some View {
        modifier(HoverLift(scale: scale))
    }
}
