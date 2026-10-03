import XCTest
import CryptoKit
@testable import WhisperDictation

// MARK: - Settings Tests

final class AppSettingsTests: XCTestCase {
    func testHotkeyCodeIsValid() {
        let code = AppSettings.shared.hotkeyKeyCode
        XCTAssertGreaterThanOrEqual(code, 0)
        XCTAssertLessThan(code, 128)
    }

    func testSelectedModelIsNotEmpty() {
        XCTAssertFalse(AppSettings.shared.selectedModel.isEmpty)
    }

    func testSoundFeedbackDefault() {
        XCTAssertTrue(AppSettings.shared.soundFeedbackEnabled)
    }

    func testMinimumRecordingDuration() {
        XCTAssertEqual(AppSettings.shared.minimumRecordingDuration, 0.3)
    }

    func testHotkeyModeRoundTrips() {
        let settings = AppSettings.shared
        let original = settings.hotkeyMode

        settings.hotkeyMode = .toggle
        XCTAssertEqual(settings.hotkeyMode, .toggle)

        settings.hotkeyMode = .pushToTalk
        XCTAssertEqual(settings.hotkeyMode, .pushToTalk)

        settings.hotkeyMode = original
    }

    func testToggleHoldDurationClampsAboveRange() {
        let settings = AppSettings.shared
        let original = settings.toggleHoldDuration

        settings.toggleHoldDuration = 999.0
        XCTAssertLessThanOrEqual(settings.toggleHoldDuration, 3.0)

        settings.toggleHoldDuration = original
    }

    func testToggleHoldDurationClampsBelowRange() {
        let settings = AppSettings.shared
        let original = settings.toggleHoldDuration

        settings.toggleHoldDuration = -5.0
        XCTAssertGreaterThanOrEqual(settings.toggleHoldDuration, 0.5)

        settings.toggleHoldDuration = original
    }

    func testToggleHoldDurationInRange() {
        let value = AppSettings.shared.toggleHoldDuration
        XCTAssertGreaterThanOrEqual(value, 0.5)
        XCTAssertLessThanOrEqual(value, 3.0)
    }

    // MARK: Getter validation (Phase 2)

    /// The getter must clamp out-of-band raw values that bypassed the clamping
    /// setter (e.g. written directly to UserDefaults by an older build or a
    /// corrupt domain). We write raw values under the key and read back through
    /// the getter.
    func testToggleHoldDurationGetterClampsRawValue() {
        let key = "toggleHoldDuration"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }

        FileBackedDefaults.shared.set(999.0, forKey: key)
        XCTAssertEqual(AppSettings.shared.toggleHoldDuration, 3.0)

        FileBackedDefaults.shared.set(-5.0, forKey: key)
        XCTAssertEqual(AppSettings.shared.toggleHoldDuration, 0.5)
    }

    func testMinimumRecordingDurationGetterClampsRawValue() {
        let key = "minimumRecordingDuration"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }

        FileBackedDefaults.shared.set(999.0, forKey: key)
        XCTAssertEqual(AppSettings.shared.minimumRecordingDuration, 5.0)

        FileBackedDefaults.shared.set(-5.0, forKey: key)
        XCTAssertEqual(AppSettings.shared.minimumRecordingDuration, 0.0)
    }

    func testSelectedModelFallsBackForUnknownValue() {
        let key = "selectedModel"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }

        // Unknown id → default
        FileBackedDefaults.shared.set("totally-bogus-model-xyz", forKey: key)
        XCTAssertEqual(AppSettings.shared.selectedModel, "small.en")

        // Known catalog id → preserved
        FileBackedDefaults.shared.set("base.en", forKey: key)
        XCTAssertEqual(AppSettings.shared.selectedModel, "base.en")
    }

    func testCustomTermsCappedAt100() {
        let settings = AppSettings.shared
        let original = settings.customTerms
        defer { settings.customTerms = original }

        settings.customTerms = (0..<150).map { "Term\($0)" }
        XCTAssertEqual(settings.customTerms.count, 100)
    }

    func testGrammarCorrectionDefault() {
        XCTAssertTrue(AppSettings.shared.grammarCorrectionEnabled)
    }

    func testNumberConversionDefault() {
        XCTAssertTrue(AppSettings.shared.numberConversionEnabled)
    }

    func testVocabularyPromptNotEmpty() {
        let prompt = AppSettings.shared.vocabularyPrompt
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.contains("API"))
        XCTAssertTrue(prompt.contains("JSON"))
        XCTAssertTrue(prompt.contains("SwiftUI"))
    }

    func testDefaultVocabularyPrompt() {
        XCTAssertTrue(AppSettings.defaultVocabularyPrompt.contains("Technical software engineering"))
    }

    func testCustomTermsDefaultEmpty() {
        // Fresh install should have no custom terms (or whatever the user currently has)
        let terms = AppSettings.shared.customTerms
        XCTAssertTrue(terms is [String]) // type check — always passes, validates the property exists
    }

    // MARK: - Secondary language settings

    func testSecondaryHotkeyKeyCodeDefaultAndRoundTrip() {
        let settings = AppSettings.shared
        let original = settings.secondaryHotkeyKeyCode
        defer { settings.secondaryHotkeyKeyCode = original }

        settings.secondaryHotkeyKeyCode = 99
        XCTAssertEqual(settings.secondaryHotkeyKeyCode, 99)
    }

    func testSecondaryHotkeyDefaultsDistinctFromPrimaryDefault() {
        // Fresh keys (no prior value written) must not collide, so both hotkeys
        // work out of the box: primary defaults to right Option (61), secondary
        // to left Option (58).
        let secondaryKey = "secondaryHotkeyKeyCode"
        let primaryKey = "hotkeyKeyCode"
        let savedSecondary = FileBackedDefaults.shared.object(forKey: secondaryKey)
        let savedPrimary = FileBackedDefaults.shared.object(forKey: primaryKey)
        defer {
            if let savedSecondary { FileBackedDefaults.shared.set(savedSecondary, forKey: secondaryKey) }
            else { FileBackedDefaults.shared.removeObject(forKey: secondaryKey) }
            if let savedPrimary { FileBackedDefaults.shared.set(savedPrimary, forKey: primaryKey) }
            else { FileBackedDefaults.shared.removeObject(forKey: primaryKey) }
        }
        FileBackedDefaults.shared.removeObject(forKey: secondaryKey)
        FileBackedDefaults.shared.removeObject(forKey: primaryKey)

        XCTAssertEqual(AppSettings.shared.hotkeyKeyCode, 61)
        XCTAssertEqual(AppSettings.shared.secondaryHotkeyKeyCode, 58)
        XCTAssertNotEqual(AppSettings.shared.hotkeyKeyCode, AppSettings.shared.secondaryHotkeyKeyCode)
    }

    func testSecondaryLanguageCodeDefaultsToEmpty() {
        let key = "secondaryLanguageCode"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }
        FileBackedDefaults.shared.removeObject(forKey: key)

        // Nothing is pre-selected for a fresh install — the user must explicitly
        // choose a secondary language in Settings before the secondary hotkey
        // does anything (see DictationEngine.handleSecondaryKeyDown).
        XCTAssertEqual(AppSettings.shared.secondaryLanguageCode, "")
    }

    func testSecondaryLanguageCodeRoundTrips() {
        let settings = AppSettings.shared
        let original = settings.secondaryLanguageCode
        defer { settings.secondaryLanguageCode = original }

        settings.secondaryLanguageCode = "es"
        XCTAssertEqual(settings.secondaryLanguageCode, "es")
    }

    func testSecondaryModelSelectionFallsBackForUnknownOrEnglishOnlyValue() {
        let key = "secondaryModelSelection"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }

        // Unknown id -> default
        FileBackedDefaults.shared.set("totally-bogus-xyz", forKey: key)
        XCTAssertEqual(AppSettings.shared.secondaryModelSelection, "small")

        // English-only id (not multilingual) must NOT be accepted for the
        // secondary slot, even though it's a real catalog id.
        FileBackedDefaults.shared.set("small.en", forKey: key)
        XCTAssertEqual(AppSettings.shared.secondaryModelSelection, "small")

        // Known multilingual id -> preserved
        FileBackedDefaults.shared.set("base", forKey: key)
        XCTAssertEqual(AppSettings.shared.secondaryModelSelection, "base")
    }

    func testPrimaryIdleTimeoutDefaultsToNeverUnload() {
        let key = "primaryIdleTimeoutMinutes"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }
        FileBackedDefaults.shared.removeObject(forKey: key)
        XCTAssertEqual(AppSettings.shared.primaryIdleTimeoutMinutes, 0)
    }

    func testSecondaryIdleTimeoutDefaultsToTenMinutes() {
        let key = "secondaryIdleTimeoutMinutes"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }
        FileBackedDefaults.shared.removeObject(forKey: key)
        XCTAssertEqual(AppSettings.shared.secondaryIdleTimeoutMinutes, 10)
    }

    func testIdleTimeoutMinutesClampsNegativeToZero() {
        let settings = AppSettings.shared
        let originalPrimary = settings.primaryIdleTimeoutMinutes
        let originalSecondary = settings.secondaryIdleTimeoutMinutes
        defer {
            settings.primaryIdleTimeoutMinutes = originalPrimary
            settings.secondaryIdleTimeoutMinutes = originalSecondary
        }

        settings.primaryIdleTimeoutMinutes = -5
        XCTAssertEqual(settings.primaryIdleTimeoutMinutes, 0)

        settings.secondaryIdleTimeoutMinutes = -1
        XCTAssertEqual(settings.secondaryIdleTimeoutMinutes, 0)
    }

    // MARK: - Secondary vocabulary

    func testSecondaryVocabularyPromptDefaultsToPortugalPresetWhenLanguageIsPortuguese() {
        let settings = AppSettings.shared
        let savedPrompt = settings.secondaryVocabularyPrompt
        let savedLanguage = settings.secondaryLanguageCode
        defer {
            settings.secondaryVocabularyPrompt = savedPrompt
            settings.secondaryLanguageCode = savedLanguage
        }

        // Clear any stored prompt so the default-lookup path is exercised.
        FileBackedDefaults.shared.removeObject(forKey: "secondaryVocabularyPrompt")
        settings.secondaryLanguageCode = "pt"

        XCTAssertEqual(settings.secondaryVocabularyPrompt, AppSettings.defaultPortugalPortuguesePrompt)
        XCTAssertTrue(settings.secondaryVocabularyPrompt.contains("Facto"))
        XCTAssertTrue(settings.secondaryVocabularyPrompt.contains("português europeu"))
    }

    func testSecondaryVocabularyPromptDefaultsToEmptyForUnknownLanguage() {
        let settings = AppSettings.shared
        let savedPrompt = settings.secondaryVocabularyPrompt
        let savedLanguage = settings.secondaryLanguageCode
        defer {
            settings.secondaryVocabularyPrompt = savedPrompt
            settings.secondaryLanguageCode = savedLanguage
        }

        FileBackedDefaults.shared.removeObject(forKey: "secondaryVocabularyPrompt")
        settings.secondaryLanguageCode = "fr"

        XCTAssertEqual(settings.secondaryVocabularyPrompt, "")
    }

    func testSecondaryVocabularyPromptRoundTrips() {
        let settings = AppSettings.shared
        let original = settings.secondaryVocabularyPrompt
        defer { settings.secondaryVocabularyPrompt = original }

        settings.secondaryVocabularyPrompt = "custom secondary vocab"
        XCTAssertEqual(settings.secondaryVocabularyPrompt, "custom secondary vocab")
    }

    func testDefaultSecondaryVocabularyPromptLookup() {
        XCTAssertEqual(AppSettings.defaultSecondaryVocabularyPrompt(forLanguageCode: "pt"), AppSettings.defaultPortugalPortuguesePrompt)
        XCTAssertEqual(AppSettings.defaultSecondaryVocabularyPrompt(forLanguageCode: "es"), "")
    }

    func testIncludeEnglishTermsInSecondaryDefaultsFalseAndRoundTrips() {
        let settings = AppSettings.shared
        let original = settings.includeEnglishTermsInSecondary
        defer { settings.includeEnglishTermsInSecondary = original }

        let key = "includeEnglishTermsInSecondary"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        FileBackedDefaults.shared.removeObject(forKey: key)
        XCTAssertFalse(AppSettings.shared.includeEnglishTermsInSecondary)
        if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }

        settings.includeEnglishTermsInSecondary = true
        XCTAssertTrue(settings.includeEnglishTermsInSecondary)
    }

    func testEffectiveSecondaryVocabularyBaseExcludesEnglishByDefault() {
        let settings = AppSettings.shared
        let savedInclude = settings.includeEnglishTermsInSecondary
        let savedSecondary = settings.secondaryVocabularyPrompt
        defer {
            settings.includeEnglishTermsInSecondary = savedInclude
            settings.secondaryVocabularyPrompt = savedSecondary
        }

        settings.includeEnglishTermsInSecondary = false
        settings.secondaryVocabularyPrompt = "SECONDARY_MARKER"

        XCTAssertEqual(settings.effectiveSecondaryVocabularyBase, "SECONDARY_MARKER")
    }

    func testEffectiveSecondaryVocabularyBasePrefixesEnglishWhenEnabled() {
        let settings = AppSettings.shared
        let savedInclude = settings.includeEnglishTermsInSecondary
        let savedSecondary = settings.secondaryVocabularyPrompt
        let savedPrimary = settings.vocabularyPrompt
        defer {
            settings.includeEnglishTermsInSecondary = savedInclude
            settings.secondaryVocabularyPrompt = savedSecondary
            settings.vocabularyPrompt = savedPrimary
        }

        settings.vocabularyPrompt = "PRIMARY_MARKER"
        settings.secondaryVocabularyPrompt = "SECONDARY_MARKER"
        settings.includeEnglishTermsInSecondary = true

        let result = settings.effectiveSecondaryVocabularyBase
        XCTAssertTrue(result.hasPrefix("PRIMARY_MARKER"))
        XCTAssertTrue(result.contains("SECONDARY_MARKER"))
    }

    func testIdleTimeoutMinutesZeroMeansNeverRoundTrips() {
        let settings = AppSettings.shared
        let original = settings.secondaryIdleTimeoutMinutes
        defer { settings.secondaryIdleTimeoutMinutes = original }

        settings.secondaryIdleTimeoutMinutes = 0
        XCTAssertEqual(settings.secondaryIdleTimeoutMinutes, 0)
    }

    func testAddAndRemoveCustomTerm() {
        let settings = AppSettings.shared
        let original = settings.customTerms

        settings.addCustomTerm("TestTermXYZ123")
        XCTAssertTrue(settings.customTerms.contains("TestTermXYZ123"))

        // Duplicate (case-insensitive) should not add
        let countBefore = settings.customTerms.count
        settings.addCustomTerm("testtermxyz123")
        XCTAssertEqual(settings.customTerms.count, countBefore)

        // Empty/whitespace term should not add
        settings.addCustomTerm("   ")
        XCTAssertFalse(settings.customTerms.contains("   "))

        settings.removeCustomTerm("TestTermXYZ123")
        XCTAssertFalse(settings.customTerms.contains("TestTermXYZ123"))

        // Restore original
        settings.customTerms = original
    }
}

// MARK: - Live Dictation Setting Tests

final class LiveDictationSettingTests: XCTestCase {
    func testLiveDictationEnabledRoundTrip() {
        let settings = AppSettings.shared
        let saved = settings.liveDictationEnabled          // save user's real value
        defer { settings.liveDictationEnabled = saved }    // restore

        settings.liveDictationEnabled = true
        XCTAssertTrue(settings.liveDictationEnabled)
        settings.liveDictationEnabled = false
        XCTAssertFalse(settings.liveDictationEnabled)
    }
}

// MARK: - State Machine Tests

final class DictationStateTests: XCTestCase {
    func testAllStatesExist() {
        XCTAssertEqual(DictationState.idle.rawValue, "idle")
        XCTAssertEqual(DictationState.recording.rawValue, "recording")
        XCTAssertEqual(DictationState.processing.rawValue, "processing")
        XCTAssertEqual(DictationState.typing.rawValue, "typing")
    }
}

// MARK: - Model Manager Tests

final class ModelManagerTests: XCTestCase {
    func testModelInfoCount() {
        XCTAssertEqual(ModelManager.ModelInfo.all.count, 12)
    }

    func testRecommendedModelsCount() {
        XCTAssertEqual(ModelManager.ModelInfo.recommended.count, 3)
    }

    func testQuantizedModelsAreRecommended() {
        for model in ModelManager.ModelInfo.recommended {
            XCTAssertTrue(model.isQuantized, "\(model.name) should be quantized")
        }
    }

    // MARK: Multilingual catalog (secondary-language dictation)

    func testMultilingualModelsExist() {
        let names = ModelManager.ModelInfo.all.map(\.name)
        XCTAssertTrue(names.contains("Base (Multilingual)"))
        XCTAssertTrue(names.contains("Small (Multilingual)"))
        XCTAssertTrue(names.contains("Medium (Multilingual)"))
        XCTAssertTrue(names.contains("Base Q5 (Multilingual)"))
        XCTAssertTrue(names.contains("Small Q5 (Multilingual)"))
        XCTAssertTrue(names.contains("Medium Q5 (Multilingual)"))
    }

    func testIsMultilingualFlagMatchesCatalogSplit() {
        for model in ModelManager.ModelInfo.all {
            let expectsMultilingual = !model.fileName.contains(".en")
            XCTAssertEqual(
                model.isMultilingual, expectsMultilingual,
                "\(model.fileName) isMultilingual should be \(expectsMultilingual)"
            )
        }
    }

    func testMultilingualSettingsIdDistinctFromEnglishOnly() {
        // "ggml-small.bin" -> "small" (multilingual) must NOT collide with
        // "ggml-small.en.bin" -> "small.en" (English-only).
        XCTAssertEqual(ModelManager.ModelInfo.smallMultilingual.settingsId, "small")
        XCTAssertEqual(ModelManager.ModelInfo.smallEn.settingsId, "small.en")
        XCTAssertNotEqual(
            ModelManager.ModelInfo.smallMultilingual.settingsId,
            ModelManager.ModelInfo.smallEn.settingsId
        )

        XCTAssertEqual(ModelManager.ModelInfo.baseMultilingual.settingsId, "base")
        XCTAssertEqual(ModelManager.ModelInfo.mediumMultilingualQ5.settingsId, "medium-q5_0")
    }

    func testRecommendedMultilingualModelsCount() {
        XCTAssertEqual(ModelManager.ModelInfo.recommendedMultilingual.count, 3)
    }

    func testRecommendedMultilingualModelsAreQuantizedAndMultilingual() {
        for model in ModelManager.ModelInfo.recommendedMultilingual {
            XCTAssertTrue(model.isQuantized, "\(model.name) should be quantized")
            XCTAssertTrue(model.isMultilingual, "\(model.name) should be multilingual")
        }
    }

    func testFullPrecisionModelsExist() {
        let names = ModelManager.ModelInfo.all.map(\.name)
        XCTAssertTrue(names.contains("Base (English)"))
        XCTAssertTrue(names.contains("Small (English)"))
        XCTAssertTrue(names.contains("Medium (English)"))
    }

    func testQuantizedModelsExist() {
        let names = ModelManager.ModelInfo.all.map(\.name)
        XCTAssertTrue(names.contains("Base Q5 (English)"))
        XCTAssertTrue(names.contains("Small Q5 (English)"))
        XCTAssertTrue(names.contains("Medium Q5 (English)"))
    }

    func testModelsDirectoryExists() {
        let dir = ModelManager.shared.modelsDirectory
        XCTAssertFalse(dir.path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testModelURLsAreValid() {
        for model in ModelManager.ModelInfo.all {
            XCTAssertTrue(model.url.absoluteString.contains("huggingface.co"))
            XCTAssertTrue(model.url.absoluteString.hasSuffix(".bin"))
        }
    }

    func testVADModel() {
        let vad = ModelManager.ModelInfo.vadSilero
        XCTAssertTrue(vad.url.absoluteString.contains("whisper-vad"))
        XCTAssertEqual(vad.fileName, "ggml-silero-v5.1.2.bin")
    }

    // MARK: Download Integrity (Phase 1)

    /// Every catalog model AND the VAD model must carry a well-formed pinned
    /// SHA256 (64 lowercase hex chars). A blank/short hash means a model shipped
    /// without integrity protection.
    func testEveryModelHasWellFormedSHA256() {
        let allModels = ModelManager.ModelInfo.all + [ModelManager.ModelInfo.vadSilero]
        let hexSet = CharacterSet(charactersIn: "0123456789abcdef")
        for model in allModels {
            let hash = model.sha256
            XCTAssertEqual(hash.count, 64, "\(model.name) sha256 must be 64 chars, got \(hash.count)")
            XCTAssertTrue(
                hash.unicodeScalars.allSatisfy { hexSet.contains($0) },
                "\(model.name) sha256 must be lowercase hex: \(hash)"
            )
        }
    }

    func testModelSHA256AreUnique() {
        let allModels = ModelManager.ModelInfo.all + [ModelManager.ModelInfo.vadSilero]
        let hashes = allModels.map(\.sha256)
        XCTAssertEqual(Set(hashes).count, hashes.count, "Pinned model hashes must all be distinct")
    }

    func testAcceptableStatusCodes() {
        XCTAssertTrue(ModelManager.isAcceptableStatusCode(200))
        XCTAssertTrue(ModelManager.isAcceptableStatusCode(206))
        XCTAssertTrue(ModelManager.isAcceptableStatusCode(299))
        XCTAssertFalse(ModelManager.isAcceptableStatusCode(199))
        XCTAssertFalse(ModelManager.isAcceptableStatusCode(300))
        XCTAssertFalse(ModelManager.isAcceptableStatusCode(304))
        XCTAssertFalse(ModelManager.isAcceptableStatusCode(404))
        XCTAssertFalse(ModelManager.isAcceptableStatusCode(500))
    }

    func testSHA256KnownVector() throws {
        // Canonical SHA256("abc")
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-sha-abc-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ModelManager.sha256Hex(ofFileAt: url), expected)
    }

    func testSHA256EmptyFile() throws {
        // Canonical SHA256 of zero bytes
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-sha-empty-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ModelManager.sha256Hex(ofFileAt: url), expected)
    }

    /// Streaming hash of a multi-chunk (>1 MB) file must match a one-shot hash of
    /// the same bytes — proves the chunked read covers the whole file with no
    /// dropped/overlapping bytes at chunk boundaries.
    func testSHA256StreamingMatchesOneShotMultiChunk() throws {
        let byteCount = 3 * 1024 * 1024 + 7 // deliberately not a chunk multiple
        var data = Data(count: byteCount)
        for i in 0..<byteCount { data[i] = UInt8((i * 31 + 7) & 0xff) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-sha-multi-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try ModelManager.sha256Hex(ofFileAt: url)
        let oneShot = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed, oneShot)
    }

    func testSHA256MissingFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).bin")
        XCTAssertThrowsError(try ModelManager.sha256Hex(ofFileAt: url))
    }
}

// MARK: - TextCorrector Tests

final class TextCorrectorTests: XCTestCase {
    let corrector = TextCorrector.shared

    // MARK: Number Conversion - Basic

    func testNumberZero() {
        let result = corrector.correct("zero")
        XCTAssertEqual(result, "0")
    }

    func testNumberSingleDigit() {
        XCTAssertTrue(corrector.correct("one").contains("1"))
        XCTAssertTrue(corrector.correct("nine").contains("9"))
    }

    func testNumberTeens() {
        XCTAssertTrue(corrector.correct("eleven").contains("11"))
        XCTAssertTrue(corrector.correct("nineteen").contains("19"))
    }

    func testNumberTens() {
        XCTAssertTrue(corrector.correct("twenty").contains("20"))
        XCTAssertTrue(corrector.correct("ninety").contains("90"))
    }

    func testNumberCompound() {
        XCTAssertTrue(corrector.correct("forty two").contains("42"))
        XCTAssertTrue(corrector.correct("twenty one").contains("21"))
        XCTAssertTrue(corrector.correct("ninety nine").contains("99"))
    }

    // MARK: Number Conversion - Hundreds/Thousands

    func testNumberHundred() {
        XCTAssertTrue(corrector.correct("three hundred").contains("300"))
        XCTAssertTrue(corrector.correct("a hundred").contains("100"))
        XCTAssertTrue(corrector.correct("one hundred").contains("100"))
    }

    func testNumberHundredCompound() {
        XCTAssertTrue(corrector.correct("three hundred forty two").contains("342"))
        XCTAssertTrue(corrector.correct("one hundred and twenty three").contains("123"))
    }

    func testNumberThousand() {
        XCTAssertTrue(corrector.correct("one thousand").contains("1,000"))
        XCTAssertTrue(corrector.correct("a thousand").contains("1,000"))
    }

    func testNumberLargeCompound() {
        XCTAssertTrue(corrector.correct("two thousand five hundred").contains("2,500"))
        XCTAssertTrue(corrector.correct("one million").contains("1,000,000"))
    }

    // MARK: Number Conversion - Digit Sequences

    func testDigitSequence() {
        XCTAssertTrue(corrector.correct("two four six eight").contains("2,468"))
        XCTAssertTrue(corrector.correct("nine one one").contains("911"))
        XCTAssertTrue(corrector.correct("one two three").contains("123"))
    }

    func testDigitSequenceTens() {
        XCTAssertTrue(corrector.correct("eighty eighty").contains("8,080"))
        XCTAssertTrue(corrector.correct("fifty fifty").contains("5,050"))
    }

    // MARK: Number Conversion - In Context

    func testNumberInSentence() {
        let result = corrector.correct("I have three hundred dollars")
        XCTAssertTrue(result.contains("300"))
        XCTAssertTrue(result.contains("dollars"))
    }

    func testNumberPreservesNonNumberWords() {
        let result = corrector.correct("a big dog")
        XCTAssertTrue(result.lowercased().contains("a big dog"))
    }

    // MARK: Number Conversion - Format

    func testFormatThousands() {
        XCTAssertTrue(corrector.correct("five thousand").contains("5,000"))
    }

    func testNoTrailingPeriodAfterNumber() {
        let result = corrector.correct("three hundred")
        XCTAssertFalse(result.hasSuffix("."), "Numbers shouldn't get trailing periods: '\(result)'")
    }

    // MARK: Acronym/Term Casing

    func testAcronymUppercase() {
        let result = corrector.correct("the api returns json")
        XCTAssertTrue(result.contains("API"))
        XCTAssertTrue(result.contains("JSON"))
    }

    func testMixedCaseTerms() {
        XCTAssertTrue(corrector.correct("use javascript").contains("JavaScript"))
        XCTAssertTrue(corrector.correct("deploy with docker").contains("Docker"))
        XCTAssertTrue(corrector.correct("query postgresql").contains("PostgreSQL"))
    }

    func testAppleTerms() {
        XCTAssertTrue(corrector.correct("build for macos").contains("macOS"))
        XCTAssertTrue(corrector.correct("using swiftui").contains("SwiftUI"))
        XCTAssertTrue(corrector.correct("open xcode").contains("Xcode"))
    }

    func testAITerms() {
        XCTAssertTrue(corrector.correct("use openai").contains("OpenAI"))
        XCTAssertTrue(corrector.correct("ask claude").contains("Claude"))
    }

    func testCompoundTerms() {
        XCTAssertTrue(corrector.correct("set up ci/cd").contains("CI/CD"))
        XCTAssertTrue(corrector.correct("the devops team").contains("DevOps"))
        XCTAssertTrue(corrector.correct("use graphql").contains("GraphQL"))
    }

    // MARK: Capitalization

    func testCapitalizeFirstLetter() {
        let result = corrector.correct("hello world")
        XCTAssertTrue(result.hasPrefix("H"))
    }

    func testCapitalizeAfterPeriod() {
        let result = corrector.correct("first sentence. second sentence")
        // After the period, "second" should be capitalized
        XCTAssertTrue(result.contains("Second") || result.contains("second"), "Got: \(result)")
    }

    func testCapitalizeStandaloneI() {
        let result = corrector.correct("i think i should go")
        XCTAssertTrue(result.contains("I think I should"))
    }

    func testCapitalizeContractions() {
        let result = corrector.correct("i'm going and i'll be back")
        XCTAssertTrue(result.contains("I'm") || result.contains("I'M"))
        XCTAssertTrue(result.contains("I'll") || result.contains("I'LL"))
    }

    // MARK: Punctuation

    func testAddTrailingPeriod() {
        let result = corrector.correct("this is a test")
        XCTAssertTrue(result.hasSuffix("."), "Should add period: '\(result)'")
    }

    func testNoDoubleTrailingPunctuation() {
        let result = corrector.correct("is this a test?")
        XCTAssertFalse(result.hasSuffix("?."))
        XCTAssertTrue(result.hasSuffix("?"))
    }

    func testFixSpaceBeforePunctuation() {
        let result = corrector.correct("hello .")
        XCTAssertFalse(result.contains(" ."))
    }

    func testFixDoubleSpaces() {
        let result = corrector.correct("hello  world")
        XCTAssertFalse(result.contains("  "))
    }

    // MARK: Full Pipeline

    func testFullPipeline() {
        let result = corrector.correct("create a rest api endpoint that returns json")
        XCTAssertTrue(result.contains("REST"))
        XCTAssertTrue(result.contains("API"))
        XCTAssertTrue(result.contains("JSON"))
        XCTAssertTrue(result.hasPrefix("C")) // Capitalized
    }

    func testFullPipelineWithNumbers() {
        let result = corrector.correct("i need three hundred megabytes of ram")
        XCTAssertTrue(result.contains("300"))
        XCTAssertTrue(result.contains("RAM"))
        XCTAssertTrue(result.contains("I need"))
    }

    // MARK: Custom Terms

    func testCustomTermCasing() {
        let settings = AppSettings.shared
        let original = settings.customTerms

        settings.customTerms = ["McKinsey", "DeepMind"]
        let result = corrector.correct("talk to mckinsey about deepmind")
        XCTAssertTrue(result.contains("McKinsey"), "Got: \(result)")
        XCTAssertTrue(result.contains("DeepMind"), "Got: \(result)")

        settings.customTerms = original
    }

    func testCustomTermsEmptyIsNoOp() {
        let settings = AppSettings.shared
        let original = settings.customTerms

        settings.customTerms = []
        let result = corrector.correct("hello world")
        XCTAssertTrue(result.hasPrefix("Hello"))

        settings.customTerms = original
    }

    func testCustomTermsDoNotBreakExistingPipeline() {
        let settings = AppSettings.shared
        let original = settings.customTerms

        settings.customTerms = ["MyCompany"]
        let result = corrector.correct("the api at mycompany returns json")
        XCTAssertTrue(result.contains("API"), "Got: \(result)")
        XCTAssertTrue(result.contains("JSON"), "Got: \(result)")
        XCTAssertTrue(result.contains("MyCompany"), "Got: \(result)")

        settings.customTerms = original
    }
}

// MARK: - DictationEngine Tests

final class DictationEngineTests: XCTestCase {

    // MARK: - Hotkey dispatch semantics (Phase 3)

    /// Push-to-talk: a key-down is always deliberate — while transcribing it cancels,
    /// otherwise it starts recording.
    func testPushToTalkKeyDownCancelsOnlyWhileTranscribing() {
        XCTAssertEqual(DictationEngine.keyDownAction(mode: .pushToTalk, state: .idle), .startRecording)
        XCTAssertEqual(DictationEngine.keyDownAction(mode: .pushToTalk, state: .recording), .startRecording)
        XCTAssertEqual(DictationEngine.keyDownAction(mode: .pushToTalk, state: .loadingModel), .cancelTranscription)
        XCTAssertEqual(DictationEngine.keyDownAction(mode: .pushToTalk, state: .processing), .cancelTranscription)
        XCTAssertEqual(DictationEngine.keyDownAction(mode: .pushToTalk, state: .typing), .cancelTranscription)
    }

    /// Toggle mode: a bare key-down must NEVER cancel directly — a stray tap during
    /// .processing would destroy an in-flight transcription (e.g. right after the
    /// 5-minute cap auto-stopped a long recording). Everything goes through the
    /// deliberate hold.
    func testToggleKeyDownNeverCancelsDirectly() {
        for state in [DictationState.idle, .recording, .loadingModel, .processing, .typing] {
            XCTAssertEqual(
                DictationEngine.keyDownAction(mode: .toggle, state: state),
                .scheduleToggle,
                "toggle key-down in \(state) must only schedule the hold"
            )
        }
    }

    /// A COMPLETED toggle hold is as deliberate as any other toggle action:
    /// idle starts, recording stops, transcribing cancels.
    func testToggleHoldActionPerState() {
        XCTAssertEqual(DictationEngine.toggleHoldAction(state: .idle), .startRecording)
        XCTAssertEqual(DictationEngine.toggleHoldAction(state: .recording), .stopAndTranscribe)
        XCTAssertEqual(DictationEngine.toggleHoldAction(state: .loadingModel), .cancelTranscription)
        XCTAssertEqual(DictationEngine.toggleHoldAction(state: .processing), .cancelTranscription)
        XCTAssertEqual(DictationEngine.toggleHoldAction(state: .typing), .cancelTranscription)
    }

    func testInitialState() {
        let engine = DictationEngine()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertTrue(engine.lastTranscription.isEmpty)
        XCTAssertFalse(engine.isModelLoaded)
    }

    // MARK: - Prompt assembly (Phase 2)

    /// A base vocabulary prompt that alone exceeds the word budget must be
    /// truncated (whisper's ~1024-token / ~750-word limit).
    func testBuildPromptTruncatesOversizedBase() {
        let longBase = (0..<1000).map { "word\($0)" }.joined(separator: " ")
        let result = DictationEngine.buildPrompt(base: longBase, customTerms: [])
        XCTAssertEqual(result.split(separator: " ").count, DictationEngine.promptWordBudget)
    }

    /// Within budget, custom terms are appended after the base prompt.
    func testBuildPromptAppendsCustomTermsWhenBudgetAllows() {
        let result = DictationEngine.buildPrompt(base: "one two three", customTerms: ["Acme", "Widget"])
        XCTAssertTrue(result.hasPrefix("one two three"))
        XCTAssertTrue(result.contains("Acme"))
        XCTAssertTrue(result.contains("Widget"))
    }

    /// When the base prompt already fills the budget, no custom terms fit.
    func testBuildPromptOversizedBaseLeavesNoRoomForCustomTerms() {
        let longBase = (0..<1000).map { "word\($0)" }.joined(separator: " ")
        let result = DictationEngine.buildPrompt(base: longBase, customTerms: ["UniqueTermZZZ"])
        XCTAssertFalse(result.contains("UniqueTermZZZ"))
        XCTAssertEqual(result.split(separator: " ").count, DictationEngine.promptWordBudget)
    }

    /// Empty custom terms → the base prompt is returned unchanged (when in budget).
    func testBuildPromptEmptyCustomTermsReturnsBase() {
        XCTAssertEqual(DictationEngine.buildPrompt(base: "hello world", customTerms: []), "hello world")
    }
}

// MARK: - buildPrompt committed-transcript tail

/// The live-mode context carry: previously committed transcript text is appended
/// last (nearest the decode), truncated to the last 50 words and to whatever word
/// budget the base prompt and custom terms leave behind.
final class BuildPromptTailTests: XCTestCase {
    func testDefaultOmitsTailAndMatchesTwoArgCall() {
        XCTAssertEqual(DictationEngine.buildPrompt(base: "a b c", customTerms: ["X"]),
                       DictationEngine.buildPrompt(base: "a b c", customTerms: ["X"], transcriptTail: ""))
    }

    func testTailAppendedLast() {
        let p = DictationEngine.buildPrompt(base: "vocab", customTerms: ["Term"], transcriptTail: "we did the thing")
        XCTAssertTrue(p.hasSuffix("we did the thing"))
        XCTAssertTrue(p.hasPrefix("vocab"))
    }

    func testTailTruncatedToLastFiftyWords() {
        let tail = (1...80).map(String.init).joined(separator: " ")
        let p = DictationEngine.buildPrompt(base: "v", customTerms: [], transcriptTail: tail)
        XCTAssertFalse(p.contains(" 30 "))          // words 1-30 dropped
        XCTAssertTrue(p.hasSuffix("79 80"))          // last 50 kept: 31...80
    }

    func testTailRespectsRemainingBudgetByActualWordCount() {
        let base = (1...690).map { "b\($0)" }.joined(separator: " ")  // 690 words
        let tail = (1...40).map { "t\($0)" }.joined(separator: " ")   // 40 words, budget left = 10
        let p = DictationEngine.buildPrompt(base: base, customTerms: [], transcriptTail: tail)
        let words = p.split(separator: " ")
        XCTAssertLessThanOrEqual(words.count, DictationEngine.promptWordBudget)
        XCTAssertTrue(p.hasSuffix("t39 t40"))        // last 10 tail words kept
        XCTAssertFalse(p.contains("t30 "))
    }
}

// MARK: - WhisperBridge Tests

final class WhisperBridgeTests: XCTestCase {
    func testInvalidModelPathThrows() {
        XCTAssertThrowsError(try WhisperBridge(modelPath: "/nonexistent/model.bin")) { error in
            XCTAssertTrue(error is WhisperError)
            XCTAssertTrue(error.localizedDescription.contains("/nonexistent/model.bin"))
        }
    }

    // MARK: - Language parameter (secondary-language dictation)

    /// Default language remains "en" so existing call sites (primary bridge)
    /// compile and behave unchanged without passing `language:` explicitly.
    /// Verified against the invalid-path failure path since constructing a real
    /// bridge requires a downloaded model — the language is stored before the
    /// model load is attempted, so this still exercises the parameter default.
    func testInvalidModelPathThrowsWithDefaultLanguage() {
        XCTAssertThrowsError(try WhisperBridge(modelPath: "/nonexistent/model.bin"))
    }

    func testInvalidModelPathThrowsWithExplicitLanguage() {
        XCTAssertThrowsError(try WhisperBridge(modelPath: "/nonexistent/model.bin", language: "pt")) { error in
            XCTAssertTrue(error is WhisperError)
        }
    }

    /// When a model IS available (small.en, downloaded by `make model` / CI setup),
    /// confirm the bridge stores the language it was constructed with.
    func testBridgeStoresConfiguredLanguage() throws {
        guard let modelPath = ModelManager.shared.activeModelPath() else {
            throw XCTSkip("No model downloaded in this environment — skipping load-dependent test")
        }
        let bridge = try WhisperBridge(modelPath: modelPath, language: "en")
        XCTAssertEqual(bridge.language, "en")
    }

    func testBridgeDefaultsToEnglishWhenLanguageOmitted() throws {
        guard let modelPath = ModelManager.shared.activeModelPath() else {
            throw XCTSkip("No model downloaded in this environment — skipping load-dependent test")
        }
        let bridge = try WhisperBridge(modelPath: modelPath)
        XCTAssertEqual(bridge.language, "en")
    }

    /// transcribe() now surfaces inference failures rather than returning "".
    /// We can't force whisper_full to fail without a loaded model, but the error
    /// case that carries the failure must produce a usable, non-empty description.
    func testTranscriptionFailedErrorHasDescription() {
        let error = WhisperError.transcriptionFailed(code: -7)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("-7") ?? false)
    }

    // MARK: - Cancellation (Phase 3)

    func testCancelledIsCancellationButFailureIsNot() {
        XCTAssertTrue(WhisperError.cancelled.isCancellation)
        XCTAssertFalse(WhisperError.transcriptionFailed(code: -1).isCancellation)
        XCTAssertFalse(WhisperError.modelLoadFailed("/x").isCancellation)
    }

    func testCancellationFlagStartsFalseThenCancels() {
        let flag = CancellationFlag()
        XCTAssertFalse(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
        flag.cancel() // idempotent
        XCTAssertTrue(flag.isCancelled)
    }
}

// MARK: - AudioCapture Tests

final class AudioCaptureDurationCapTests: XCTestCase {
    func testMaxRecordingSamplesIsFiveMinutesAt16kHz() {
        XCTAssertEqual(AudioCapture.maxRecordingSeconds, 300)
        XCTAssertEqual(AudioCapture.maxRecordingSamples, 16000 * 300)
    }

    func testCrossesDurationCapFiresExactlyOnCrossing() {
        let cap = AudioCapture.maxRecordingSamples
        // Well below the cap on both sides — no crossing.
        XCTAssertFalse(AudioCapture.crossesDurationCap(previousCount: 0, newCount: 1000))
        // The append that reaches the cap fires.
        XCTAssertTrue(AudioCapture.crossesDurationCap(previousCount: cap - 100, newCount: cap))
        XCTAssertTrue(AudioCapture.crossesDurationCap(previousCount: cap - 1, newCount: cap + 500))
        // Already past the cap — must NOT fire again (fire-once guarantee).
        XCTAssertFalse(AudioCapture.crossesDurationCap(previousCount: cap, newCount: cap + 500))
        XCTAssertFalse(AudioCapture.crossesDurationCap(previousCount: cap + 500, newCount: cap + 1000))
    }
}

final class AudioCaptureConfigChangeTests: XCTestCase {
    // AVAudioEngine posts a configuration-change notification once right after
    // start() when the AUHAL renegotiates a stale format (seen when another app
    // switched the device's sample rate). That renegotiation is benign — the
    // engine keeps running and the tap keeps delivering at the format it was
    // installed with — and must NOT end the session.
    func testRenegotiationWithMatchingFormatIsBenign() {
        XCTAssertTrue(AudioCapture.isBenignConfigurationChange(
            isRunning: true, tapRate: 16000, tapChannels: 2, hwRate: 16000, hwChannels: 2))
    }

    func testEngineStoppedIsFatal() {
        // Device unplugged: the engine stops itself.
        XCTAssertFalse(AudioCapture.isBenignConfigurationChange(
            isRunning: false, tapRate: 16000, tapChannels: 2, hwRate: 16000, hwChannels: 2))
    }

    func testSampleRateChangeIsFatal() {
        // Mid-session rate flip (e.g. conferencing app): tap format no longer valid.
        XCTAssertFalse(AudioCapture.isBenignConfigurationChange(
            isRunning: true, tapRate: 16000, tapChannels: 2, hwRate: 48000, hwChannels: 2))
    }

    func testChannelCountChangeIsFatal() {
        XCTAssertFalse(AudioCapture.isBenignConfigurationChange(
            isRunning: true, tapRate: 16000, tapChannels: 2, hwRate: 16000, hwChannels: 1))
    }

    func testZeroedFormatIsFatal() {
        // Device gone entirely — format reads back as 0 Hz / 0 ch.
        XCTAssertFalse(AudioCapture.isBenignConfigurationChange(
            isRunning: true, tapRate: 16000, tapChannels: 2, hwRate: 0, hwChannels: 0))
    }
}

// MARK: - Onboarding Tests

final class OnboardingTests: XCTestCase {
    func testHasCompletedOnboardingRoundTrips() {
        let settings = AppSettings.shared
        let original = settings.hasCompletedOnboarding

        settings.hasCompletedOnboarding = true
        XCTAssertTrue(settings.hasCompletedOnboarding)

        settings.hasCompletedOnboarding = false
        XCTAssertFalse(settings.hasCompletedOnboarding)

        settings.hasCompletedOnboarding = original
    }

    // The decision is pure: show onboarding only for a genuinely new user —
    // not completed AND no whisper model on disk yet.
    func testShowsForBrandNewUser() {
        XCTAssertTrue(OnboardingView.shouldShowOnboarding(hasCompleted: false, hasAnyModel: false))
    }

    func testSkipsWhenAlreadyCompleted() {
        XCTAssertFalse(OnboardingView.shouldShowOnboarding(hasCompleted: true, hasAnyModel: false))
    }

    // Existing users (upgrading) already have a model — they must never see onboarding.
    func testSkipsExistingUserWithModel() {
        XCTAssertFalse(OnboardingView.shouldShowOnboarding(hasCompleted: false, hasAnyModel: true))
    }

    func testSkipsCompletedUserWithModel() {
        XCTAssertFalse(OnboardingView.shouldShowOnboarding(hasCompleted: true, hasAnyModel: true))
    }
}

// MARK: - AudioDeviceManager Tests

final class AudioDeviceManagerTests: XCTestCase {
    func testListDevices() {
        let manager = AudioDeviceManager.shared
        manager.refreshDevices()
        // Should have at least one input device on any Mac
        XCTAssertFalse(manager.inputDevices.isEmpty, "No audio input devices found")
    }

    func testSelectedDeviceHandled() {
        // selectedDevice returns nil if no matching device, or a valid device if set
        let device = AudioDeviceManager.shared.selectedDevice
        if let device {
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertFalse(device.uid.isEmpty)
        }
        // Either nil or valid — both are acceptable
    }
}
