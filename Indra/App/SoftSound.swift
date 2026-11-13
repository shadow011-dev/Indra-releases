import AppKit

/// A short, soft, calm chime. Synthesized once in memory, so there is no audio file to ship.
enum SoftSound {
    private static var wav: Data?
    private static var focusWav: Data?
    private static var current: NSSound?

    /// Played when a to-do is ticked: two gentle rising notes that fade out slowly.
    static func taskDone() {
        if wav == nil { wav = makeWAV() }
        guard let wav, let sound = NSSound(data: wav) else { return }
        sound.volume = 0.5
        current?.stop()
        current = sound
        sound.play()
    }

    /// Played the moment a focus session starts and the notch has folded away: a soft, deep singing-bowl note
    /// with a slow, calm tail, and a faint low swell under it that rises with the wave across the screen.
    static func focusStart() {
        if focusWav == nil { focusWav = makeFocusWAV() }
        guard let focusWav, let sound = NSSound(data: focusWav) else { return }
        sound.volume = 0.55
        current?.stop()
        current = sound
        sound.play()
    }

    private static func makeFocusWAV() -> Data {
        let rate = 44_100.0
        let length = 3.4
        let count = Int(rate * length)
        // Bowl: a low note with its fifth and octave above, plus one slightly detuned partial that makes it shimmer.
        // (frequency Hz, level, decay speed)
        let partials: [(Double, Double, Double)] = [
            (196.00, 0.60, 1.05),   // G3
            (293.66, 0.26, 1.35),   // D4
            (392.00, 0.30, 1.60),   // G4
            (541.30, 0.10, 2.40),   // the bowl's inharmonic ring
            (394.10, 0.14, 1.60)    // detuned twin of G4: a slow beat
        ]
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            var value = 0.0
            let attack = min(1.0, t / 0.03)                      // soft strike, no click
            for (freq, level, decay) in partials {
                value += level * attack * exp(-t * decay) * sin(2 * .pi * freq * t)
            }
            // A quiet swell of low air that grows and fades with the wave.
            let swell = sin(.pi * min(1.0, t / 2.6))
            let sweep = 90 + 60 * min(1.0, t / 2.6)
            value += 0.16 * swell * swell * sin(2 * .pi * sweep * t)
            let tail = min(1.0, (length - t) / 0.25)             // the very end fades to silence
            samples[i] = Int16(max(-1, min(1, value * 0.55 * tail)) * Double(Int16.max))
        }
        return wavData(samples, rate: rate)
    }

    private static func makeWAV() -> Data {
        let rate = 44_100.0
        let length = 0.62
        let count = Int(rate * length)
        // (start seconds, frequency Hz, level): E5 then a soft B5 on top of the tail.
        let notes: [(Double, Double, Double)] = [(0.0, 659.25, 0.55), (0.11, 987.77, 0.38)]
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            var value = 0.0
            for (start, freq, level) in notes where t >= start {
                let age = t - start
                let attack = min(1.0, age / 0.018)              // soft start, no click
                let decay = exp(-age * 6.5)                     // slow, calm fade
                let tone = sin(2 * .pi * freq * age) + 0.18 * sin(4 * .pi * freq * age)
                value += level * attack * decay * tone
            }
            let tail = min(1.0, (length - t) / 0.05)            // fade the very end to silence
            samples[i] = Int16(max(-1, min(1, value * 0.5 * tail)) * Double(Int16.max))
        }

        return wavData(samples, rate: rate)
    }

    static func wavData(_ samples: [Int16], rate: Double) -> Data {
        let count = samples.count
        var data = Data()
        func put32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let bytes = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(bytes)
        for s in samples { put16(UInt16(bitPattern: s)) }
        return data
    }
}
