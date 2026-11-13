import SwiftUI
import AppKit

/// The calm chime that goes with the welcome animation.
enum WelcomeSound {
    private static var sound: NSSound?

    static func play() {
        guard let url = Bundle.main.url(forResource: "IndraWelcome", withExtension: "wav"),
              let chime = NSSound(contentsOf: url, byReference: false) else { return }
        chime.volume = 0.55
        sound = chime
        chime.play()
    }
}
