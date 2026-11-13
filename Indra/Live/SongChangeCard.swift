import SwiftUI

/// The song-change card. It hangs under the closed notch: the notch's own row above it keeps the artwork on the
/// left and the visualizer on the right, and this strip shows the title (with a note) and the artist (with a
/// microphone) side by side.
struct SongChangeDownline: View {
    let title: String
    let artist: String
    let notchHeight: CGFloat
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            // Title and artist side by side when both fit; with a long title only the title is shown.
            ViewThatFits(in: .horizontal) {
                if !artist.isEmpty {
                    HStack(spacing: 14) {
                        item(symbol: "music.note", text: title).fixedSize(horizontal: true, vertical: false)
                        item(symbol: "music.mic", text: artist).fixedSize(horizontal: true, vertical: false)
                    }
                }
                item(symbol: "music.note", text: title)
            }
            .padding(.horizontal, 36) // clear of the card's rounded bottom corners (28 pt radius)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
            .offset(y: shown ? 0 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
    }

    private func item(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.42))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
    }
}
