import EventKit
import SwiftUI

/// The calendar page when "Show date" is on: today's date on the left, the day's events on the right,
/// in the same colours and chip style as the full calendar page (CalendarView). Laid out for 390 x 175 like
/// the other full-page widgets, so it scales with the notch size.
struct DatePageView: View {
    @ObservedObject var controller: CalendarController
    /// Clicking the day or the date opens the month calendar.
    var onOpenMonth: (() -> Void)? = nil

    private let accent = Color(red: 0.882, green: 0.310, blue: 0.384)
    private let dim = Color(red: 0.447, green: 0.447, blue: 0.459)
    private let eventsX: CGFloat = 166
    private let maxEvents = 5

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Left side: weekday, big day number, month and year, each arriving after the one before.
            weekdayLabel.staggered(0, base: 0.05, step: 0.07)
            bigDate.staggered(1, base: 0.05, step: 0.07)
            monthLabel.staggered(2, base: 0.05, step: 0.07)
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 116)
                .offset(x: eventsX - 18, y: 30)
                .staggered(2, base: 0.05, step: 0.07)
            eventArea.staggered(3, base: 0.05, step: 0.07)
            // The whole date block (day name, number, month) is one click target.
            Color.clear
                .frame(width: eventsX - 18 - CalendarLayout.leftX + 12, height: 126)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenMonth?()
                }
                .offset(x: CalendarLayout.leftX - 12, y: 18)
        }
        .frame(width: CalendarLayout.size.width, height: CalendarLayout.size.height, alignment: .topLeading)
        .onAppear {
            // Load after the page transition, so the animation never stutters.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000)
                controller.activate()
            }
        }
    }

    // MARK: - Date

    private var weekdayLabel: some View {
        Text(controller.selectedDate.formatted(.dateTime.weekday(.wide)).uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent)
            .offset(x: CalendarLayout.leftX, y: 24)
    }

    private var bigDate: some View {
        Text("\(calendar.component(.day, from: controller.selectedDate))")
            .font(.system(size: 64, weight: .light))
            .foregroundStyle(Color.white)
            .offset(x: CalendarLayout.leftX - 2, y: 38)
    }

    private var monthLabel: some View {
        Text(controller.selectedDate.formatted(.dateTime.month(.wide).year()))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(dim)
            .offset(x: CalendarLayout.leftX, y: 124)
    }

    // MARK: - Events

    @ViewBuilder
    private var eventArea: some View {
        switch controller.status {
        case .fullAccess:
            if controller.events.isEmpty {
                // No events: the note sits in the middle of the column, not at its top edge.
                Text(calendar.isDateInToday(controller.selectedDate) ? "No events today" : "No events")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(dim)
                    .frame(width: CalendarLayout.rightX - eventsX, height: 116, alignment: .center)
                    .offset(x: eventsX, y: 30)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.events.prefix(maxEvents)) { event in
                        chip(event)
                    }
                    if controller.events.count > maxEvents {
                        Text("+\(controller.events.count - maxEvents) more")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(dim)
                            .padding(.leading, 4)
                    }
                }
                // Down in the middle of the column (like the "No events" note); a long list starts at the top.
                .frame(width: CalendarLayout.rightX - eventsX, height: 116,
                       alignment: controller.events.count > 4 ? .topLeading : .leading)
                .offset(x: eventsX, y: 30)
            }
        case .notDetermined:
            EmptyView()
        default:
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Allow calendar access")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 9)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .offset(x: eventsX, y: 30)
        }
    }

    private func chip(_ event: CalendarEvent) -> some View {
        let color = Color(nsColor: event.color)
        let title = event.isAllDay
            ? event.title
            : "\(event.start.formatted(date: .omitted, time: .shortened)) \(event.title)"
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Image(systemName: "calendar")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.7))
                )
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 5)
        .frame(height: 19)
        .frame(maxWidth: CalendarLayout.rightX - eventsX, alignment: .leading)
        .background(Capsule().fill(color.opacity(0.16)))
    }
}
