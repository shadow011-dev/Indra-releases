import Foundation

/// Writes lyrics in Latin (English) letters, so they can be read by someone who does not read the script.
/// It is a transliteration, not a translation: the sounds are kept, only the letters change.
///   Hindi  "क्या कर रहे हो"  ->  "Kya kar rahe ho"   (Hinglish, as people type it)
///   Other scripts (Arabic, Cyrillic, Greek, Korean, Japanese kana, Tamil, Thai ...) use the system's
///   transliteration and lose their accents. Everything runs on the Mac, with no network.
/// Words that are already in Latin letters are left exactly as they are.
enum LyricsRomanizer {
    /// One lyric line, with every non-Latin word turned into Latin letters.
    static func latin(_ text: String) -> String {
        guard needsWork(text) else { return text }
        var words: [String] = []
        for token in text.split(separator: " ", omittingEmptySubsequences: true) {
            words.append(word(String(token)))
        }
        var line = words.joined(separator: " ")
        // A line that began in another script starts with a capital, like a sentence.
        if let first = text.split(separator: " ").first, needsWork(String(first)), let head = line.first {
            line = head.uppercased() + line.dropFirst()
        }
        return line
    }

    /// True when the text holds letters outside the Latin alphabets.
    static func needsWork(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value > 0x24F && !(0x1E00...0x1EFF).contains(scalar.value) && scalar.properties.isAlphabetic
        }
    }

    private static func word(_ word: String) -> String {
        guard needsWork(word) else { return word }
        let devanagari = word.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        let work = NSMutableString(string: word)
        guard CFStringTransform(work as CFMutableString, nil, kCFStringTransformToLatin, false) else { return word }
        var text = work as String
        if devanagari { text = hinglish(text) }
        let plain = NSMutableString(string: text)
        CFStringTransform(plain as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
        return plain as String
    }

    private static let consonants = "bcdfghjklmnpqrstvwxyz"
    /// A consonant (with its h) and a Latin letter in front of it; only the end of the word may follow.
    private static let finalSchwa = try? NSRegularExpression(
        pattern: "(?<=[A-Za-z][\(consonants)])a(?=[^A-Za-z]*$)")
    /// The unwritten "a" in the middle of a word is not pronounced: kitanā -> kitna, tumase -> tumse, karake -> karke.
    private static let middleSchwa = try? NSRegularExpression(
        pattern: "([aeiouAEIOU][\(consonants)]{1,3})a([\(consonants)]{1,2})(?=(?:[AIUEOeiou]|ai|au)[^A-Za-z]*$)")

    /// Turns the system's careful Devanagari transliteration (kyā kara rahā) into the way Hindi is typed in
    /// English letters (kya kar raha).
    private static func hinglish(_ latin: String) -> String {
        var t = latin.lowercased().decomposedStringWithCanonicalMapping
        t = t.replacingOccurrences(of: "jn\u{0303}", with: "gy")
        let swaps: [(String, String)] = [
            ("m\u{0307}", "n"), ("m\u{0323}", "n"), ("m\u{0310}", "n"), ("m\u{0303}", "n"),   // anusvara, chandrabindu
            ("n\u{0307}", "n"), ("n\u{0303}", "n"), ("n\u{0323}", "n"),
            ("s\u{0301}", "sh"), ("s\u{0323}", "sh"),
            ("t\u{0323}", "t"), ("d\u{0323}", "d"), ("l\u{0323}", "l"),
            ("r\u{0323}", "r"), ("r\u{0325}", "ri")
        ]
        for (from, to) in swaps { t = t.replacingOccurrences(of: from, with: to) }
        // Long vowels become capitals for a moment, so they cannot be mistaken for the silent short "a".
        for vowel in ["a", "i", "u", "e", "o"] {
            t = t.replacingOccurrences(of: vowel + "\u{0304}", with: vowel.uppercased())
        }
        // च is "ch" and छ is "chh" in everyday spelling (the system writes them c and ch).
        t = t.replacingOccurrences(of: "ch", with: "\u{1}")
            .replacingOccurrences(of: "c", with: "ch")
            .replacingOccurrences(of: "\u{1}", with: "chh")
        if let finalSchwa {
            t = finalSchwa.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        if let middleSchwa {
            t = middleSchwa.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1$2")
        }
        return t.lowercased()
    }
}
