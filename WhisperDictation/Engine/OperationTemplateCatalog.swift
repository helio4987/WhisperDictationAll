import Foundation

/// A distributable starting point for a Custom Operation's prompt framing,
/// fetched from this fork's own GitHub repo rather than written into the app.
/// Deliberately NOT a full `TextOperation`: it never carries a hotkey or a
/// model, since both depend on what the installing user has downloaded and
/// which keys are free on their machine — "Use Template" always leaves both
/// unassigned on the created operation, the same empty state a manually
/// added operation starts in.
///
/// There is no bundled fallback list in the app itself — every template
/// comes from the fetched file, by design (see `operation-templates/README.md`
/// in the repo). An empty fetch or a fetch failure just means no templates
/// are available yet, not a missing feature.
struct OperationTemplate: Identifiable, Codable, Equatable {
    /// Stable, unique, kebab-case — never reused for a different template
    /// (see the repo README). Used as the dedupe key when merging a refetch
    /// with what's already cached, and as SwiftUI's `Identifiable` id.
    let id: String
    let name: String
    let description: String
    let prependEnabled: Bool
    let prependText: String
    let appendEnabled: Bool
    let appendText: String
    /// Freeform display hint (e.g. "Works well with any Q4_K_M instruct
    /// model, even 1-3B."). Never used to auto-select a model — purely
    /// informational text shown in the UI.
    let recommendedModelHint: String?

    /// Builds a new, unassigned `TextOperation` from this template: prompt
    /// framing copied over, hotkey and model left for the user to set, same
    /// as a freshly added blank operation.
    func makeOperation() -> TextOperation {
        TextOperation(
            name: name,
            prependEnabled: prependEnabled,
            prependText: prependText,
            appendEnabled: appendEnabled,
            appendText: appendText
        )
    }
}

/// Fetches and caches the list of `OperationTemplate`s published at
/// `operation-templates/templates.json` in this fork's own GitHub repo (raw
/// content, public, unauthenticated — same trust/caching shape as
/// `TextModelCatalog`'s Hugging Face fetch: a user-triggered Refresh, not
/// background telemetry, documented alongside it in SECURITY.md).
///
/// Cached to `~/.WhisperDictation/operationTemplates.json` so Settings
/// doesn't hit the network on every open — only on first-ever use (empty
/// cache) or an explicit Refresh tap. Pushing a commit to `templates.json`
/// on `main` makes a new template available to every install on their next
/// Refresh, with no app update or release involved.
@MainActor
final class OperationTemplateCatalog: ObservableObject {
    static let shared = OperationTemplateCatalog()

    /// Schema versions this app build knows how to render. A fetched file
    /// declaring a newer version is rejected outright (surfaced as
    /// `fetchError`) rather than guessed at — this is the deliberate
    /// counterpart to Codable's usual "unknown fields are silently ignored"
    /// leniency: a *version* mismatch means the template shape itself may
    /// have changed in a way this build can't safely interpret, so refusing
    /// is safer than rendering a template missing fields it actually needs.
    static let supportedSchemaVersion = 1

    @Published private(set) var templates: [OperationTemplate] = []
    @Published private(set) var lastFetched: Date?
    @Published var fetchError: String?
    @Published var isFetching = false

    private let fileManager = FileManager.default
    private let session: URLSession

    /// Injectable for tests; defaults to the shared URLSession in production.
    init(session: URLSession = .shared) {
        self.session = session
        loadCache()
    }

    private var cacheURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".WhisperDictation", isDirectory: true)
            .appendingPathComponent("operationTemplates.json")
    }

    /// Raw content URL for this fork's own templates file, pinned to `main`
    /// — the whole point is "push a commit, it shows up on next Refresh",
    /// not a tagged release.
    private var templatesURL: URL {
        URL(string: "https://raw.githubusercontent.com/helio4987/WhisperDictationAll/main/operation-templates/templates.json")!
    }

    /// Fetches the template list and replaces the cache. Safe to call
    /// repeatedly (e.g. from a Settings "Refresh" button) — a failure leaves
    /// the previous cached list and `lastFetched` date in place rather than
    /// clearing them, so a transient network error doesn't blank out an
    /// otherwise-usable list. Same shape as `TextModelCatalog.refresh()`.
    func refresh() async {
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            let (data, response) = try await session.data(from: templatesURL)
            if let http = response as? HTTPURLResponse, !ModelManager.isAcceptableStatusCode(http.statusCode) {
                throw ModelError.badStatus(http.statusCode)
            }
            let file = try JSONDecoder().decode(TemplatesFile.self, from: data)
            guard file.schemaVersion == Self.supportedSchemaVersion else {
                throw OperationTemplateError.unsupportedSchemaVersion(file.schemaVersion)
            }
            templates = file.templates
            lastFetched = Date()
            saveCache()
        } catch {
            fetchError = "Couldn't fetch templates: \(error.localizedDescription)"
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return }
        templates = cached.templates
        lastFetched = cached.lastFetched
    }

    private func saveCache() {
        let cache = CacheFile(templates: templates, lastFetched: lastFetched)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct CacheFile: Codable {
        let templates: [OperationTemplate]
        let lastFetched: Date?
    }
}

/// Decode-only shape of `operation-templates/templates.json`.
struct TemplatesFile: Decodable, Equatable {
    let schemaVersion: Int
    let templates: [OperationTemplate]
}

enum OperationTemplateError: LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "This template file uses a newer format (schema \(version)) than this app understands. Update the app to use these templates."
        }
    }
}
