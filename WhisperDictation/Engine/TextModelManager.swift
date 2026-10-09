import Foundation
import CryptoKit

/// Downloads, verifies, and stores GGUF text models discovered via
/// `TextModelCatalog`. Mirrors `ModelManager`'s download pipeline (progress
/// tracking, cancellation, pinned-SHA256 verification) but is independent of it:
/// `ModelManager` curates a fixed catalog of Whisper models; this manager stores
/// whatever variant the user picked from the live Hugging Face catalog.
///
/// This milestone only covers download/storage — nothing here loads a model into
/// memory or runs inference. That's a separate piece (a `llama.cpp`-backed engine,
/// analogous to `WhisperBridge`) layered on top of what's downloaded here.
@MainActor
final class TextModelManager: ObservableObject {
    static let shared = TextModelManager()

    /// Progress (0...1) of in-flight downloads, keyed by variant `id`
    /// ("repoId/fileName") — mirrors `ModelManager.activeDownloads`.
    @Published var activeDownloads: [String: Double] = [:]
    @Published var downloadError: String?

    /// Full metadata for every variant that has been successfully downloaded,
    /// persisted independently of `TextModelCatalog`'s live (and only cached,
    /// refresh-able) list. Without this, a model that drops out of a later
    /// catalog refresh — renamed, delisted, or just pushed out of the top-50
    /// ranking — would leave a file on disk with nothing in the UI able to
    /// reference or delete it. Populated on successful download; reconciled
    /// against disk at launch in case a file was removed outside the app.
    @Published private(set) var downloadedVariants: [TextModelVariant] = []

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadGeneration: [String: Int] = [:]

    private let fileManager = FileManager.default

    /// `~/.WhisperDictation/TextModels` — alongside Whisper's `Models` directory
    /// and `settings.json`, keeping everything the app persists under one visible
    /// top-level folder.
    var modelsDirectory: URL {
        let dir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".WhisperDictation", isDirectory: true)
            .appendingPathComponent("TextModels", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var manifestURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".WhisperDictation", isDirectory: true)
            .appendingPathComponent("textModelsDownloaded.json")
    }

    private init() {
        loadManifest()
    }

    func isDownloaded(_ variant: TextModelVariant) -> Bool {
        fileManager.fileExists(atPath: localPath(for: variant).path)
    }

    func localPath(for variant: TextModelVariant) -> URL {
        modelsDirectory.appendingPathComponent(variant.fileName)
    }

    /// Loads the manifest of previously-downloaded variants and drops any entry
    /// whose file is no longer on disk (removed outside the app, e.g. via
    /// Finder) — the manifest only ever reflects what's actually present.
    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let saved = try? JSONDecoder().decode([TextModelVariant].self, from: data)
        else { return }
        downloadedVariants = saved.filter { isDownloaded($0) }
        if downloadedVariants.count != saved.count {
            saveManifest()
        }
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(downloadedVariants) else { return }
        try? fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Records a successfully downloaded variant in the manifest, replacing any
    /// existing entry for the same `id` (e.g. a re-download after a checksum
    /// change upstream). Internal (not private) so tests can simulate a
    /// completed download without a real network fetch.
    func recordDownloaded(_ variant: TextModelVariant) {
        downloadedVariants.removeAll { $0.id == variant.id }
        downloadedVariants.append(variant)
        saveManifest()
    }

    func isDownloading(_ variant: TextModelVariant) -> Bool {
        downloadTasks[variant.id] != nil
    }

    func downloadProgress(for variant: TextModelVariant) -> Double? {
        activeDownloads[variant.id]
    }

    /// Fire-and-forget download entry point for the UI. Ignores duplicate starts
    /// for the same variant (same guard shape as `ModelManager.startDownload`).
    func startDownload(_ variant: TextModelVariant) {
        let key = variant.id
        guard downloadTasks[key] == nil else { return }
        let generation = (downloadGeneration[key] ?? 0) + 1
        downloadGeneration[key] = generation
        activeDownloads[key] = 0
        downloadError = nil
        downloadTasks[key] = Task { [weak self] in
            await self?.runDownload(variant, generation: generation)
        }
    }

    func cancelDownload(_ variant: TextModelVariant) {
        let key = variant.id
        downloadTasks[key]?.cancel()
        downloadTasks[key] = nil
        downloadGeneration[key] = (downloadGeneration[key] ?? 0) + 1
        activeDownloads[key] = nil
    }

    func deleteModel(_ variant: TextModelVariant) throws {
        try fileManager.removeItem(at: localPath(for: variant))
        downloadedVariants.removeAll { $0.id == variant.id }
        saveManifest()
    }

    private func reportProgress(_ progress: Double, key: String, generation: Int) {
        guard downloadGeneration[key] == generation else { return }
        activeDownloads[key] = progress
    }

    private func finishDownload(key: String, generation: Int, error: String?) {
        guard downloadGeneration[key] == generation else { return }
        activeDownloads[key] = nil
        downloadTasks[key] = nil
        if let error { downloadError = error }
    }

    /// Downloads, verifies (HTTP status + pinned SHA256 from the Hugging Face LFS
    /// metadata), and installs a variant. Safe to run twice: the temp file is
    /// verified before it replaces any existing model, and a mismatch throws
    /// without touching the installed copy — same shape as
    /// `ModelManager.runDownload`.
    private func runDownload(_ variant: TextModelVariant, generation: Int) async {
        let key = variant.id
        let destination = localPath(for: variant)

        do {
            // Defense in depth: `TextModelCatalog.parseVariants` already excludes
            // sharded/sub-path file names (containing "/"), but a flat
            // `appendingPathComponent` below would otherwise try to write into a
            // subdirectory that doesn't exist and fail with a confusing
            // "couldn't be moved" error — fail clearly up front instead if that
            // guard is ever bypassed (e.g. a future catalog source).
            guard !variant.fileName.contains("/") else {
                throw TextModelError.unsupportedShardedFile(variant.fileName)
            }

            try Task.checkCancellation()

            let (tempURL, response) = try await URLSession.shared.download(
                from: variant.downloadURL,
                delegate: TextModelDownloadDelegate { [weak self] progress in
                    Task { @MainActor in
                        self?.reportProgress(progress, key: key, generation: generation)
                    }
                }
            )

            if let http = response as? HTTPURLResponse, !ModelManager.isAcceptableStatusCode(http.statusCode) {
                try? fileManager.removeItem(at: tempURL)
                throw ModelError.badStatus(http.statusCode)
            }

            let actual = try ModelManager.sha256Hex(ofFileAt: tempURL)
            guard actual.caseInsensitiveCompare(variant.sha256) == .orderedSame else {
                try? fileManager.removeItem(at: tempURL)
                throw ModelError.checksumMismatch(expected: variant.sha256, actual: actual)
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: tempURL, to: destination)
            recordDownloaded(variant)

            finishDownload(key: key, generation: generation, error: nil)
        } catch is CancellationError {
            // cancelDownload() already performed cleanup.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Cancelled mid-transfer — cleanup handled by cancelDownload().
        } catch {
            fputs("[TextModelManager] Download failed for \(variant.fileName): \(error)\n", stderr)
            finishDownload(key: key, generation: generation,
                           error: "Couldn’t download \(variant.fileName): \(error.localizedDescription)")
        }
    }
}

enum TextModelError: LocalizedError {
    case unsupportedShardedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShardedFile(let fileName):
            return "\(fileName) is part of a multi-file (sharded) model, which isn't supported yet."
        }
    }
}

private final class TextModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
