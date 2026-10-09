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

    init(
        id: UUID = UUID(),
        name: String = "New Operation",
        hotkeyKeyCode: Int = 0,
        modelVariantId: String? = nil,
        prependEnabled: Bool = false,
        prependText: String = "",
        appendEnabled: Bool = false,
        appendText: String = ""
    ) {
        self.id = id
        self.name = name
        self.hotkeyKeyCode = hotkeyKeyCode
        self.modelVariantId = modelVariantId
        self.prependEnabled = prependEnabled
        self.prependText = prependText
        self.appendEnabled = appendEnabled
        self.appendText = appendText
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
    }

    func update(_ operation: TextOperation) {
        guard let index = operations.firstIndex(where: { $0.id == operation.id }) else { return }
        operations[index] = operation
        save()
    }

    func remove(_ operation: TextOperation) {
        operations.removeAll { $0.id == operation.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        operations.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Hotkeys already in use by another custom operation, excluding
    /// `excluding` itself — used by the UI to warn when a newly recorded
    /// hotkey collides with one already assigned to a different operation.
    /// Collisions with the primary/secondary dictation hotkeys are checked
    /// separately by the caller (this store has no knowledge of `AppSettings`).
    func conflictingOperation(forHotkeyKeyCode keyCode: Int, excluding: UUID) -> TextOperation? {
        guard keyCode != 0 else { return nil }
        return operations.first { $0.id != excluding && $0.hotkeyKeyCode == keyCode }
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
