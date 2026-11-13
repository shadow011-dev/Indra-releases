import SwiftUI

/// Short help: the gestures and a few things worth knowing, one line each.
struct TipsPage: View {
    var body: some View {
        SettingsPage(.tips) {
            SettingsCard("Gestures") {
                GestureRow(title: "Hover", text: "Opens the notch")
                RowDivider()
                GestureRow(title: "Swipe down", text: "Next page")
                RowDivider()
                GestureRow(title: "Swipe up", text: "Closes it")
                RowDivider()
                GestureRow(title: "Swipe left", text: "Weather, or next song")
                RowDivider()
                GestureRow(title: "Swipe right", text: "To-do, or last song")
            }

            SettingsCard("Good to know") {
                TipRow(symbol: "cursorarrow.rays", tint: Theme.blue,
                       title: "Click instead of hover", text: "Turn hover off in General.")
                RowDivider()
                TipRow(symbol: "tray.fill", tint: Theme.teal,
                       title: "Files", text: "Drop files on the notch, then AirDrop them.")
                RowDivider()
                TipRow(symbol: "timer", tint: Theme.green,
                       title: "Focus timer", text: "In Duo, swipe down from the player to find it.")
                RowDivider()
                TipRow(symbol: "lock.fill", tint: Theme.indigo,
                       title: "Lock screen", text: "Play a song, then lock your Mac. Click the art or song name for lyrics.")
                RowDivider()
                TipRow(symbol: "contextualmenu.and.cursorarrow", tint: Theme.orange,
                       title: "Right-click the notch", text: "Settings, build number and quit.")
            }
        }
    }
}

private struct TipRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            IconGlyph(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Gestures

/// One gesture in a line: its name, then what it does.
private struct GestureRow: View {
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 96, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
