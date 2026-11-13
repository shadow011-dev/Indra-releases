import AppKit
import SwiftUI

/// Every haptic the Mac can produce, named hf1, hf2, ... so one can be picked for each place in the app.
///
/// hf1-hf3 are the three patterns the system offers (`NSHapticFeedbackManager`).
/// hf4 and up fire the trackpad motor directly through the system's multitouch framework, one per
/// actuation ID (1 to 16). That path is private, so it is looked up at run time and only works when the
/// app is allowed to reach the trackpad (the full-access build); `HapticLab.motorAvailable` says whether it is.
struct HapticModel: Identifiable {
    enum Source {
        case pattern(NSHapticFeedbackManager.FeedbackPattern)
        case actuation(Int32)
    }

    let number: Int
    let name: String
    let note: String
    let source: Source

    var id: Int { number }
    var code: String { "hf\(number)" }

    /// The system patterns, then actuation IDs 1...16. IDs 1-6, 15 and 16 are the ones trackpads respond to;
    /// the rest are usually silent, so they are listed last.
    static let patterns: [HapticModel] = [
        HapticModel(number: 1, name: "Generic", note: "System pattern, the standard tap", source: .pattern(.generic)),
        HapticModel(number: 2, name: "Alignment", note: "System pattern, a snap into place", source: .pattern(.alignment)),
        HapticModel(number: 3, name: "Level change", note: "System pattern, a step up or down", source: .pattern(.levelChange))
    ]

    static let actuations: [HapticModel] = [1, 2, 3, 4, 5, 6, 15, 16].enumerated().map { index, id in
        HapticModel(number: 4 + index, name: "Actuation \(id)", note: "Trackpad motor, ID \(id)", source: .actuation(Int32(id)))
    }

    static let others: [HapticModel] = [7, 8, 9, 10, 11, 12, 13, 14].enumerated().map { index, id in
        HapticModel(number: 12 + index, name: "Actuation \(id)", note: "Trackpad motor, ID \(id), usually silent", source: .actuation(Int32(id)))
    }

    static var all: [HapticModel] { patterns + actuations + others }
}

/// Plays a haptic as one tap, or as two or three quick taps in a row.
///
/// The Mac gives no strength dial: each haptic has one fixed strength, so the only thing that can change is
/// how many taps are played a few milliseconds apart. One tap is the plain haptic.
@MainActor
enum HapticLab {
    static var motorAvailable: Bool { TrackpadActuator.shared.isAvailable }

    static func play(_ model: HapticModel, taps: Int) {
        let count = max(1, min(taps, 3))
        Task { @MainActor in
            for step in 0..<count {
                fire(model)
                if step < count - 1 { try? await Task.sleep(nanoseconds: 70_000_000) }
            }
        }
    }

    private static func fire(_ model: HapticModel) {
        guard Preferences.hapticsEnabled else { return }   // v426: the notch / main window switch covers the lab too
        switch model.source {
        case .pattern(let pattern):
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        case .actuation(let id):
            TrackpadActuator.shared.fire(id) { fired in
                // The motor can't be reached: the nearest thing the system allows.
                if !fired { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
            }
        }
    }
}

/// A temporary page to try every haptic and pick one (and a strength) for each place in the app.
struct HapticLabPage: View {
    @State private var taps: [Int: Int] = [:]

    var body: some View {
        SettingsPage(.hapticLab) {
            SettingsCard("System patterns") {
                rows(HapticModel.patterns)
            }

            SettingsCard("Trackpad motor") {
                rows(HapticModel.actuations)
            }

            SettingsCard("Other actuation IDs") {
                rows(HapticModel.others)
            }
        }
    }

    private func rows(_ models: [HapticModel]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { RowDivider() }
                HapticRow(model: model, taps: binding(for: model))
            }
        }
    }

    private func binding(for model: HapticModel) -> Binding<Int> {
        Binding(get: { taps[model.number] ?? 1 },
                set: { taps[model.number] = $0 })
    }
}

private struct HapticRow: View {
    let model: HapticModel
    @Binding var taps: Int
    @State private var hovering = false

    var body: some View {
        SettingRow(title: "\(model.code) · \(model.name)", subtitle: model.note) {
            HStack(spacing: 10) {
                Picker("", selection: $taps) {
                    Text("1×").tag(1)
                    Text("2×").tag(2)
                    Text("3×").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                Text("Hover")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accent.opacity(hovering ? 1 : 0.8)))
                    .contentShape(Capsule())
                    .onHover { inside in
                        hovering = inside
                        if inside { HapticLab.play(model, taps: taps) }
                    }
            }
        }
    }
}
