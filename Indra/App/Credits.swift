import SwiftUI
import AppKit

/// Third-party credits. Face Lock is built on Glance (MIT), which requires its copyright and permission notice to travel
/// with the app; the same text lives in docs/THIRD_PARTY_NOTICES.md in the repository.
enum Credits {
    static let glanceURL = URL(string: "https://github.com/jonnyoo/glance")!

    static let licenses = """
Glance (Face Lock): https://github.com/jonnyoo/glance

MIT License

Copyright (c) 2026 Jonathan Zhou

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

SkyLightWindow (lock screen window): https://github.com/Lakr233/SkyLightWindow
MIT License, Copyright (c) 2025 Lakr Aream. The permission notice above applies.

InsightFace (ArcFace model): https://github.com/deepinsight/insightface
The recognition model is an InsightFace pretrained model, provided for non-commercial research purposes only.
"""
}

/// The small credit at the bottom of Settings > Face Lock, with the licences one click away.
struct FaceLockCredit: View {
    @State private var showLicenses = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Face Lock is based on")
                Link("Glance", destination: Credits.glanceURL)
                Text("by Jonathan Zhou (MIT license)")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)

            Button(showLicenses ? "Hide licenses" : "Licenses") {
                withAnimation(.smooth(duration: 0.25)) { showLicenses.toggle() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)

            if showLicenses {
                Text(Credits.licenses)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background { CardBackground() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}
