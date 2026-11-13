import XCTest
@testable import Indra

/// The same song reached through different players must give the same lyrics key.
final class LyricsMatchingTests: XCTestCase {
    func testNormalizedIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(LyricsStore.normalized("Beyoncé - Halo (Live)"), "beyonce halo live")
    }

    func testCleanedRemovesStreamingTags() {
        XCTAssertEqual(LyricsStore.cleaned("Halo (feat. Someone)"), "Halo")
        XCTAssertEqual(LyricsStore.cleaned("Halo - Remastered 2011"), "Halo")
        XCTAssertEqual(LyricsStore.cleaned("Halo"), "Halo")
    }

    func testPrimaryArtistTakesTheFirstName() {
        XCTAssertEqual(LyricsStore.primaryArtist("A & B"), "A")
        XCTAssertEqual(LyricsStore.primaryArtist("A, B"), "A")
        XCTAssertEqual(LyricsStore.primaryArtist("Solo"), "Solo")
    }

    func testTopicChannelsLoseTheirSuffix() {
        XCTAssertEqual(LyricsStore.plainArtist("Adele - Topic"), "Adele")
        XCTAssertEqual(LyricsStore.plainArtist("Adele"), "Adele")
    }

    func testSameSongSameKey() {
        let a = LyricsStore.lookupKey(title: "Halo (Remastered)", artist: "Beyoncé")
        let b = LyricsStore.lookupKey(title: "halo", artist: "Beyonce, Jay-Z")
        XCTAssertEqual(a, b)
    }
}
