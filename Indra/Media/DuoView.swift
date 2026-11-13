import SwiftUI

/// NotchNook-style "Nook" page: now playing on the left, scrollable calendar on the right, split down the middle.
struct DuoView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var identifier: SongIdentifier
    @ObservedObject var calendar: CalendarController
    let levels: SmoothedLevel
    let active: Bool
    /// v443: clicking the month name opens the full month calendar (the same page as without Duo).
    var onOpenMonth: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // The cover sits at the bottom of the page, PlayerView.duoCoverBottomGap above the notch's edge.
                PlayerView(media: media, identifier: identifier, levels: levels, active: active, compact: true)
                    .frame(width: geo.size.width * NotchMetrics.duoPlayerFraction, height: geo.size.height, alignment: .bottomLeading)
                    .offset(y: NotchMetrics.duoBottomMargin - PlayerView.duoCoverBottomGap)
                Rectangle()
                    .fill(Color.white.opacity(0.16))   // v443: 7 % brighter (was 0.15)
                    .frame(width: 1)
                    .padding(.vertical, 4)
                DateStripView(controller: calendar, compact: true, onMonthTap: onOpenMonth)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
            }
        }
    }
}

/// Shown on the Duo page when nothing is playing.
struct NowPlayingEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 1) {
                Text("No app seems to be running")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("Wanna open one?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            HStack(spacing: 12) {
                appButton(bundleID: "com.apple.Music", fallbackSymbol: "music.note")
                appButton(bundleID: "com.spotify.client", fallbackSymbol: "waveform")
                youtubeButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appButton(bundleID: String, fallbackSymbol: String) -> some View {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return Button {
            guard let appURL else { return }
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            Group {
                if let appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .grayscale(0.85)
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.14)))
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var youtubeButton: some View {
        Button {
            if let url = URL(string: "https://www.youtube.com") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.93, green: 0.13, blue: 0.13))
                .frame(width: 30, height: 22)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                )
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
