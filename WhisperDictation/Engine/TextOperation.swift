import Foundation

/// A user-defined operation: hold a hotkey, run a local LLM over the current
/// text selection, replace the selection with the result. Unlike the fixed
/// primary/secondary dictation hotkeys, there can be any number of these —
/// each one freely named and configured, so "improve this text" is just one
/// example a user might create, not a built-in mode. The Settings tab for
/// these is "Custom Operations" (see `CustomOperationsSection`).
///
/// The prompt sent to the model is built from `prependText` (if enabled) +
/// the selected text + `appendText` (if enabled). Both are independently
/// optional: an operation can prepend only, append only, both, or neither
/// (passing the selection through to the model unmodified).
struct TextOperation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Carbon virtual key code for the hotkey, same representation as
    /// `AppSettings.hotkeyKeyCode`/`secondaryHotkeyKeyCode`. 0 (not a realistic
    /// key) signals "unassigned" for a freshly created operation until the user
    /// records one.
    var hotkeyKeyCode: Int
    /// References a downloaded `TextModelVariant` by its stable `id`
    /// ("repoId/fileName") rather than embedding the variant inline — the
    /// variant's own metadata (sha256, size) can be looked up from
    /// `TextModelManager.downloadedVariants` when needed, so this operation
    /// doesn't carry a stale copy of it.
    var modelVariantId: String?
    var prependEnabled: Bool
    var prependText: String
    var appendEnabled: Bool
    var appendText: String
    /// Sample text for the Settings "Run Test" control, persisted per
    /// operation so it survives an app restart along with everything else —
    /// otherwise it's reset to the hardcoded default every time Settings
    /// reopens, which looked like the whole operation hadn't been saved.
    var testSampleText: String
    /// Last test run's output and error, shown inline under the Test
    /// section until the next test run replaces them. Persisted for the
    /// same reason as `testSampleText` — losing a result on restart (or
    /// just reopening Settings) made it look like nothing had been kept.
    var lastTestOutput: String?
    var lastTestError: String?

    init(
        id: UUID = UUID(),
        name: String = "New Operation",
        hotkeyKeyCode: Int = 0,
        modelVariantId: String? = nil,
        prependEnabled: Bool = false,
        prependText: String = "",
        appendEnabled: Bool = false,
        appendText: String = "",
        testSampleText: String = "The weather today is pretty nice outside.",
        lastTestOutput: String? = nil,
        lastTestError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hotkeyKeyCode = hotkeyKeyCode
        self.modelVariantId = modelVariantId
        self.prependEnabled = prependEnabled
        self.prependText = prependText
        self.appendEnabled = appendEnabled
        self.appendText = appendText
        self.testSampleText = testSampleText
        self.lastTestOutput = lastTestOutput
        self.lastTestError = lastTestError
    }

    // Custom Codable so operations saved before testSampleText/lastTestOutput/
    // lastTestError existed still decode — the synthesized Codable would
    // otherwise require every key to be present and fail on older saved files.
    private enum CodingKeys: String, CodingKey {
        case id, name, hotkeyKeyCode, modelVariantId
        case prependEnabled, prependText, appendEnabled, appendText
        case testSampleText, lastTestOutput, lastTestError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hotkeyKeyCode = try container.decode(Int.self, forKey: .hotkeyKeyCode)
        modelVariantId = try container.decodeIfPresent(String.self, forKey: .modelVariantId)
        prependEnabled = try container.decode(Bool.self, forKey: .prependEnabled)
        prependText = try container.decode(String.self, forKey: .prependText)
        appendEnabled = try container.decode(Bool.self, forKey: .appendEnabled)
        appendText = try container.decode(String.self, forKey: .appendText)
        testSampleText = try container.decodeIfPresent(String.self, forKey: .testSampleText)
            ?? "The weather today is pretty nice outside."
        lastTestOutput = try container.decodeIfPresent(String.self, forKey: .lastTestOutput)
        lastTestError = try container.decodeIfPresent(String.self, forKey: .lastTestError)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hotkeyKeyCode, forKey: .hotkeyKeyCode)
        try container.encodeIfPresent(modelVariantId, forKey: .modelVariantId)
        try container.encode(prependEnabled, forKey: .prependEnabled)
        try container.encode(prependText, forKey: .prependText)
        try container.encode(appendEnabled, forKey: .appendEnabled)
        try container.encode(appendText, forKey: .appendText)
        try container.encode(testSampleText, forKey: .testSampleText)
        try container.encodeIfPresent(lastTestOutput, forKey: .lastTestOutput)
        try container.encodeIfPresent(lastTestError, forKey: .lastTestError)
    }

    /// Builds the full prompt sent to the model for a given selection: prepend
    /// text (if enabled, trimmed, with a trailing newline so it reads as its
    /// own line rather than running into the selection) + the selection itself
    /// + append text (if enabled, with a leading newline).
    func buildPrompt(forSelection selection: String) -> String {
        var parts: [String] = []
        if prependEnabled, !prependText.isEmpty { parts.append(prependText) }
        parts.append(selection)
        if appendEnabled, !appendText.isEmpty { parts.append(appendText) }
        return parts.joined(separator: "\n\n")
    }

    var hasHotkey: Bool { hotkeyKeyCode != 0 }
}

/// Persisted list of `TextOperation`s at `~/.WhisperDictation/customOperations.json`
/// — a separate file from `settings.json` because it's a variable-length
/// collection the user adds/removes/reorders freely, which doesn't fit
/// `AppSettings`/`FileBackedDefaults`'s flat key-value shape (that store holds
/// exactly one value per named setting, not a user-managed list of records).
@MainActor
final class TextOperationStore: ObservableObject {
    static let shared = TextOperationStore()

    @Published private(set) var operations: [TextOperation] = []

    /// Fired after every mutation (add/update/remove/move) that changes the
    /// persisted list — lets `CustomOperationEngine` keep its hotkey monitors
    /// in sync (create one for a newly-hotkeyed operation, tear one down for
    /// a removed operation) without depending on Combine. `@Published`
    /// already covers SwiftUI's needs; this is a second, explicit channel for
    /// a plain-class non-View observer, same shape as
    /// `LanguageModelSlot.onStateChange`.
    var onOperationsChanged: (() -> Void)?

    private let fileManager = FileManager.default

    private var fileURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".WhisperDictation", isDirectory: true)
            .appendingPathComponent("customOperations.json")
    }

    private init() {
        load()
    }

    func add(_ operation: TextOperation) {
        operations.append(operation)
        save()
        onOperationsChanged?()
    }

    func update(_ operation: TextOperation) {
        guard let index = operations.firstIndex(where: { $0.id == operation.id }) else { return }
        operations[index] = operation
        save()
        onOperationsChanged?()
    }

    func remove(_ operation: TextOperation) {
        operations.removeAll { $0.id == operation.id }
        save()
        onOperationsChanged?()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        operations.move(fromOffsets: source, toOffset: destination)
        save()
        onOperationsChanged?()
    }

    /// Hotkeys already in use by another custom operation, excluding
    /// `excluding` itself — used by the UI to warn when a newly recorded
    /// hotkey collides with one already assigned to a different operation.
    /// Collisions with the primary/secondary dictation hotkeys are checked
    /// separately by the caller (this store has no knowledge of `AppSettings`).
    /// `excluding` is `nil` when checking a hotkey that isn't itself one of
    /// the operations (e.g. the app-wide operations menu hotkey) — every
    /// operation is then a candidate conflict, not just "every operation
    /// except this one".
    func conflictingOperation(forHotkeyKeyCode keyCode: Int, excluding: UUID? = nil) -> TextOperation? {
        guard keyCode != 0 else { return nil }
        return operations.first { $0.id != excluding && $0.hotkeyKeyCode == keyCode }
    }

    /// Every operation that references `modelVariantId`, regardless of
    /// whether that operation currently has a hotkey assigned — used to block
    /// deleting a downloaded model that's still configured as an operation's
    /// model (see `TextModelVariantRow`'s delete guard). Deliberately not
    /// scoped to hotkey-bound operations only: an operation without a hotkey
    /// yet is still a saved configuration pointing at this model, and letting
    /// its model disappear out from under it would only surface as a failure
    /// later, once a hotkey is added — worse timing than blocking the delete
    /// now, when the user has full context on why.
    func operationsReferencing(modelVariantId: String) -> [TextOperation] {
        operations.filter { $0.modelVariantId == modelVariantId }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TextOperation].self, from: data)
        else { return }
        operations = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(operations) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
