import Foundation

/// Filtered catalog of Whisper-supported languages available for secondary-language
/// dictation.
///
/// Source of truth: whisper.cpp vendors a full ~99-language table (`g_lang` in
/// `whisper.cpp/src/whisper.cpp`) mapping ISO-ish codes to English display names,
/// e.g. `{ "pt", "portuguese" }`. That full table spans a huge accuracy range —
/// per independent benchmarking against Common Voice/FLEURS, word-error-rate climbs
/// steeply for languages with little Whisper training data (see
/// https://tools.miku.ac/blog/whisper-99-languages-tier-reality for the public
/// tier breakdown this filter follows).
///
/// `WhisperLanguages.supported` keeps only Tier 1-3 languages (roughly WER < 30% on
/// real audio) and excludes Tier 4 / long-tail languages (Pashto, Punjabi, Urdu,
/// Sinhala, Khmer, Burmese, Lao, Yoruba, Shona, Hausa, Sundanese, Javanese, and the
/// rest of whisper.cpp's low-resource entries) where transcription quality is
/// typically unusable without fine-tuning.
enum WhisperLanguages {
    struct Language: Identifiable, Equatable {
        /// Whisper language code, e.g. "pt". Passed straight to `WhisperBridge`.
        let code: String
        /// Human-readable display name, e.g. "Portuguese".
        let displayName: String

        var id: String { code }
    }

    /// Filtered, reliable subset — Tiers 1 through 3. Alphabetically sorted by
    /// display name for a stable, predictable dropdown/autocomplete order.
    static let supported: [Language] = [
        Language(code: "ar", displayName: "Arabic"),
        Language(code: "bn", displayName: "Bengali"),
        Language(code: "bg", displayName: "Bulgarian"),
        Language(code: "ca", displayName: "Catalan"),
        Language(code: "zh", displayName: "Chinese"),
        Language(code: "hr", displayName: "Croatian"),
        Language(code: "cs", displayName: "Czech"),
        Language(code: "da", displayName: "Danish"),
        Language(code: "nl", displayName: "Dutch"),
        Language(code: "en", displayName: "English"),
        Language(code: "et", displayName: "Estonian"),
        Language(code: "fi", displayName: "Finnish"),
        Language(code: "fr", displayName: "French"),
        Language(code: "de", displayName: "German"),
        Language(code: "el", displayName: "Greek"),
        Language(code: "he", displayName: "Hebrew"),
        Language(code: "hi", displayName: "Hindi"),
        Language(code: "hu", displayName: "Hungarian"),
        Language(code: "id", displayName: "Indonesian"),
        Language(code: "it", displayName: "Italian"),
        Language(code: "ja", displayName: "Japanese"),
        Language(code: "ko", displayName: "Korean"),
        Language(code: "lv", displayName: "Latvian"),
        Language(code: "lt", displayName: "Lithuanian"),
        Language(code: "mr", displayName: "Marathi"),
        Language(code: "no", displayName: "Norwegian"),
        Language(code: "fa", displayName: "Persian"),
        Language(code: "pl", displayName: "Polish"),
        Language(code: "pt", displayName: "Portuguese"),
        Language(code: "ro", displayName: "Romanian"),
        Language(code: "ru", displayName: "Russian"),
        Language(code: "sr", displayName: "Serbian"),
        Language(code: "sk", displayName: "Slovak"),
        Language(code: "sl", displayName: "Slovenian"),
        Language(code: "es", displayName: "Spanish"),
        Language(code: "sv", displayName: "Swedish"),
        Language(code: "ta", displayName: "Tamil"),
        Language(code: "te", displayName: "Telugu"),
        Language(code: "th", displayName: "Thai"),
        Language(code: "tr", displayName: "Turkish"),
        Language(code: "uk", displayName: "Ukrainian"),
        Language(code: "vi", displayName: "Vietnamese"),
        Language(code: "cy", displayName: "Welsh"),
    ]

    private static let byCode: [String: Language] = Dictionary(
        uniqueKeysWithValues: supported.map { ($0.code, $0) }
    )

    static func language(forCode code: String) -> Language? {
        byCode[code]
    }

    /// Case-insensitive substring match against display name OR code, e.g. typing
    /// "port" or "pt" both surface Portuguese. Empty query returns the full list
    /// (used to show all options when the picker's text field is first focused).
    static func filter(query: String) -> [Language] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return supported }
        let needle = trimmed.lowercased()
        return supported.filter {
            $0.displayName.lowercased().contains(needle) || $0.code.lowercased().contains(needle)
        }
    }
}
