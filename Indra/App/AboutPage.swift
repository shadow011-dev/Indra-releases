import AppKit
import SwiftUI

/// Version, the saved problems (with a report to copy or email) and the credit line.
struct AboutPage: View {
    @State private var entries: [ProblemEntry] = []
    @State private var copied = false
    @State private var confirmClear = false
    @ObservedObject private var health = HealthMonitor.shared

    var body: some View {
        SettingsPage(.about) {
            appCard

            UpdatesCard()

            SettingsCard("Self-check") {
                if health.issues.isEmpty {
                    SettingRow(symbol: "checkmark.shield.fill", tint: Theme.green,
                               title: "Everything is working",
                               subtitle: health.lastCheck.map { "Last checked \(IndraLog.dateText($0))" } ?? "Checking ...") {
                        StatusPill(ok: true, text: "All good")
                    }
                } else {
                    ForEach(Array(health.issues.enumerated()), id: \.element.id) { index, issue in
                        if index > 0 { RowDivider() }
                        SettingRow(symbol: "exclamationmark.triangle.fill", tint: Theme.orange,
                                   title: issue.title,
                                   subtitle: issue.detail.isEmpty ? nil : issue.detail) {
                            if let fix = issue.fix {
                                ActionButton(title: fix.buttonTitle, kind: .primary) { fix.perform() }
                            }
                        }
                    }
                }
                RowDivider()
                SettingRow(symbol: "arrow.clockwise", tint: Theme.blue, title: "Check now") {
                    ActionButton(title: "Run self-check", symbol: "stethoscope") { health.checkNow() }
                }
            }

            SettingsCard("Problem report") {
                SettingRow(symbol: "ladybug.fill", tint: Theme.red,
                           title: "Saved problems") {
                    StatusPill(ok: entries.isEmpty, text: entries.isEmpty ? "All good" : "\(entries.count) saved")
                }
                RowDivider()
                SettingRow(symbol: "envelope.fill", tint: Theme.blue,
                           title: "Send to Shadow",
                           subtitle: IndraLog.supportEmail) {
                    HStack(spacing: 8) {
                        ActionButton(title: copied ? "Copied" : "Copy report",
                                     symbol: copied ? "checkmark" : "doc.on.doc") {
                            copyReport()
                        }
                        ActionButton(title: "Send email", symbol: "paperplane.fill", kind: .primary) {
                            sendEmail()
                        }
                    }
                }
                RowDivider()
                SettingRow(symbol: "trash.fill", tint: Theme.gray, title: "Clear saved problems") {
                    ActionButton(title: "Clear", kind: .destructive) { confirmClear = true }
                        .disabled(entries.isEmpty)
                }
            }

            if !entries.isEmpty {
                SettingsCard("Saved problems") {
                    let shown = Array(entries.reversed().prefix(40))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { RowDivider() }
                        ProblemRow(entry: entry)
                    }
                }
            }

            Text("Created by Shadow")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .onAppear { entries = IndraLog.entries() }
        .onReceive(NotificationCenter.default.publisher(for: IndraLog.changed)) { _ in
            entries = IndraLog.entries()
        }
        .confirmationDialog("Clear all saved problems?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { IndraLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be removed from this Mac. Copy the report first if you still need it.")
        }
    }

    private var appCard: some View {
        HStack(spacing: 14) {
            Image("IndraLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppBrand.name)
                    .font(.system(size: 19, weight: .bold))
                Text("Version \(IndraLog.appVersion) · Build \(IndraLog.appBuild)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            StatusPill(ok: !SensoryDiagnostics.isSandboxed,
                       text: SensoryDiagnostics.isSandboxed ? "Standard" : "Full access")
        }
        .padding(16)
        .background { CardBackground() }
    }

    private func copyReport() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(IndraLog.report(), forType: .string)
        withAnimation(.smooth(duration: 0.25)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.smooth(duration: 0.25)) { copied = false }
        }
    }

    /// Copies the full report, then opens a new email to Shadow; paste the report into it.
    private func sendEmail() {
        copyReport()
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = IndraLog.supportEmail
        parts.queryItems = [
            URLQueryItem(name: "subject", value: "Indra \(IndraLog.appVersion) (\(IndraLog.appBuild)) problem report"),
            URLQueryItem(name: "body", value: "Paste the copied report below:\n\n")
        ]
        if let url = parts.url {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One saved problem: kind, title and time; tap to see the details.
private struct ProblemRow: View {
    let entry: ProblemEntry
    @State private var open = false

    private var tint: Color {
        switch entry.kind {
        case "Crash": return Theme.red
        case "Freeze", "Unexpected exit": return Theme.orange
        case "System report": return Theme.violet
        default: return Theme.yellow
        }
    }

    private var details: String {
        var text = String(entry.detail.prefix(3000))
        if !entry.recent.isEmpty {
            if !text.isEmpty { text += "\n\n" }
            text += "Just before:\n" + entry.recent
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(entry.kind)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(open ? nil : 2)
                            .multilineTextAlignment(.leading)
                        Text(IndraLog.dateText(entry.date) + (entry.count > 1 ? "  ·  \(entry.count) times" : ""))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open && !details.isEmpty {
                Text(details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}


/// v544: "Updates": looks at the GitHub repository for a newer version and updates the app from here (see UpdateManager).
private struct UpdatesCard: View {
    @ObservedObject private var updater = UpdateManager.shared
    @State private var confirmUpdate = false
    @State private var tokenText = ""
    @State private var tokenSaved = UpdateToken.isSaved
    @State private var showTokenField = false
    @State private var developerOn = DeveloperAccess.isUnlocked
    @State private var showCodeField = false
    @State private var codeText = ""
    @State private var codeWrong = false

    private var title: String {
        switch updater.state {
        case .idle: return "Updates"
        case .checking: return "Checking for updates ..."
        case .upToDate: return "Indra is up to date"
        case .available(let version): return "Update available: build \(version)"
        case .updating(let step): return step
        case .failed: return "Could not update"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .idle: return "This is build \(UpdateManager.currentBuild). New versions are looked for automatically."
        case .checking: return "Looking for the newest version."
        case .upToDate(let date): return "Build \(UpdateManager.currentBuild). Last checked \(IndraLog.dateText(date)). New versions are looked for automatically."
        case .available: return "You have build \(UpdateManager.currentBuild). The new version is downloaded and Indra restarts."
        case .updating: return "Please leave Indra open. It restarts by itself when the new version is ready."
        case .failed(let reason): return reason
        }
    }

    private var symbol: String {
        switch updater.state {
        case .available: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .upToDate: return "checkmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch updater.state {
        case .available: return Theme.blue
        case .failed: return Theme.orange
        case .upToDate: return Theme.green
        default: return Theme.blue
        }
    }

    /// v549: the developer code. Never logged, never kept; only the right one unlocks the developer items on this Mac.
    private func submitCode() {
        if DeveloperAccess.unlock(codeText) {
            developerOn = true
            showCodeField = false
            codeWrong = false
            Trace.log("DEVELOPER mode unlocked on this Mac")
        } else {
            codeWrong = true
        }
        codeText = ""
    }

    var body: some View {
        SettingsCard("Updates") {
            SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
                if updater.isWorking {
                    ProgressView().controlSize(.small)
                } else if updater.availableVersion != nil {
                    ActionButton(title: "Update now", symbol: "arrow.down.circle.fill", kind: .primary) { confirmUpdate = true }
                } else {
                    ActionButton(title: "Check for updates", symbol: "arrow.clockwise") {
                        Task { await updater.check() }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 5) { if !developerOn { showCodeField = true } }
            if !updater.log.isEmpty, case .updating = updater.state {
                RowDivider()
                Text(updater.log.suffix(5).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            if showCodeField && !developerOn {
                RowDivider()
                HStack(spacing: 8) {
                    SecureField("Developer code", text: $codeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { submitCode() }
                    ActionButton(title: "Unlock", kind: .primary) { submitCode() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if codeWrong {
                    Text("That code is not right.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            // v549: everything below is for the developer only (unlocked with the code above).
            if developerOn {
                RowDivider()
                // v546: a Mac without a git login to the private repository signs in here, once, with a read-only token.
                SettingRow(symbol: "key.fill", tint: Theme.blue,
                           title: "GitHub access token",
                           subtitle: tokenSaved ? "Saved in this Mac's Keychain." : "Only for building updates from the source on a developer Mac. Not needed to update.") {
                    HStack(spacing: 8) {
                        if tokenSaved {
                            ActionButton(title: "Remove", kind: .destructive) {
                                UpdateToken.remove()
                                tokenSaved = false
                            }
                        }
                        ActionButton(title: tokenSaved ? "Replace" : "Add token", symbol: "key.fill") { showTokenField.toggle() }
                    }
                }
                if showTokenField {
                    HStack(spacing: 8) {
                        SecureField("Paste the token here", text: $tokenText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        ActionButton(title: "Save", kind: .primary) {
                            if UpdateToken.save(tokenText) {
                                tokenText = ""
                                tokenSaved = true
                                showTokenField = false
                                Task { await updater.check() }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                RowDivider()
                SettingRow(symbol: "lock.open.fill", tint: Theme.orange,
                           title: "Developer mode",
                           subtitle: "Unlocked on this Mac.") {
                    ActionButton(title: "Lock", kind: .destructive) {
                        DeveloperAccess.lock()
                        developerOn = false
                        showTokenField = false
                        Trace.log("DEVELOPER mode locked on this Mac")
                    }
                }
            }
        }
        .confirmationDialog("Update Indra now?", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Update and restart") { Task { await updater.update() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new version is downloaded, checked and installed. Indra then restarts. The old copy is kept in the cache folder.")
        }
        .onAppear {
            // v553: opening this page looks again unless a look was made in the last two minutes.
            Task { await updater.checkIfStale(olderThan: 120) }
        }
    }
}
