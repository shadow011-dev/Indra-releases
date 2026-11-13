import AppKit
import EventKit
import SwiftUI

/// NotchNook-style date widget: big month, a scrollable strip of days, and the selected
/// day's events (or "Nothing for today") underneath.
struct DateStripView: View {
    @ObservedObject var controller: CalendarController
    /// The standalone page shows nothing under the strip on a day without events; the Duo page keeps its hint.
    var showsEmptyHint = true
    /// The Duo page is short: a slimmer day strip, and the "Nothing for today" hint on one line.
    var compact = false
    /// v443: when set (the Duo page), the month name is a button that opens the full month calendar.
    var onMonthTap: (() -> Void)? = nil
    @Environment(\.staggerEpoch) private var epoch
    /// The day (offset from today) sitting in the middle of the strip. The events shown below follow it.
    @State private var centred: Int? = 0
    /// True while the strip is being put back on today by the app itself: those moves give no haptic.
    @State private var quiet = true
    /// True while the strip is being dragged, flicked or animated. At rest the day in the middle is enlarged
    /// whatever the measured positions say, so today is already in focus the moment the notch opens.
    @State private var scrolling = false
    /// The strip stays invisible until it has been put on today, which happens while the notch is still closed.
    /// What opens is therefore already in its final place: nothing scrolls in front of the eye.
    @State private var placed = false
    /// Bumped when the pointer comes back over the page: if another day is in focus, the strip glides back to today.
    @State private var glideToken = 0
    /// v443: the day a click is bringing into the middle. While the strip glides there, the days it passes are not selected.
    @State private var focusTarget: Int?
    /// v459: until this moment nothing but the click decides which day is in focus: the strip is still gliding to the clicked day.
    @State private var clickLockUntil = Date.distantPast
    /// v460: moves the strip's own NSScrollView when a day is clicked (see StripScrollDriver).
    @State private var driver = StripScrollDriver()
    /// v459: when the pointer last left the page. The glide back to today needs a real exit first: the page re-reports
    /// "pointer inside" whenever the strip moves under it, and that used to send a clicked day straight back to today.
    @State private var hoverLeftAt: Date?
    @State private var monthHovered = false

    /// Tall enough for the enlarged day (weekday letter above the number) with room to spare, so nothing is clipped.
    private var stripHeight: CGFloat { compact ? 50 : 60 }
    private let offsets = Array(-14...45)
    private let blue = Color(red: 0.18, green: 0.52, blue: 1.0)
    private let mutedRed = Color(red: 0.76, green: 0.42, blue: 0.40)

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            HStack(alignment: .center, spacing: 4) {
                monthTitle
                strip
            }
            eventsArea
        }
        .onAppear {
            // Read the events straight away (Duo shows them as soon as the notch opens) ...
            controller.refresh()
            // ... and load once more after the page transition, so the animation never stutters.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000)
                controller.activate()
            }
        }
        // Every time the notch opens the day is read again, so events added meanwhile are there, and today is
        // back in focus (put there without animation, so nothing scrolls in front of the eye).
        .onChange(of: epoch) { _, _ in
            controller.resetToToday()
            // The events are read again once the notch has finished opening. Reading them while it opens made the
            // first opening after a long rest (when the calendar store is cold) stutter; the closed notch keeps
            // them fresh meanwhile (see keepWarm in the window controller), so nothing is missed. The read is a
            // synchronous call to the calendar store, so it waits until the opening spring has fully settled (it used
            // to run at 0.65 s, still inside the animation, and showed as a late hitch).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                controller.refresh()
            }
        }
        // Hovering the page again brings today back into focus, with a soft glide.
        .onHover { inside in
            if !inside { hoverLeftAt = Date(); return }
            guard let left = hoverLeftAt, Date().timeIntervalSince(left) > 0.4,
                  Date() > clickLockUntil.addingTimeInterval(1.0) else { return }
            if !calendar.isDateInToday(controller.selectedDate) { glideToken &+= 1 }
        }
        // Calendar access answered while the page is open: show the events right away.
        .onChange(of: controller.status) { _, new in
            if new == .fullAccess { controller.refresh() }
        }
    }

    @ViewBuilder
    private var monthTitle: some View {
        let title = Text(controller.selectedDate.formatted(.dateTime.month(.abbreviated)))
            .font(.system(size: compact ? 22 : 24, weight: .bold))
            .foregroundStyle(Color.white)
            .fixedSize()
        if let onMonthTap {
            Button {
                onMonthTap()
            } label: {
                title
                    .opacity(monthHovered ? 0.72 : 1)
                    .scaleEffect(monthHovered ? 1.04 : 1, anchor: .leading)
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.16), value: monthHovered)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.94))
            .onHover { monthHovered = $0 }
        } else {
            title
        }
    }

    // MARK: - Day strip

    private var strip: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(offsets, id: \.self) { offset in
                            let isCentre = calendar.isDate(date(for: offset), inSameDayAs: controller.selectedDate)
                            dayCell(offset, proxy: proxy)
                                .id(offset)
                                // Only the day in the middle swells. The falloff is narrower than one
                                // cell (36pt), so a neighbour of the centred day is never magnified.
                                .visualEffect { content, cell in
                                    let frame = cell.frame(in: .named("dayStrip"))
                                    let distance = abs(frame.midX - geo.size.width / 2)
                                    let measured = max(0, 1 - distance / 22)
                                    // At rest the selected day is the one in the middle: it is in focus straight away.
                                    let near = (!scrolling && isCentre) ? 1 : measured
                                    return content
                                        .scaleEffect(1 + 0.32 * near)
                                        .opacity(0.5 + 0.5 * near)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .background(StripScrollFinder(driver: driver))
                .scrollPosition(id: $centred, anchor: .center)
                // Margins let the first and last day reach the middle, so only one day is ever in focus.
                .contentMargins(.horizontal, max(0, (geo.size.width - 36) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByFew))
                .lockScrollAxis(.horizontal)
                .coordinateSpace(name: "dayStrip")
                .onScrollPhaseChange { _, phase in
                    scrolling = phase != .idle
                }
                // Whatever day reaches the middle becomes the selected day, so its events appear below.
                .onChange(of: centred) { _, new in
                    guard let new else { return }
                    // A click is bringing one day into the middle: the days passed on the way are not selected.
                    if Date() < clickLockUntil { return }
                    if let target = focusTarget, new != target { return }
                    let day = date(for: new)
                    guard !calendar.isDate(day, inSameDayAs: controller.selectedDate) else { return }
                    if !quiet { Haptics.hf3(lockout: 0.03) }   // a new date comes into focus
                    controller.select(day)
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.14),
                                           .init(color: .black, location: 0.86),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading,
                                   endPoint: .trailing)
                )
                .opacity(placed ? 1 : 0)
                // Today is put in the middle once, without animation, before anything can be seen.
                // After that the strip never moves by itself: only the person's own scrolling moves it.
                .onAppear {
                    quiet = true
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        centred = 0
                        proxy.scrollTo(0, anchor: .center)
                    }
                    DispatchQueue.main.async {
                        withTransaction(transaction) {
                            proxy.scrollTo(0, anchor: .center)
                            placed = true
                        }
                        quiet = false
                    }
                }
                // Only a real change of width (Duo size on or off) puts today back in the middle, with no animation.
                .onChange(of: geo.size.width) { _, _ in
                    recentreToday(proxy)
                }
                // Once the notch is closed the strip jumps back to today without animation,
                // so nothing moves when it is opened again.
                .onChange(of: controller.resetToken) { _, _ in
                    quiet = true
                    scrolling = false
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        centred = 0
                        proxy.scrollTo(0, anchor: .center)
                    }
                    DispatchQueue.main.async { quiet = false }
                }
                // The pointer came back: glide to today (no haptic for a move the app makes itself).
                .onChange(of: glideToken) { _, _ in
                    guard centred != 0 else { return }
                    quiet = true
                    withAnimation(.smooth(duration: 0.45)) {
                        centred = 0
                        proxy.scrollTo(0, anchor: .center)
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        quiet = false
                    }
                }
            }
        }
        .frame(height: stripHeight)
    }

    /// Puts today back exactly in the middle, without animation or haptic. Only while today is the day in focus,
    /// so a day the person scrolled to is left alone.
    private func recentreToday(_ proxy: ScrollViewProxy) {
        guard centred == 0 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(0, anchor: .center)
        }
    }

    private func date(for offset: Int) -> Date {
        let start = calendar.startOfDay(for: controller.today)
        return calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }

    /// v443: a click on a day brings it into the middle and into focus (it swells like the day the pointer scrolled to).
    /// The strip is moved both through its position binding and with the proxy, as every other move of the strip is: the
    /// binding alone did not always scroll, and the clicked day was then selected but never reached the middle.
    private func focusDay(_ offset: Int, proxy: ScrollViewProxy) {
        let day = date(for: offset)
        let changes = !calendar.isDate(day, inSameDayAs: controller.selectedDate)
        if changes { Haptics.hf3(lockout: 0.03) }   // a new date comes into focus
        focusTarget = offset
        clickLockUntil = Date().addingTimeInterval(0.8)
        scrolling = true   // the days swell by their distance from the middle while the strip glides
        // v460: the strip's own scroll view is moved directly, by the number of days between the clicked one and the one in
        // the middle (each day is 36 pt wide). Moving it through SwiftUI's scroll position did not reliably reach the
        // clicked day. If the scroll view cannot be found, the SwiftUI way is used as before.
        let cells = offset - (centred ?? 0)
        if cells == 0 || driver.glide(byCells: cells, duration: 0.34) {
            // moved (or already there)
        } else {
            withAnimation(.smooth(duration: 0.34)) {
                centred = offset
                proxy.scrollTo(offset, anchor: .center)
            }
        }
        controller.select(day)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard focusTarget == offset else { return }
            focusTarget = nil
            // The clicked day is the one in focus whatever the glide did: if the strip did not end exactly on it (the
            // snapping can stop one day off), it is put there now, without animation, and the day swells.
            scrolling = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                centred = offset
                proxy.scrollTo(offset, anchor: .center)
            }
        }
    }

    private func dayCell(_ offset: Int, proxy: ScrollViewProxy) -> some View {
        let day = date(for: offset)
        let isToday = offset == 0
        let isSelected = calendar.isDate(day, inSameDayAs: controller.selectedDate)
        let weekday = isToday
            ? day.formatted(.dateTime.weekday(.abbreviated)).uppercased()
            : day.formatted(.dateTime.weekday(.narrow))
        return Button {
            focusDay(offset, proxy: proxy)
        } label: {
            VStack(spacing: 3) {
                Text(weekday)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isToday ? mutedRed : Color.white.opacity(0.45))
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 18, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? blue : Color.white.opacity(isSelected ? 1 : 0.65))
            }
            .frame(width: 36, height: stripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Events

    @ViewBuilder
    private var eventsArea: some View {
        switch controller.status {
        case .fullAccess:
            if controller.events.isEmpty {
                if showsEmptyHint {
                let hint = calendar.isDateInToday(controller.selectedDate) ? "Nothing for today" : "Nothing planned"
                Group {
                    if compact {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.system(size: 12, weight: .medium))
                            Text(hint)
                                .font(.system(size: 11, weight: .medium))
                        }
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.system(size: 16, weight: .medium))
                            Text(hint)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Every event of the day is listed; with more than fit the list scrolls (with a soft fade at the
                // bottom edge). The standalone page keeps its short two-line summary.
                if showsEmptyHint {
                    // v505: in Duo (compact) only the FIRST event is shown; the viewport is exactly one row high, so the
                    // second one no longer peeks in at the bottom (v506: the row is 27 pt, the full two lines of text). It is reached by scrolling, one event per step.
                    let oneAtATime = compact && controller.events.count > 1
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 5) {
                            ForEach(controller.events) { event in
                                // v506: the row is two lines of text (about 25 pt), not the 22 pt of its colour bar: the viewport
                                // of v505 was 22 pt and cut the time line off at the bottom. Rows and viewport are now both 27 pt.
                                eventRow(event).frame(height: oneAtATime ? 27 : nil)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.bottom, !oneAtATime && controller.events.count > 2 ? 10 : 0)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollBounceBehavior(.basedOnSize)
                    .lockScrollAxis(.vertical)
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: !oneAtATime && controller.events.count > 2 ? 0.86 : 1),
                                               .init(color: !oneAtATime && controller.events.count > 2 ? .clear : .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: oneAtATime ? 27 : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(spacing: 5) {
                        ForEach(controller.events.prefix(2)) { event in
                            eventRow(event)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        case .notDetermined:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Allow calendar access")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let color = Color(nsColor: event.color)
        let time = event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(time)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
    }
}


// MARK: - Moving the strip's scroll view (v460)

/// Holds the NSScrollView behind the day strip and glides it sideways by whole days.
final class StripScrollDriver {
    weak var scroll: NSScrollView?
    /// Width of one day cell in the strip.
    static let cellWidth: CGFloat = 36

    /// Glides the strip by `cells` days (positive = to later days). False when the scroll view is not known yet.
    func glide(byCells cells: Int, duration: TimeInterval) -> Bool {
        guard let scroll, let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let lowest = -insets.left
        let highest = max(lowest, document.frame.width - clip.bounds.width + insets.right)
        let target = min(max(clip.bounds.origin.x + CGFloat(cells) * Self.cellWidth, lowest), highest)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.origin.y))
        } completionHandler: {
            MainActor.assumeIsolated { scroll.reflectScrolledClipView(clip) }
        }
        return true
    }
}

/// Finds the NSScrollView that SwiftUI draws for the strip (the one this view was placed behind) and hands it to the driver.
private struct StripScrollFinder: NSViewRepresentable {
    let driver: StripScrollDriver

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.driver = driver
        return view
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.driver = driver
        view.attach()
    }

    final class FinderView: NSView {
        var driver: StripScrollDriver?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            // The scroll view may not be in the window's view tree yet on the first pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attach() }
        }

        func attach() {
            guard window != nil else { return }
            if let found = findScrollView() { driver?.scroll = found }
        }

        private func findScrollView() -> NSScrollView? {
            var ancestor: NSView? = superview
            while let level = ancestor {
                var best: (NSScrollView, CGFloat)?
                collect(in: level) { candidate in
                    let overlap = self.convert(self.bounds, to: nil).intersection(candidate.convert(candidate.bounds, to: nil))
                    guard !overlap.isNull else { return }
                    let area = overlap.width * overlap.height
                    if area > (best?.1 ?? 0) { best = (candidate, area) }
                }
                if let best { return best.0 }
                ancestor = level.superview
            }
            return nil
        }

        private func collect(in view: NSView, _ visit: (NSScrollView) -> Void) {
            for sub in view.subviews {
                if let scroll = sub as? NSScrollView { visit(scroll) }
                collect(in: sub, visit)
            }
        }
    }
}
