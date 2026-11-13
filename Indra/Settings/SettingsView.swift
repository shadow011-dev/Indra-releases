import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.expandOnHoverKey) private var expandOnHover = true
    @AppStorage(Preferences.blipEnabledKey) private var blipEnabled = true
    @AppStorage(Preferences.liveBatteryKey) private var liveBattery = true
    @AppStorage(Preferences.batteryLimitKey) private var batteryLimit = 100.0
    @AppStorage(Preferences.liveLockKey) private var liveLock = true
    @AppStorage(Preferences.trayFirstKey) private var trayFirst = true
    @AppStorage(Preferences.showDateKey) private var showDate = false
    @AppStorage(Preferences.showCalendarKey) private var showCalendar = true
    @AppStorage(Preferences.idleActivityKey) private var idleActivity = "duo"
    @AppStorage(Preferences.autoIdentifyKey) private var autoIdentify = true
    @AppStorage(Preferences.idleMostRecentKey) private var idleMostRecent = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = newValue
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Expand notch on hover", isOn: $expandOnHover)
                Toggle("Launch at login", isOn: launchBinding)
            }
            Section("When idle") {
                Toggle("Follow last activity", isOn: $idleMostRecent)
                IdleActivityPicker(selection: $idleActivity, calendarAllowed: true)
                    .disabled(idleMostRecent)
                    .opacity(idleMostRecent ? 0.4 : 1)
            }
            Section("Live activities") {
                Toggle("Battery (plug in, low, full)", isOn: $liveBattery)
                HStack {
                    Text("Show charging animation at")
                    Slider(value: $batteryLimit, in: 80...100, step: 10)
                    Text("\(Int(batteryLimit))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(!liveBattery)
                Toggle("Lock and unlock", isOn: $liveLock)
            }
            Section("Calendar") {
                Toggle("Date and events", isOn: $showDate)
                    .disabled(idleActivity == "duo")
                if showDate {
                    Text("With the date page on, click the date to open the month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Files Tray") {
                Toggle("Open tray first when it has files", isOn: $trayFirst)
                Toggle("Blip integration", isOn: $blipEnabled)
                    .disabled(FileSharing.blipURL == nil)
                if FileSharing.blipURL == nil {
                    Text("Blip is not installed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 820)
    }
}

/// Four selectable tiles: Nothing / Player / Calendar / Both.
private struct IdleActivityPicker: View {
    @Binding var selection: String
    let calendarAllowed: Bool

    var body: some View {
        HStack(spacing: 10) {
            option("none", "Nothing", symbol: "nosign", enabled: true)
            option("playing", "Player", symbol: "play.fill", enabled: true)
            option("calendar", "Calendar", symbol: "calendar", enabled: calendarAllowed)
            option("duo", "Both", symbol: "rectangle.on.rectangle", enabled: calendarAllowed)
        }
    }

    private func option(_ value: String, _ title: String, symbol: String, enabled: Bool) -> some View {
        let selected = selection == value
        return Button {
            selection = value
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.22)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                    )
                Text(title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
