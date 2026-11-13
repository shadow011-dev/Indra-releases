import SwiftUI

/// v477: lock screen only. With it on, the face animation takes the album's gradient (the colours of the notch
/// waveform, left to right) instead of one album colour.
struct AlbumGradientRow: View {
    @AppStorage("faceLockAlbumGradient") private var on = false

    var body: some View {
        SettingsRowContent(title: "Album gradient on lock screen") {
            FaceLockToggle(isOn: $on)
        }
    }
}

struct AnimationColorRow: View {
    @AppStorage("faceLockAnimationColor") private var selected = AnimationColor.blue.rawValue

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Color")
                    .font(.system(size: 15, weight: .medium))
                Text("Unlock animation color")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                ForEach(AnimationColor.allCases.filter { $0 != .custom }) { option in
                    Button {
                        selected = option.rawValue
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(selected == option.rawValue ? 0.95 : 0), lineWidth: 2)
                                    .padding(-4)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(option.rawValue.capitalized)
                }
            }
        }
        CustomColorControl()
        }
        .padding(.vertical, 6)
    }
}