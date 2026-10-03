import Foundation

/// Minimal `UserDefaults`-compatible key/value store backed by a JSON file at
/// `~/.WhisperDictation/settings.json`, instead of the standard (and much less
/// discoverable, and binary/plist-formatted) `~/Library/Preferences/<bundle-id>.plist`
/// location `UserDefaults` would otherwise use. JSON over plist for legibility and
/// because it's a more universally standard format to hand-edit or inspect outside
/// the app. Exposes just the subset of the `UserDefaults` API `AppSettings` actually
/// calls (`object`/`string`/`bool`/`stringArray`/`set`/`removeObject`), so
/// `AppSettings` itself needed no changes beyond swapping which store it talks to.
///
/// Not a general-purpose `UserDefaults` replacement: no KVO, no cross-process
/// change notifications, no `NSUbiquitousKeyValueStore` sync. This app's prior
/// use of `UserDefaults.standard` didn't rely on any of those either — settings
/// are read/written only from within this one process.
final class FileBackedDefaults: @unchecked Sendable {
    static let shared = FileBackedDefaults()

    /// `~/.WhisperDictation/settings.json`.
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".WhisperDictation", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var storage: [String: Any]

    /// Legacy plist location this store used before switching to JSON. Checked as
    /// a one-time migration fallback alongside the even-older `UserDefaults`
    /// fallback below.
    private static var legacyPlistFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".WhisperDictation", isDirectory: true)
            .appendingPathComponent("settings.plist")
    }

    init(fileURL: URL = FileBackedDefaults.defaultFileURL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.storage = Self.loadJSON(from: fileURL)
        } else if FileManager.default.fileExists(atPath: Self.legacyPlistFileURL.path) {
            // One-time migration from this store's own prior plist format.
            self.storage = Self.loadPlist(from: Self.legacyPlistFileURL)
            if !self.storage.isEmpty { save() }
        } else {
            // First launch after the original UserDefaults -> file-backed-store
            // migration: carry over whatever was previously in
            // UserDefaults.standard's `com.sampop.WhisperDictation` domain (the
            // only domain this app ever wrote to), so existing users don't appear
            // to have had their settings silently reset. Only the keys
            // AppSettings actually defines are copied — no other apps'
            // UserDefaults data is touched or read.
            self.storage = Self.migrateFromUserDefaults()
            if !self.storage.isEmpty { save() }
        }
    }

    /// One-time best-effort migration from the legacy `UserDefaults.standard`
    /// storage this app used before moving to `~/.WhisperDictation/settings.plist`.
    /// Reads only recognized `AppSettings` keys; anything else in the standard
    /// domain (there shouldn't be anything else, since this app wrote only these
    /// keys) is left untouched and ignored.
    private static func migrateFromUserDefaults() -> [String: Any] {
        let legacyKeys = [
            "hotkeyKeyCode", "hotkeyMode", "toggleHoldDuration", "selectedModel",
            "soundFeedbackEnabled", "vocabularyPrompt", "launchAtLogin",
            "minimumRecordingDuration", "grammarCorrectionEnabled",
            "selectedAudioDeviceUID", "numberConversionEnabled", "customTerms",
            "hasCompletedOnboarding", "liveDictationEnabled",
            "secondaryLanguageCode", "secondaryModelSelection",
            "secondaryHotkeyKeyCode", "primaryIdleTimeoutMinutes",
            "secondaryIdleTimeoutMinutes", "secondaryVocabularyPrompt",
            "includeEnglishTermsInSecondary",
        ]
        var migrated: [String: Any] = [:]
        let legacy = UserDefaults.standard
        for key in legacyKeys {
            if let value = legacy.object(forKey: key) {
                migrated[key] = value
            }
        }
        return migrated
    }

    private static func loadJSON(from url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func loadPlist(from url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    /// Writes the whole store back to disk as pretty-printed, sorted-key JSON —
    /// legible and diff-friendly for anyone opening the file directly. Called
    /// after every mutation — settings changes are infrequent (user interactions
    /// in Settings, not a hot path), so the simplicity of "always persist the
    /// full dict" outweighs batching writes.
    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard JSONSerialization.isValidJSONObject(storage),
              let data = try? JSONSerialization.data(withJSONObject: storage, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func bool(forKey key: String) -> Bool {
        object(forKey: key) as? Bool ?? false
    }

    func stringArray(forKey key: String) -> [String]? {
        object(forKey: key) as? [String]
    }

    /// General setter, matching `UserDefaults.set(_:forKey:)`'s shape. `value:
    /// Any?` accepts every concrete type `AppSettings` stores (Int, Double, Bool,
    /// String, [String]) via Swift's implicit bridging to the parameter type.
    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
        lock.unlock()
        save()
    }

    func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }
}
