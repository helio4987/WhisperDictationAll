import XCTest
@testable import WhisperDictation

// MARK: - TextModelCatalog.filterCandidates (pure, no network)

final class TextModelCatalogFilterTests: XCTestCase {
    func testKeepsInstructAndChatModels() {
        let raw = [
            HFModelSummary(id: "bartowski/Llama-3.2-3B-Instruct-GGUF", downloads: 100, likes: 10),
            HFModelSummary(id: "someorg/Mistral-7B-Chat-GGUF", downloads: 50, likes: 5),
        ]
        let result = TextModelCatalog.filterCandidates(raw)
        XCTAssertEqual(result.map(\.repoId), raw.map(\.id))
    }

    func testExcludesModelsWithoutInstructOrChatSignal() {
        let raw = [
            HFModelSummary(id: "meta-llama/Llama-3.2-3B-GGUF", downloads: 100, likes: 10),
        ]
        XCTAssertTrue(TextModelCatalog.filterCandidates(raw).isEmpty)
    }

    func testExcludesCoderModelsEvenWhenInstructTuned() {
        let raw = [
            HFModelSummary(id: "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", downloads: 100, likes: 10),
        ]
        XCTAssertTrue(TextModelCatalog.filterCandidates(raw).isEmpty)
    }

    func testFilterIsCaseInsensitive() {
        let raw = [
            HFModelSummary(id: "org/Model-INSTRUCT-GGUF", downloads: 1, likes: 1),
        ]
        XCTAssertEqual(TextModelCatalog.filterCandidates(raw).count, 1)
    }

    func testDisplayNameIsLastPathComponent() {
        let raw = [HFModelSummary(id: "bartowski/Llama-3.2-3B-Instruct-GGUF", downloads: 1, likes: 1)]
        let result = TextModelCatalog.filterCandidates(raw)
        XCTAssertEqual(result.first?.displayName, "Llama-3.2-3B-Instruct-GGUF")
    }

    func testPreservesDownloadsAndLikes() {
        let raw = [HFModelSummary(id: "org/Foo-Instruct-GGUF", downloads: 12345, likes: 678)]
        let result = TextModelCatalog.filterCandidates(raw)
        XCTAssertEqual(result.first?.downloads, 12345)
        XCTAssertEqual(result.first?.likes, 678)
    }
}

// MARK: - TextModelCatalog.parseVariants (pure, no network)

final class TextModelCatalogVariantParsingTests: XCTestCase {
    func testExtractsGGUFSiblingsWithLFSMetadata() {
        let detail = HFModelDetail(siblings: [
            HFSibling(rfilename: "model-Q4_K_M.gguf", lfs: HFLfs(sha256: "abc123", size: 2_000_000_000)),
            HFSibling(rfilename: "model-Q8_0.gguf", lfs: HFLfs(sha256: "def456", size: 3_000_000_000)),
        ])
        let variants = TextModelCatalog.parseVariants(detail, repoId: "org/Model-GGUF")
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(variants[0].fileName, "model-Q4_K_M.gguf")
        XCTAssertEqual(variants[0].sha256, "abc123")
        XCTAssertEqual(variants[0].sizeBytes, 2_000_000_000)
        XCTAssertEqual(variants[0].repoId, "org/Model-GGUF")
    }

    func testExcludesNonGGUFFiles() {
        let detail = HFModelDetail(siblings: [
            HFSibling(rfilename: "README.md", lfs: nil),
            HFSibling(rfilename: ".gitattributes", lfs: nil),
        ])
        XCTAssertTrue(TextModelCatalog.parseVariants(detail, repoId: "org/Model-GGUF").isEmpty)
    }

    func testExcludesGGUFFilesWithoutLFSMetadata() {
        // A .gguf sibling without `lfs` can't be verified after download (no
        // pinned sha256), so it must be excluded rather than offered unverifiable.
        let detail = HFModelDetail(siblings: [
            HFSibling(rfilename: "model-Q4_K_M.gguf", lfs: nil),
        ])
        XCTAssertTrue(TextModelCatalog.parseVariants(detail, repoId: "org/Model-GGUF").isEmpty)
    }

    func testExcludesImatrixCalibrationFiles() {
        // Regression test: bartowski (and others) publish an imatrix.gguf
        // calibration file alongside real model variants in the same repo.
        // It passes the ".gguf" + top-level + has-lfs checks, but
        // llama_model_load_from_file fails on it — it's not a loadable model.
        let detail = HFModelDetail(siblings: [
            HFSibling(rfilename: "imatrix.gguf", lfs: HFLfs(sha256: "abc", size: 50_000_000)),
            HFSibling(rfilename: "Llama-3.2-3B-Instruct.imatrix.gguf", lfs: HFLfs(sha256: "def", size: 60_000_000)),
            HFSibling(rfilename: "model-Q4_K_M.gguf", lfs: HFLfs(sha256: "ghi", size: 2_000_000_000)),
        ])
        let variants = TextModelCatalog.parseVariants(detail, repoId: "org/Model-GGUF")
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.fileName, "model-Q4_K_M.gguf")
    }

    func testExcludesMultimodalProjectorFiles() {
        // Regression test: a vision/multimodal repo publishes an
        // "mmproj-*.gguf" file alongside the real model — it's a projector
        // used together with a main model, not a standalone loadable one.
        let detail = HFModelDetail(siblings: [
            HFSibling(rfilename: "mmproj-Model-BF16.gguf", lfs: HFLfs(sha256: "abc", size: 900_000_000)),
            HFSibling(rfilename: "model-Q4_K_M.gguf", lfs: HFLfs(sha256: "ghi", size: 2_000_000_000)),
        ])
        let variants = TextModelCatalog.parseVariants(detail, repoId: "org/Model-GGUF")
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.fileName, "model-Q4_K_M.gguf")
    }

    func testExcludesShardedFilesInsideASubfolder() {
        // Regression test: a repo like "Qwen3.8-Flash-Next-GGUF" splits a single
        // model into N files inside a subfolder (rfilename contains "/"). A flat
        // Download button can't reassemble shards, and TextModelManager's flat
        // destination path would otherwise fail trying to write into a
        // subdirectory that doesn't exist.
        let detail = HFModelDetail(siblings: [
            HFSibling(
                rfilename: "Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64-00001-of-00028.gguf",
                lfs: HFLfs(sha256: "abc", size: 693_400_000)
            ),
            HFSibling(rfilename: "model-Q4_K_M.gguf", lfs: HFLfs(sha256: "def", size: 2_000_000_000)),
        ])
        let variants = TextModelCatalog.parseVariants(detail, repoId: "org/Qwen3.8-Flash-Next-GGUF")
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.fileName, "model-Q4_K_M.gguf")
    }

    func testDownloadURLPointsAtRepoAndFileName() {
        let variant = TextModelVariant(
            repoId: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            sizeBytes: 2_019_377_696,
            sha256: "abc123"
        )
        XCTAssertEqual(
            variant.downloadURL.absoluteString,
            "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        )
    }

    func testVariantIdCombinesRepoAndFileName() {
        let variant = TextModelVariant(repoId: "org/Model-GGUF", fileName: "model-Q4_K_M.gguf", sizeBytes: 1, sha256: "x")
        XCTAssertEqual(variant.id, "org/Model-GGUF/model-Q4_K_M.gguf")
    }

    func testQuantizationTagParsedFromFileName() {
        let cases: [(String, String?)] = [
            ("Llama-3.2-3B-Instruct-Q4_K_M.gguf", "Q4_K_M"),
            ("Llama-3.2-3B-Instruct-IQ4_XS.gguf", "IQ4_XS"),
            ("Llama-3.2-3B-Instruct-Q8_0.gguf", "Q8_0"),
            ("Llama-3.2-3B-Instruct-f16.gguf", nil),
            ("weirdly-named-file.gguf", nil),
        ]
        for (fileName, expected) in cases {
            let variant = TextModelVariant(repoId: "org/Repo", fileName: fileName, sizeBytes: 1, sha256: "x")
            XCTAssertEqual(variant.quantizationTag, expected, "for \(fileName)")
        }
    }
}

// MARK: - TextModelCatalog.filterVariants (pure, no network)

final class TextModelCatalogVariantFilterTests: XCTestCase {
    private let small = TextModelVariant(repoId: "org/Repo", fileName: "model-Q4_K_M.gguf", sizeBytes: 2_000_000_000, sha256: "a")
    private let large = TextModelVariant(repoId: "org/Repo", fileName: "model-Q8_0.gguf", sizeBytes: 8_000_000_000, sha256: "b")

    func testNoLimitAndAnyQuantizationReturnsEverything() {
        let result = TextModelCatalog.filterVariants([small, large], maxSizeGB: 0, preferredQuantization: "Any")
        XCTAssertEqual(result.count, 2)
    }

    func testMaxSizeExcludesLargerVariants() {
        let result = TextModelCatalog.filterVariants([small, large], maxSizeGB: 4, preferredQuantization: "Any")
        XCTAssertEqual(result, [small])
    }

    func testPreferredQuantizationNarrowsToMatchingVariants() {
        let result = TextModelCatalog.filterVariants([small, large], maxSizeGB: 0, preferredQuantization: "Q4_K_M")
        XCTAssertEqual(result, [small])
    }

    func testPreferredQuantizationFallsBackToAllWhenNothingMatches() {
        // No variant tagged "Q5_K_M" here — falling back to the (size-filtered)
        // full list avoids showing an empty result the user can't explain.
        let result = TextModelCatalog.filterVariants([small, large], maxSizeGB: 0, preferredQuantization: "Q5_K_M")
        XCTAssertEqual(result.count, 2)
    }

    func testSizeAndQuantizationFiltersCombine() {
        let result = TextModelCatalog.filterVariants([small, large], maxSizeGB: 4, preferredQuantization: "Q4_K_M")
        XCTAssertEqual(result, [small])
    }
}

// MARK: - TextModelManager (download storage, no network)

final class TextModelManagerTests: XCTestCase {
    private func makeVariant(fileName: String = "test-model-Q4_K_M.gguf") -> TextModelVariant {
        TextModelVariant(repoId: "org/Test-GGUF", fileName: fileName, sizeBytes: 1024, sha256: "deadbeef")
    }

    @MainActor
    func testIsDownloadedFalseForUnknownVariant() {
        let variant = makeVariant(fileName: "never-downloaded-\(UUID().uuidString).gguf")
        XCTAssertFalse(TextModelManager.shared.isDownloaded(variant))
    }

    @MainActor
    func testLocalPathIsInsideTextModelsDirectory() {
        let variant = makeVariant()
        let path = TextModelManager.shared.localPath(for: variant)
        XCTAssertTrue(path.path.contains(".WhisperDictation/TextModels"))
        XCTAssertEqual(path.lastPathComponent, variant.fileName)
    }

    @MainActor
    func testIsDownloadingFalseWhenNoDownloadStarted() {
        let variant = makeVariant(fileName: "not-downloading-\(UUID().uuidString).gguf")
        XCTAssertFalse(TextModelManager.shared.isDownloading(variant))
        XCTAssertNil(TextModelManager.shared.downloadProgress(for: variant))
    }

    @MainActor
    func testDeleteModelThrowsForMissingFile() {
        let variant = makeVariant(fileName: "missing-\(UUID().uuidString).gguf")
        XCTAssertThrowsError(try TextModelManager.shared.deleteModel(variant))
    }

    /// Regression test for the "downloaded model later disappears from the live
    /// catalog" scenario: a successful download must be recorded in
    /// `downloadedVariants` (persisted independently of `TextModelCatalog`,
    /// which only reflects the latest refresh), and `deleteModel` must remove
    /// it from that record too, not just from disk.
    @MainActor
    func testRecordDownloadedTracksVariantIndependentlyOfCatalog() throws {
        let manager = TextModelManager.shared
        let variant = makeVariant(fileName: "manifest-test-\(UUID().uuidString).gguf")

        // Write the file directly (what runDownload would have moved into
        // place) then record it, mirroring runDownload's success path without
        // needing a real network fetch.
        try "fake model bytes".data(using: .utf8)!.write(to: manager.localPath(for: variant))
        manager.recordDownloaded(variant)

        XCTAssertTrue(manager.downloadedVariants.contains(variant))

        try manager.deleteModel(variant)
        XCTAssertFalse(manager.isDownloaded(variant))
        XCTAssertFalse(manager.downloadedVariants.contains(variant))
    }

    @MainActor
    func testRecordDownloadedReplacesExistingEntryForSameId() throws {
        let manager = TextModelManager.shared
        let fileName = "manifest-replace-test-\(UUID().uuidString).gguf"
        let original = makeVariant(fileName: fileName)
        let updated = TextModelVariant(repoId: original.repoId, fileName: fileName, sizeBytes: 999, sha256: "newsha")
        defer { try? manager.deleteModel(original) }

        try "fake model bytes".data(using: .utf8)!.write(to: manager.localPath(for: original))
        manager.recordDownloaded(original)
        manager.recordDownloaded(updated)

        let matching = manager.downloadedVariants.filter { $0.id == original.id }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.sha256, "newsha")
    }
}
