import SwiftUI

/// What the lock screen HUD shows right now.
struct LockHUD: Equatable {
    let kind: HUDKind
    /// 0 ... 1
    let value: Double
    let muted: Bool
}

/// Volume / brightness overlay for the lock screen: only this, nothing else.
/// It is the notch's downline HUD (icon, percentage, bar) hanging below the notch. It grows out of the
/// notch itself and folds back into it, with the same springs the notch uses on the desktop.
struct LockHUDView: View {
    let hud: LockHUD
    /// False while the HUD is the bare notch (just before it grows and while it folds away).
    let visible: Bool
    let tint: Color

    var body: some View {
        let metrics = NotchMetrics.make(for: NotchMetrics.notchScreen(), island: false)
        let full = metrics.hudDownlineSize
        let size = visible ? full : metrics.closedSize
        ZStack(alignment: .top) {
            Color.black
            DownlineHUDView(kind: hud.kind,
                            value: hud.value,
                            muted: hud.muted,
                            tint: tint,
                            notchHeight: metrics.closedSize.height)
                .frame(width: full.width, height: full.height, alignment: .top)
                .opacity(visible ? 1 : 0)
                .blur(radius: visible ? 0 : 6)
                .animation(.easeOut(duration: visible ? 0.26 : 0.14).delay(visible ? 0.07 : 0), value: visible)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topCornerRadius: visible ? 18 : 0, bottomCornerRadius: visible ? 28 : 10))
        .animation(visible ? NotchMotion.hudOpen : NotchMotion.hudClose, value: visible)
        .allowsHitTesting(false)
    }
}

/// A Bluetooth device shown over the lock screen.
struct LockBluetooth: Equatable {
    let id = UUID()
    let kind: BluetoothKind
    let name: String
    let connected: Bool
}

/// The notch's Bluetooth card for the lock screen: the device's picture on the left, the green / red dot on the right,
/// and its name in a strip below. Like the HUD it grows out of the notch and folds back into it.
struct LockBluetoothView: View {
    let device: LockBluetooth
    /// False while the card is the bare notch (just before it grows and while it folds away).
    let visible: Bool
    @AppStorage(Preferences.bluetoothEarbudStyleKey) private var earbudStyle = "pro"

    var body: some View {
        let metrics = NotchMetrics.make(for: NotchMetrics.notchScreen(), island: false)
        let slot = metrics.compactSlot
        let full = device.name.isEmpty ? metrics.hudDownlineSize : metrics.bluetoothDownlineSize(slot: slot)
        let size = visible ? full : metrics.closedSize
        ZStack(alignment: .top) {
            Color.black
            if visible {
                ZStack(alignment: .top) {
                    if !device.name.isEmpty {
                        BluetoothNameDownline(name: device.name, notchHeight: metrics.closedSize.height)
                            .frame(width: full.width, height: full.height, alignment: .top)
                    }
                    HStack(spacing: 0) {
                        BluetoothGlyph(kind: device.kind, style: earbudStyle, size: 26)
                            .padding(.leading, 9)
                            .frame(width: slot, alignment: .leading)
                        Spacer(minLength: 0)
                        BluetoothDot(connected: device.connected)
                            .padding(.trailing, 9)
                            .frame(width: slot, alignment: .trailing)
                    }
                    .frame(width: metrics.closedSize.width + slot * 2, height: 26)
                    .frame(width: full.width, height: metrics.closedSize.height, alignment: .top)
                }
                .frame(width: full.width, height: full.height, alignment: .top)
                .transition(.opacity.animation(.easeOut(duration: 0.14)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topCornerRadius: visible ? 18 : 0, bottomCornerRadius: visible ? 28 : 10))
        .animation(visible ? NotchMotion.hudOpen : NotchMotion.hudClose, value: visible)
        .allowsHitTesting(false)
    }
}

/// The battery changing while the screen is locked: charger plugged in, pulled out, low battery, charge limit.
struct LockBattery: Equatable {
    let id = UUID()
    let percent: Int
    let charging: Bool
    let pluggedIn: Bool

    var title: String {
        if charging || pluggedIn { return percent >= 100 ? "Fully charged" : "Charging" }
        if percent <= 10 { return "Battery very low" }
        return percent <= 20 ? "Low battery" : "On battery"
    }
}

/// The notch's battery card for the lock screen, exactly the closed notch's own: the notch widens on both sides,
/// the battery icon sits on the left and the percentage on the right (no text strip). It grows out of the notch
/// and folds back into it.
struct LockBatteryHUDView: View {
    let battery: LockBattery
    /// False while the card is the bare notch (just before it grows and while it folds away).
    let visible: Bool

    var body: some View {
        let metrics = NotchMetrics.make(for: NotchMetrics.notchScreen(), island: false)
        let slot = metrics.idleSlot
        let full = metrics.closedBodySize(slot: slot)
        let size = visible ? full : metrics.closedSize
        let charging = battery.charging || battery.pluggedIn
        ZStack(alignment: .top) {
            Color.black
            if visible {
                HStack(spacing: 0) {
                    BatteryGlyph(percent: battery.percent, charging: charging)
                        .id("\(battery.percent)-\(charging)")
                        .padding(.leading, 7)
                        .frame(width: slot, alignment: .leading)
                    Spacer(minLength: 0)
                    BatteryPercent(percent: battery.percent, charging: charging)
                        .id("\(battery.percent)-\(charging)")
                        .padding(.trailing, 7)
                        .frame(width: slot, alignment: .trailing)
                }
                .frame(width: metrics.closedSize.width + slot * 2, height: 26)
                .frame(width: full.width, height: metrics.closedSize.height, alignment: .top)
                .transition(.opacity.animation(.easeOut(duration: 0.26).delay(0.07)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topCornerRadius: visible ? 8 : 0, bottomCornerRadius: visible ? 14 : 10))
        .animation(visible ? NotchMotion.hudOpen : NotchMotion.hudClose, value: visible)
        .allowsHitTesting(false)
    }
}
