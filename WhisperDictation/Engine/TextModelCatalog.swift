import Foundation

/// A GGUF text-generation model discovered via the Hugging Face Hub API, for the
/// "improve selected text" feature (text rewrite via a local LLM). Unlike
/// `ModelManager.ModelInfo` (a fixed Swift array curated by hand for Whisper), this
/// catalog is fetched live from Hugging Face and cached to disk — see
/// `TextModelCatalog`. The GGUF text-LLM ecosystem moves too fast for a hardcoded
/// list to stay current, so discovery is dynamic; download/verify/store still
/// reuses the same pattern as `ModelManager`.
struct TextModelCandidate: Identifiable, Codable, Equatable {
    /// Hugging Face repo id, e.g. "bartowski/Llama-3.2-3B-Instruct-GGUF".
    let repoId: String
    /// Last path component of `repoId`, e.g. "Llama-3.2-3B-Instruct-GGUF".
    let displayName: String
    let downloads: Int
    let likes: Int

    var id: String { repoId }
}

/// One quantized `.gguf` file within a `TextModelCandidate`'s repo. Fetched lazily
/// (only when the user expands a candidate in Settings), since each variant list
/// costs a separate API call — fetching all of them for every candidate up front
/// would turn one "Refresh" tap into dozens of requests.
struct TextModelVariant: Identifiable, Codable, Equatable {
    let repoId: String
    let fileName: String
    let sizeBytes: Int64
    /// SHA256 of the exact file, taken from the Hugging Face LFS pointer metadata.
    /// Verified after download, same as `ModelManager.ModelInfo.sha256`.
    let sha256: String

    var id: String { "\(repoId)/\(fileName)" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileName)")!
    }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Quantization tag parsed from the file name (e.g. "Q4_K_M", "IQ3_M",
    /// "Q8_0"), or nil if the name doesn't contain a recognizable one. Used to
    /// apply `AppSettings.textModelPreferredQuantization`. GGUF file names
    /// consistently end in "-<TAG>.gguf" (optionally with a shard suffix already
    /// excluded by `TextModelCatalog.parseVariants`), so matching the last
    /// hyphen-delimited component before the extension is reliable across the
    /// naming conventions different quantizers use (bartowski, unsloth, mradermacher).
    var quantizationTag: String? {
        let stem = fileName.replacingOccurrences(of: ".gguf", with: "")
        guard let lastComponent = stem.components(separatedBy: "-").last else { return nil }
        let isQuantLike = lastComponent.hasPrefix("Q") || lastComponent.hasPrefix("IQ")
        return isQuantLike ? lastComponent : nil
    }
}

/// Fetches and caches a curated list of popular GGUF instruct models from the
/// Hugging Face Hub API (`huggingface.co/api/models`, public, unauthenticated).
///
/// Cached to `~/.WhisperDictation/textModelCatalog.json` alongside settings/models,
/// so opening Settings doesn't hit the network every time — only on first-ever use
/// (empty cache) or when the user explicitly taps Refresh. This mirrors the
/// project's one documented network exception (model downloads, see SECURITY.md):
/// a user-triggered catalog fetch, not background telemetry.
@MainActor
final class TextModelCatalog: ObservableObject {
    static let shared = TextModelCatalog()

    @Published private(set) var candidates: [TextModelCandidate] = []
    @Published private(set) var lastFetched: Date?
    @Published var fetchError: String?
    @Published var isFetching = false

    /// Variants already loaded for a candidate, keyed by `repoId`. Populated by
    /// `loadVariants(for:)`; absence means "not fetched yet", not "known empty".
    @Published private(set) var variantsByRepoId: [String: [TextModelVariant]] = [:]

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
            .appendingPathComponent("textModelCatalog.json")
    }

    /// Curated query: GGUF text-generation repos, ranked by downloads. Hugging
    /// Face's raw ranking surfaces unrelated pipeline tags (vision, audio,
    /// object-detection) and huge base models even under the "gguf" filter, so
    /// results get a further client-side pass in `filterCandidates`.
    private var listURL: URL {
        URL(string: "https://huggingface.co/api/models?filter=gguf&pipeline_tag=text-generation&sort=downloads&direction=-1&limit=50")!
    }

    private func detailURL(forRepoId repoId: String) -> URL {
        URL(string: "https://huggingface.co/api/models/\(repoId)?blobs=true")!
    }

    /// Fetches the candidate list and replaces the cache. Safe to call repeatedly
    /// (e.g. from a Settings "Refresh" button) — a failure leaves the previous
    /// cached list and `lastFetched` date in place rather than clearing them, so a
    /// transient network error doesn't blank out an otherwise-usable list.
    func refresh() async {
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            let (data, response) = try await session.data(from: listURL)
            if let http = response as? HTTPURLResponse, !ModelManager.isAcceptableStatusCode(http.statusCode) {
                throw ModelError.badStatus(http.statusCode)
            }
            let raw = try JSONDecoder().decode([HFModelSummary].self, from: data)
            candidates = Self.filterCandidates(raw)
            lastFetched = Date()
            saveCache()
        } catch {
            fetchError = "Couldn't fetch model list: \(error.localizedDescription)"
        }
    }

    /// Loads (and caches in-memory) the downloadable `.gguf` variants for one
    /// candidate. Returns the cached result on repeat calls without re-fetching.
    func loadVariants(for candidate: TextModelCandidate) async -> [TextModelVariant] {
        if let cached = variantsByRepoId[candidate.repoId] {
            return cached
        }
        guard let (data, response) = try? await session.data(from: detailURL(forRepoId: candidate.repoId)),
              let http = response as? HTTPURLResponse, ModelManager.isAcceptableStatusCode(http.statusCode),
              let detail = try? JSONDecoder().decode(HFModelDetail.self, from: data)
        else {
            return []
        }
        let variants = Self.parseVariants(detail, repoId: candidate.repoId)
        variantsByRepoId[candidate.repoId] = variants
        return variants
    }

    /// Pure for testability: extracts `.gguf` siblings that carry LFS metadata
    /// (size + sha256) — a sibling without `lfs` can't be verified after download,
    /// so it's excluded rather than offered with no integrity check.
    ///
    /// Also excludes multi-part/sharded files (Hugging Face `rfilename`s that
    /// live inside a repo subfolder, e.g.
    /// "Model-GGUF/Model-00001-of-00028.gguf"): a single `Download` button can't
    /// reassemble a sharded model, and `TextModelManager`'s flat
    /// `modelsDirectory.appendingPathComponent(fileName)` would try to write into
    /// a subdirectory that doesn't exist, which fails outright (this is what
    /// produced the "couldn't be moved... folder containing the latter doesn't
    /// exist" errors on a 28-shard repo). Checked via `rfilename.contains("/")`
    /// — a bare top-level `.gguf` file never contains a path separator.
    ///
    /// `nonisolated` since this does no main-actor work and tests call it
    /// synchronously (the enclosing class is `@MainActor`, which would otherwise
    /// isolate even this pure, static helper).
    ///
    /// Also excludes two kinds of auxiliary `.gguf` files that sit alongside
    /// real model variants in the same repo but aren't themselves loadable
    /// text-generation models:
    /// - Importance-matrix calibration files ("imatrix.gguf" or
    ///   "<repo>.imatrix.gguf") that some quantizers (bartowski, in
    ///   particular) publish — internal inputs to the quantization process.
    /// - Multimodal projector files ("mmproj-*.gguf"), used alongside a main
    ///   vision/multimodal model, not loadable standalone.
    /// Both fail in `llama_model_load_from_file` with a generic "Failed to
    /// load model" error that gives no hint it's the wrong *kind* of file
    /// rather than a corrupt or incompatible model. Matched by substring
    /// (case-insensitive) since the exact file name varies per repo.
    nonisolated static func parseVariants(_ detail: HFModelDetail, repoId: String) -> [TextModelVariant] {
        detail.siblings.compactMap { sibling in
            let lowercasedName = sibling.rfilename.lowercased()
            guard sibling.rfilename.hasSuffix(".gguf"),
                  !sibling.rfilename.contains("/"),
                  !lowercasedName.contains("imatrix"),
                  !lowercasedName.hasPrefix("mmproj"),
                  let lfs = sibling.lfs
            else { return nil }
            return TextModelVariant(
                repoId: repoId,
                fileName: sibling.rfilename,
                sizeBytes: lfs.size,
                sha256: lfs.sha256
            )
        }
    }

    /// Applies the user's size/quantization preferences (see
    /// `AppSettings.textModelMaxSizeGB`/`textModelPreferredQuantization`) to a
    /// variant list. `nonisolated` and pure — same reasoning as `parseVariants`.
    /// A `maxSizeGB` of 0 means "no limit"; a `preferredQuantization` of "Any"
    /// (or one that matches nothing) disables that filter rather than hiding
    /// every variant, so an unrecognized/renamed tag never results in an empty
    /// list the user can't explain.
    nonisolated static func filterVariants(
        _ variants: [TextModelVariant],
        maxSizeGB: Double,
        preferredQuantization: String
    ) -> [TextModelVariant] {
        var result = variants
        if maxSizeGB > 0 {
            let maxBytes = Int64(maxSizeGB * 1_000_000_000)
            result = result.filter { $0.sizeBytes <= maxBytes }
        }
        if preferredQuantization != "Any" {
            let matching = result.filter { $0.quantizationTag == preferredQuantization }
            if !matching.isEmpty { result = matching }
        }
        return result
    }

    /// Pure for testability: curates the raw Hugging Face ranking down to repos
    /// that look like small instruct/chat GGUF models suitable for a quick local
    /// text-rewrite task — excluding coder-specialized models (a separate
    /// concern from prose editing) and anything without an instruct/chat signal
    /// in its name (base/foundation checkpoints aren't usable for this feature
    /// without a chat template). `nonisolated` for the same reason as
    /// `parseVariants` — pure, synchronous, and called directly from tests.
    nonisolated static func filterCandidates(_ raw: [HFModelSummary]) -> [TextModelCandidate] {
        raw
            .filter { summary in
                let id = summary.id.lowercased()
                let hasInstructSignal = id.contains("instruct") || id.contains("chat")
                let isCoder = id.contains("coder")
                return hasInstructSignal && !isCoder
            }
            .map { summary in
                TextModelCandidate(
                    repoId: summary.id,
                    displayName: summary.id.components(separatedBy: "/").last ?? summary.id,
                    downloads: summary.downloads,
                    likes: summary.likes
                )
            }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return }
        candidates = cached.candidates
        lastFetched = cached.lastFetched
    }

    private func saveCache() {
        let cache = CacheFile(candidates: candidates, lastFetched: lastFetched)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct CacheFile: Codable {
        let candidates: [TextModelCandidate]
        let lastFetched: Date?
    }
}

// MARK: - Hugging Face API response shapes (decode-only, minimal fields)

struct HFModelSummary: Decodable, Equatable {
    let id: String
    let downloads: Int
    let likes: Int
}

struct HFModelDetail: Decodable, Equatable {
    let siblings: [HFSibling]
}

struct HFSibling: Decodable, Equatable {
    let rfilename: String
    let lfs: HFLfs?
}

struct HFLfs: Decodable, Equatable {
    let sha256: String
    let size: Int64
}
