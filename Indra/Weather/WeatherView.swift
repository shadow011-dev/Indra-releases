import SwiftUI

/// Alcove-style weather page: temperature, conditions and a temperature curve on the left,
/// the next hours on the right (scroll with two fingers).
struct WeatherView: View {
    @ObservedObject var controller: WeatherController
    @ObservedObject private var locator = WeatherLocator.shared

    /// Width of the page; wider than the standard page when the notch has the Duo size.
    var layoutWidth: CGFloat = CalendarLayout.size.width

    private let left: CGFloat = 42
    /// The divider keeps its place relative to the width (x = 202 on the standard 390-point page).
    private var dividerX: CGFloat { (layoutWidth * 202 / 390).rounded() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch controller.phase {
            case .ready(let snapshot):
                content(snapshot)
            case .loading:
                // No "Loading" text: the page stays empty for the moment it takes the very first fetch.
                Color.clear
            case .needsCity:
                message("Set your city to see the weather", showsButton: true)
            case .failed(let text):
                message(text, showsButton: true)
            }
        }
        .frame(width: layoutWidth, height: CalendarLayout.size.height, alignment: .topLeading)
        .animation(.smooth(duration: 0.35), value: locator.state)
        .onAppear { controller.activate() }
        .onChange(of: locator.state) { _, new in
            if case .done = new { controller.activate() }
        }
    }

    // MARK: - Loaded

    private func content(_ snapshot: WeatherSnapshot) -> some View {
        ZStack(alignment: .topLeading) {
            Text("\(snapshot.temperature)°")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.white)
                .offset(x: left - 2, y: 24)
            Image(systemName: snapshot.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 20))
                .offset(x: left + 74, y: 40)
            Text("H:\(snapshot.high)°  L:\(snapshot.low)°  UV \(snapshot.uv)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
                .offset(x: left, y: 86)
            HStack(spacing: 5) {
                Image(systemName: "wind")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(snapshot.windKmh) km/h")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.5))
            .offset(x: left, y: 108)
            TemperatureCurve(points: snapshot.graph, nowIndex: snapshot.graphNowIndex)
                .frame(width: dividerX - left - 14, height: 24)
                .offset(x: left, y: 128)
            Rectangle()
                .fill(Color.white.opacity(0.13))
                .frame(width: 1, height: 119)
                .offset(x: dividerX, y: 32)
            hourList(snapshot.hours)
                .offset(x: dividerX + 10, y: 41)
        }
    }

    private func hourList(_ hours: [WeatherHour]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { position, hour in
                    HStack(spacing: 0) {
                        Text(hour.label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .frame(width: 48, alignment: .leading)
                        Image(systemName: hour.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 14))
                            .frame(width: 24)
                        Spacer(minLength: 0)
                        Text("\(hour.temperature)°")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(height: 29)
                    .staggered(position + 1)
                }
            }
        }
        .frame(width: layoutWidth - dividerX - 10 - 42, height: 118)
        // One tick for every line that scrolls past.
        .onScrollGeometryChange(for: Int.self) { geometry in
            Int(max(0, geometry.contentOffset.y) / 29)
        } action: { old, new in
            if old != new { Haptics.hf2(lockout: 0.03) }
        }
        .lockScrollAxis(.vertical)
        .scrollEdgeFade()
    }

    // MARK: - Not loaded

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
        }) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
    }

    private func message(_ text: String, showsButton: Bool) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            if showsButton {
                HStack(spacing: 8) {
                    pill(locator.isWorking ? "Locating…" : "Use My Location") {
                        locator.locate()
                    }
                    .disabled(locator.isWorking)
                    pill("Open Settings") {
                        NotificationCenter.default.post(name: .indraOpenSettings, object: nil)
                    }
                }
                if case .failed(let reason) = locator.state {
                    Text(reason)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: layoutWidth, height: CalendarLayout.size.height)
    }
}

/// Dotted line for the past, solid line for the coming hours, a dot for now.
struct TemperatureCurve: View {
    let points: [Double]
    let nowIndex: Int

    private let teal = Color(red: 0.36, green: 0.80, blue: 0.86)

    var body: some View {
        Canvas { canvas, size in
            guard points.count > 2 else { return }
            let low = points.min() ?? 0
            let high = points.max() ?? 1
            let span = max(high - low, 1)
            let step = size.width / CGFloat(points.count - 1)

            func point(_ index: Int) -> CGPoint {
                let normalized = (points[index] - low) / span
                return CGPoint(x: CGFloat(index) * step,
                               y: size.height - 4 - CGFloat(normalized) * (size.height - 8))
            }

            func smooth(from first: Int, to last: Int) -> Path {
                var path = Path()
                path.move(to: point(first))
                guard last > first else { return path }
                for index in (first + 1)...last {
                    let previous = point(index - 1)
                    let current = point(index)
                    let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                    path.addQuadCurve(to: middle, control: previous)
                }
                path.addLine(to: point(last))
                return path
            }

            let now = min(max(nowIndex, 0), points.count - 1)
            let future = smooth(from: now, to: points.count - 1)

            var fill = future
            fill.addLine(to: CGPoint(x: point(points.count - 1).x, y: size.height))
            fill.addLine(to: CGPoint(x: point(now).x, y: size.height))
            fill.closeSubpath()
            canvas.fill(fill,
                        with: .linearGradient(Gradient(colors: [teal.opacity(0.25), teal.opacity(0)]),
                                              startPoint: CGPoint(x: 0, y: 0),
                                              endPoint: CGPoint(x: 0, y: size.height)))

            if now > 0 {
                canvas.stroke(smooth(from: 0, to: now),
                              with: .color(teal.opacity(0.9)),
                              style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4.5]))
            }
            canvas.stroke(future,
                          with: .color(teal),
                          style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            let marker = point(now)
            canvas.fill(Path(ellipseIn: CGRect(x: marker.x - 3.5, y: marker.y - 3.5, width: 7, height: 7)),
                        with: .color(Color.white))
        }
    }
}
