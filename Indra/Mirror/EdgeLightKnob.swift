import SwiftUI

/// The two edge lights: the screen's edges glow warm (orange) or cool (blue). See EdgeLightController.
enum EdgeLight {
    static let warm = Color(red: 1.0, green: 0.58, blue: 0.20)
    static let cool = Color(red: 0.34, green: 0.62, blue: 1.0)
}

/// A donut-shaped knob. Click it to switch its light on or off. Drag up or down to change the intensity (the
/// outer arc) and left or right to change the width of the light (the thin inner arc). Every step gives a tick.
struct EdgeLightKnob: View {
    let tint: Color
    let symbol: String
    let side: CGFloat
    @Binding var isOn: Bool
    @Binding var intensity: Double
    @Binding var width: Double
    @State private var dragStart: (intensity: Double, width: Double)?
    @State private var pressed = false

    private let gaugeSweep = 0.75

    var body: some View {
        ZStack {
            // The donut: a dark disc with a hole in the middle.
            Circle()
                .fill(Color.white.opacity(isOn ? 0.10 : 0.07))
            // Outer track and arc: intensity.
            Circle()
                .trim(from: 0, to: gaugeSweep)
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(4)
            Circle()
                .trim(from: 0, to: gaugeSweep * max(intensity, 0.001))
                .stroke(tint.opacity(isOn ? 1 : 0.3), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(4)
                .shadow(color: tint.opacity(isOn ? 0.55 : 0), radius: 4)
            // Inner thin arc: width.
            Circle()
                .trim(from: 0, to: gaugeSweep * max(width, 0.001))
                .stroke(tint.opacity(isOn ? 0.75 : 0.25), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(12)
            // The hole.
            Circle()
                .fill(Color.black.opacity(0.55))
                .padding(side * 0.30)
            Image(systemName: symbol)
                .font(.system(size: side * 0.2, weight: .semibold))
                .foregroundStyle(isOn ? tint : Color.white.opacity(0.4))
        }
        .frame(width: side, height: side)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: pressed)
        .animation(.easeOut(duration: 0.15), value: intensity)
        .animation(.easeOut(duration: 0.15), value: width)
        .animation(.easeOut(duration: 0.2), value: isOn)
        .contentShape(Circle())
        .onTapGesture {
            Haptics.hf2()
            isOn.toggle()
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStart == nil { dragStart = (intensity, width) }
                    guard let start = dragStart else { return }
                    pressed = true
                    if !isOn { isOn = true }
                    let newIntensity = min(max(start.intensity - Double(value.translation.height) / 80, 0), 1)
                    let newWidth = min(max(start.width + Double(value.translation.width) / 80, 0), 1)
                    if Int(newIntensity * 20) != Int(intensity * 20) || Int(newWidth * 20) != Int(width * 20) {
                        Haptics.hf3(lockout: 0.03)
                    }
                    intensity = newIntensity
                    width = newWidth
                }
                .onEnded { _ in
                    dragStart = nil
                    pressed = false
                }
        )
        .help("Click to switch on or off. Drag up or down for intensity, left or right for width.")
    }
}
