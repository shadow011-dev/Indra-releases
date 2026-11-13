import AppKit

/// v517: the optional sound when the Mac locks and unlocks (Settings > Lock Screen > Sounds).
/// v524: one fixed sound for each, in the style of the iPhone's: a short, dry, soft "tock" for locking and a slightly lighter,
/// higher one for unlocking. They are not picked from the system sounds any more. They are made in memory (like SoftSound), so
/// there is no audio file to ship; these are close imitations, not Apple's own recordings.
@MainActor
enum LockSounds {
    private static var current: NSSound?
    private static var lockWav: Data?
    private static var unlockWav: Data?

    static func play(locking: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: locking ? Preferences.lockSoundOnKey : Preferences.unlockSoundOnKey) else { return }
        preview(locking: locking)
    }

    /// v543: App Lock. An app that was unlocked plays the Mac's unlock sound (same switch: Settings > Lock Screen > Sounds).
    static func playAppUnlocked() { play(locking: false) }

    /// v543: App Lock. A face, fingerprint or password that did not unlock plays the lock sound twice (the lock-sound switch).
    /// v544: the two taps are 0.09 s apart (they were 0.24 s), and the second one no longer cuts the first one off: each is its own
    /// sound object, so the pair is a quick "tick-tick".
    static func playAppFailed() {
        guard UserDefaults.standard.bool(forKey: Preferences.lockSoundOnKey) else { return }
        play(clickOf: true, interrupt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { play(clickOf: true, interrupt: false) }
    }

    /// Plays the sound whatever the switch says (used when the switch is turned on, as a sample).
    static func preview(locking: Bool) {
        play(clickOf: locking, interrupt: true)
    }

    private static var extra: [NSSound] = []

    private static func play(clickOf locking: Bool, interrupt: Bool) {
        let data: Data
        if locking {
            if lockWav == nil { lockWav = makeClick(body: 170, bodyDecay: 55, tones: [(1850, 0.42, 105), (3050, 0.22, 135)], length: 0.16) }
            guard let wav = lockWav else { return }
            data = wav
        } else {
            if unlockWav == nil { unlockWav = makeClick(body: 230, bodyDecay: 70, tones: [(2350, 0.40, 120), (3700, 0.22, 150)], length: 0.13) }
            guard let wav = unlockWav else { return }
            data = wav
        }
        guard let sound = NSSound(data: data) else { return }
        sound.volume = 0.7
        if interrupt {
            current?.stop()
            current = sound
        } else {
            // Played on top of the one that is still ringing; kept alive until it has surely ended.
            extra.append(sound)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { extra.removeAll { $0 === sound } }
        }
        sound.play()
    }

    /// A short click: a low, quickly fading body, two bright ringing tones, and a few milliseconds of noise for the
    /// moment of contact. (frequency Hz, level, decay speed) for each tone.
    private static func makeClick(body: Double, bodyDecay: Double, tones: [(Double, Double, Double)], length: Double) -> Data {
        let rate = 44_100.0
        let count = Int(rate * length)
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt32 = 12_345   // the same noise every time
        for i in 0..<count {
            let t = Double(i) / rate
            let attack = min(1.0, t / 0.0006)                       // no pop at the very start
            var value = 0.5 * exp(-t * bodyDecay) * sin(2 * .pi * body * t)
            for (freq, level, decay) in tones {
                value += level * exp(-t * decay) * sin(2 * .pi * freq * t)
            }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            value += 0.28 * noise * exp(-t * 900)                   // the contact itself, gone in a few ms
            let tail = min(1.0, (length - t) / 0.02)                // the end fades to silence
            samples[i] = Int16(max(-1, min(1, value * 0.8 * attack * tail)) * Double(Int16.max))
        }
        return SoftSound.wavData(samples, rate: rate)
    }
}
