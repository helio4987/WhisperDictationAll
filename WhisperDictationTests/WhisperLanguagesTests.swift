import XCTest
@testable import WhisperDictation

final class WhisperLanguagesTests: XCTestCase {

    func testSupportedListIsNonEmpty() {
        XCTAssertFalse(WhisperLanguages.supported.isEmpty)
    }

    func testSupportedCodesAreUnique() {
        let codes = WhisperLanguages.supported.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "language codes must be unique")
    }

    func testPortugueseIsSupported() {
        XCTAssertEqual(WhisperLanguages.language(forCode: "pt")?.displayName, "Portuguese")
    }

    // MARK: - Low-resource exclusion filter

    func testKnownLowResourceLanguagesAreExcluded() {
        // Sample of whisper.cpp's long-tail/high-WER codes that must NOT appear in
        // the filtered, "reliable" list surfaced to users.
        let excludedCodes = ["su", "jw", "haw", "ba", "ha", "ln", "tt", "as", "mg", "tl",
                              "bo", "my", "lb", "sa", "mt", "nn", "tk", "ps", "ht", "fo",
                              "uz", "lo", "yi", "am", "gu", "sd", "tg", "be", "ka", "oc",
                              "af", "so", "yo", "sn", "km", "si", "pa", "ur", "yue"]
        let supportedCodes = Set(WhisperLanguages.supported.map(\.code))
        for code in excludedCodes {
            XCTAssertFalse(supportedCodes.contains(code), "\(code) should be excluded as low-resource")
        }
    }

    func testEnglishIsPresentForCompleteness() {
        XCTAssertEqual(WhisperLanguages.language(forCode: "en")?.displayName, "English")
    }

    func testUnknownCodeReturnsNil() {
        XCTAssertNil(WhisperLanguages.language(forCode: "zz-not-a-real-code"))
    }

    // MARK: - Filter / autocomplete

    func testFilterEmptyQueryReturnsAll() {
        XCTAssertEqual(WhisperLanguages.filter(query: "").count, WhisperLanguages.supported.count)
        XCTAssertEqual(WhisperLanguages.filter(query: "   ").count, WhisperLanguages.supported.count)
    }

    func testFilterMatchesByDisplayNamePrefix() {
        let results = WhisperLanguages.filter(query: "port")
        XCTAssertTrue(results.contains { $0.code == "pt" })
    }

    func testFilterIsCaseInsensitive() {
        let lower = WhisperLanguages.filter(query: "portuguese")
        let upper = WhisperLanguages.filter(query: "PORTUGUESE")
        let mixed = WhisperLanguages.filter(query: "PorTugueSe")
        XCTAssertEqual(lower.map(\.code), upper.map(\.code))
        XCTAssertEqual(lower.map(\.code), mixed.map(\.code))
    }

    func testFilterMatchesByCode() {
        let results = WhisperLanguages.filter(query: "pt")
        XCTAssertTrue(results.contains { $0.displayName == "Portuguese" })
    }

    func testFilterNoMatchReturnsEmpty() {
        XCTAssertTrue(WhisperLanguages.filter(query: "zzzznotalanguage").isEmpty)
    }

    func testFilterSubstringMatchNotJustPrefix() {
        // "man" is a substring of "German" — substring matching, not prefix-only.
        let results = WhisperLanguages.filter(query: "man")
        XCTAssertTrue(results.contains { $0.code == "de" })
    }
}
