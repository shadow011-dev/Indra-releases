import EventKit
import SwiftUI

/// Fixed geometry (points, measured from the shape's top-left corner).
enum CalendarLayout {
    static let size = CGSize(width: 390, height: 175)
    static let leftX: CGFloat = 40.5
    static let rightX: CGFloat = 347
    static let gridX: CGFloat = 202
    static let gridTop: CGFloat = 35.5
    static let columnWidth: CGFloat = 20.8
}

/// Alcove-style calendar: weekday and big day number with the day's events on the left,
/// the month grid with event dots on the right.
struct CalendarView: View {
    @ObservedObject var controller: CalendarController
    /// Set when "Show date" is on: clicking the day or the date goes back to the date + events page.
    var onShowDate: (() -> Void)? = nil
    /// v443: opened from the Duo page by clicking the month: the day picked there stays selected (opening the page
    /// normally goes back to today).
    var keepsDay = false
    /// v445: on that page the header buttons sit in the top corners, so the weekday, the date and the events (and the month
    /// name, less) move down a little to leave them room.
    private var clearance: CGFloat { keepsDay ? 6 : 0 }

    /// The animation of one day giving way to the next: soft and quick, the same for every piece that changes.
    static let dayChange = Animation.smooth(duration: 0.34)
    /// The selection circle: a short cross-fade with a little scale, so it feels like it passes from date to date.
    static let circleChange = Animation.smooth(duration: 0.24)
    private let accent = Color(red: 0.882, green: 0.310, blue: 0.384)
    private let dim = Color(red: 0.447, green: 0.447, blue: 0.459)

    private var calendar: Calendar { Calendar.current }

    /// Opened from the date page: the layout is turned around, month grid on the left, the day and its events on the right.
    private var flipped: Bool { onShowDate != nil }
    /// Left edge of the day / date / events column.
    private var textX: CGFloat { flipped ? 204.5 : CalendarLayout.leftX }
    /// Width of that column. Flipped, its text is right-aligned against the right margin, the mirror of the normal layout.
    private let columnWidth: CGFloat = 145
    private var columnAlignment: Alignment { flipped ? .trailing : .leading }
    /// Left edge of the month grid.
    private var gridX: CGFloat { flipped ? 42.5 : CalendarLayout.gridX }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if flipped {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 116)
                    .offset(x: 188, y: 30)
            }
            monthLabel
            monthGrid
            // Left side: weekday, then the date, then the events, each arriving after the one before.
            ZStack(alignment: .topLeading) {
                weekdayLabel.staggered(0, base: 0.05, step: 0.07)
                bigDate.staggered(1, base: 0.05, step: 0.07)
                eventArea.staggered(2, base: 0.05, step: 0.07)
                if let onShowDate {
                    Color.clear
                        .frame(width: flipped ? columnWidth + 12 : 110, height: 56)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.hf2()
                            onShowDate()
                        }
                        .offset(x: flipped ? textX : textX - 12, y: 14)
                }
            }
            // v440: picking another day no longer swaps the whole left side. The weekday and the events blur into the
            // new ones, and only the digits that changed roll over in the big date (see the pieces below).
            .animation(CalendarView.dayChange, value: dayKey)
        }
        .frame(width: CalendarLayout.size.width, height: CalendarLayout.size.height, alignment: .topLeading)
        .onAppear {
            // Load after the page transition, so the animation never stutters.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000)
                if keepsDay { controller.refresh() } else { controller.activate() }
            }
        }
    }

    // MARK: - Left side

    /// Changes whenever another day is selected.
    private var dayKey: Int {
        Int(calendar.startOfDay(for: controller.selectedDate).timeIntervalSince1970)
    }

    private var weekdayLabel: some View {
        let text = controller.selectedDate.formatted(.dateTime.weekday(.abbreviated)).uppercased()
        return ZStack(alignment: columnAlignment) {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
                .id(text)
                .transition(.blurReplace)
        }
        .frame(width: columnWidth, alignment: columnAlignment)
        .offset(x: textX, y: 19 + clearance)
    }

    private var monthLabel: some View {
        Text(controller.today.formatted(.dateTime.month(.abbreviated)).uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: 60, alignment: flipped ? .leading : .trailing)
            .offset(x: flipped ? gridX + 3 : CalendarLayout.rightX - 60, y: 19 + min(clearance, 4))
    }

    private var bigDate: some View {
        let day = calendar.component(.day, from: controller.selectedDate)
        // numericText: only the digits that differ roll and blur into the new ones (11 -> 10 moves the last digit only).
        return Text("\(day)")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(Color.white)
            .contentTransition(.numericText(value: Double(day)))
            .frame(width: columnWidth, alignment: columnAlignment)
            .offset(x: flipped ? textX : textX - 1, y: 29 + clearance)
    }

    @ViewBuilder
    private var eventArea: some View {
        switch controller.status {
        case .fullAccess:
            let isToday = calendar.isDateInToday(controller.selectedDate)
            ZStack(alignment: flipped ? .topTrailing : .topLeading) {
                VStack(alignment: flipped ? .trailing : .leading, spacing: 4) {
                    if controller.events.isEmpty {
                        VStack(alignment: flipped ? .trailing : .leading, spacing: 2) {
                            Text(isToday ? "No events today" : "No events")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(dim)
                            Text(isToday ? "Your day is clear" : "This day is clear")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(dim.opacity(0.6))
                        }
                    } else {
                        ForEach(controller.events.prefix(2)) { event in
                            chip(event)
                        }
                    }
                }
                // The events of the old day blur out as the new day's blur in.
                .id(dayKey)
                .transition(.blurReplace)
            }
            .frame(width: columnWidth, alignment: columnAlignment)
            .offset(x: textX, y: 72 + clearance)
        case .notDetermined:
            EmptyView()
        default:
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Allow calendar access")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .offset(x: textX, y: 72 + clearance)
        }
    }

    private func chip(_ event: CalendarEvent) -> some View {
        let color = Color(nsColor: event.color)
        let title = event.isAllDay
            ? event.title
            : "\(event.start.formatted(date: .omitted, time: .shortened)) \(event.title)"
        return HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(
                    Image(systemName: "calendar")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.7))
                )
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 4)
        .frame(height: 15.5)
        .frame(maxWidth: 145, alignment: .leading)
        .background(Capsule().fill(color.opacity(0.16)))
    }

    // MARK: - Month grid

    private var headers: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return Array(repeating: "", count: 7) }
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    /// Weeks of day numbers for the current month; nil = blank cell.
    private var weeks: [[Int?]] {
        guard let month = calendar.dateInterval(of: .month, for: controller.today) else { return [] }
        let daysInMonth = calendar.range(of: .day, in: .month, for: month.start)?.count ?? 30
        let firstWeekday = calendar.component(.weekday, from: month.start)
        let lead = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Int?] = Array(repeating: nil, count: lead)
        cells.append(contentsOf: (1...daysInMonth).map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    private func isSundayColumn(_ column: Int) -> Bool {
        ((calendar.firstWeekday - 1 + column) % 7) + 1 == 1
    }

    private var monthGrid: some View {
        let weeks = self.weeks
        let pitch: CGFloat = weeks.count + 1 > 6 ? 17.5 : 20
        let headers = self.headers
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { column in
                    Text(headers[column])
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isSundayColumn(column) ? dim : Color.white)
                        .frame(width: CalendarLayout.columnWidth, height: pitch)
                }
            }
            ForEach(0..<weeks.count, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        cell(weeks[row][column], column: column, pitch: pitch)
                    }
                }
            }
        }
        .offset(x: gridX, y: CalendarLayout.gridTop)
    }

    /// Number colour: the selected day is dark on its white circle (white on today's red one), today is red when
    /// another day is picked, Sundays are dim.
    private func numberColor(isToday: Bool, isSelected: Bool, column: Int) -> Color {
        if isSelected { return isToday ? Color.white : Color.black.opacity(0.88) }
        if isToday { return accent }
        return isSundayColumn(column) ? dim : Color.white
    }

    @ViewBuilder
    private func cell(_ day: Int?, column: Int, pitch: CGFloat) -> some View {
        if let day {
            let isToday = calendar.component(.day, from: controller.today) == day
            let isSelected = calendar.component(.day, from: controller.selectedDate) == day
            Button {
                select(day)
            } label: {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(isToday ? accent : Color.white)
                            .frame(width: 17.5, height: 17.5)
                            .transition(.opacity.combined(with: .scale(scale: 0.78)))
                    }
                    Text("\(day)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(numberColor(isToday: isToday, isSelected: isSelected, column: column))
                    if !isToday, let colors = controller.dayDots[day] {
                        HStack(spacing: 2) {
                            ForEach(colors.indices, id: \.self) { index in
                                Capsule()
                                    .fill(Color(nsColor: colors[index]))
                                    .frame(width: 4.5, height: 1.5)
                            }
                        }
                        .offset(y: 7.5)
                    }
                }
                .animation(CalendarView.circleChange, value: isSelected)
                .frame(width: CalendarLayout.columnWidth, height: pitch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: CalendarLayout.columnWidth, height: pitch)
        }
    }

    private func select(_ day: Int) {
        guard let month = calendar.dateInterval(of: .month, for: controller.today),
              let date = calendar.date(byAdding: .day, value: day - 1, to: month.start) else { return }
        controller.select(date)
    }
}
