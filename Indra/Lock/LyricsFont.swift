import SwiftUI
import AppKit
import CoreText

/// The typeface of the lyrics on the lock screen: six very different faces.
/// Names saved by older versions map to the closest new face (see `resolve`).
enum LyricsFont: String, CaseIterable, Identifiable {
    case shandey      // Youth Shandey (the default)
    case snell        // flowing script
    case didot        // fashion-magazine serif
    case copperplate  // engraved caps
    case marker       // hand-written
    case fajardose    // Miss Fajardose, formal script

    var id: String { rawValue }

    /// Anything not recognised (including the old default "system") opens as Youth Shandey.
    static func resolve(_ raw: String) -> LyricsFont {
        switch raw {
        case "rounded": return .marker
        case "optima": return .copperplate
        default: return LyricsFont(rawValue: raw) ?? .shandey
        }
    }

    var title: String {
        switch self {
        case .snell: return "Snell Script"
        case .didot: return "Didot"
        case .copperplate: return "Copperplate"
        case .marker: return "Marker Felt"
        case .fajardose: return "Miss Fajardose"
        case .shandey: return "Youth Shandey"
        }
    }

    private var postScriptName: String {
        switch self {
        case .snell: return "SnellRoundhand-Bold"
        case .didot: return "Didot-Bold"
        case .copperplate: return "Copperplate-Bold"
        case .marker: return "MarkerFelt-Wide"
        case .fajardose: return "MissFajardose-Regular"
        case .shandey: return "YouthShandey-Regular"
        }
    }

    /// Optical size correction so every face reads about as big as the others at the same point size.
    private var sizeScale: CGFloat {
        switch self {
        case .snell: return 1.18
        case .didot: return 1.0
        case .copperplate: return 0.92
        case .marker: return 1.0
        case .fajardose: return 1.35
        case .shandey: return 1.0
        }
    }

    /// The font files shipped inside the app, registered once for this process.
    private static let registered: Bool = {
        let bundle = Bundle.main
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// The face at the given size. A missing font falls back to the bold system serif.
    func font(size: CGFloat) -> Font {
        _ = LyricsFont.registered
        let scaled = size * sizeScale
        if NSFont(name: postScriptName, size: scaled) != nil {
            return .custom(postScriptName, fixedSize: scaled)
        }
        return .system(size: size, weight: .bold, design: .serif)
    }
}

/// Tiles showing a sample line in every typeface. The chosen one gets a blue frame.
struct LyricsFontPicker: View {
    @Binding var raw: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        let current = LyricsFont.resolve(raw)
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(LyricsFont.allCases) { face in
                let selected = face == current
                Button {
                    guard !selected else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { raw = face.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        Text("Aa Lyrics")
                            .font(face.font(size: 19))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(selected ? AnyShapeStyle(Theme.accent.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.05)))
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.10)),
                                              lineWidth: selected ? 1.5 : 1))
                        Text(face.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
