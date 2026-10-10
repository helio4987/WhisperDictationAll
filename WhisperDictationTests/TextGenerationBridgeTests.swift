import XCTest
@testable import WhisperDictation

// MARK: - TextGenerationBridge

/// Covers what's practical to test without bundling a real GGUF model in the
/// test target (multi-hundred-MB download, not something CI/local test runs
/// should depend on fetching). Real inference was verified manually against
/// a downloaded SmolLM2-360M-Instruct model during development — see the
/// Settings "Test" button on a Custom Operation for the same path exercised
/// interactively.
final class TextGenerationBridgeTests: XCTestCase {
    func testInvalidModelPathThrowsModelLoadFailed() {
        XCTAssertThrowsError(try TextGenerationBridge(modelPath: "/nonexistent/model.gguf")) { error in
            guard case TextGenerationError.modelLoadFailed(let path) = error else {
                XCTFail("Expected modelLoadFailed, got \(error)")
                return
            }
            XCTAssertEqual(path, "/nonexistent/model.gguf")
        }
    }

    func testErrorDescriptionsAreNonEmpty() {
        let errors: [TextGenerationError] = [
            .modelLoadFailed("/some/path.gguf"),
            .generationFailed("decode failed"),
            .promptTooLong(tokenCount: 5000, contextSize: 2048),
            .cancelled,
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "for \(error)")
        }
    }

    func testPromptTooLongDescriptionIncludesCounts() {
        let error = TextGenerationError.promptTooLong(tokenCount: 5000, contextSize: 2048)
        XCTAssertTrue(error.errorDescription?.contains("5000") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("2048") ?? false)
    }
}

// MARK: - TextGenerationManager

@MainActor
final class TextGenerationManagerTests: XCTestCase {
    func testBridgeThrowsForInvalidModelPathWithoutCaching() async {
        let manager = TextGenerationManager.shared
        do {
            _ = try await manager.bridge(forModelPath: "/nonexistent/manager-test.gguf")
            XCTFail("Expected modelLoadFailed to be thrown")
        } catch is TextGenerationError {
            // Expected — a failed load must not be cached as if it succeeded,
            // so a retry (e.g. after the user fixes the path) gets a fresh attempt.
        } catch {
            XCTFail("Expected TextGenerationError, got \(error)")
        }
    }

    func testLoadStateReflectsFailureAfterInvalidPath() async {
        let manager = TextGenerationManager.shared
        let path = "/nonexistent/load-state-test-\(UUID().uuidString).gguf"

        _ = try? await manager.bridge(forModelPath: path)

        if case .failed = manager.loadState(forModelPath: path) {
            // expected
        } else {
            XCTFail("Expected .failed state, got \(manager.loadState(forModelPath: path))")
        }
    }

    func testLoadStateIsUnloadedForAPathNeverUsed() {
        let manager = TextGenerationManager.shared
        let path = "/never/touched/\(UUID().uuidString).gguf"
        XCTAssertEqual(manager.loadState(forModelPath: path), .unloaded)
    }

    func testUnloadIsNoOpForAPathWithNoSlot() async {
        let manager = TextGenerationManager.shared
        let path = "/never/loaded/\(UUID().uuidString).gguf"
        // Must not crash/throw — mirrors LanguageModelSlot.unload()'s own
        // idempotence for a slot that was never loaded.
        await manager.unload(modelPath: path)
        XCTAssertEqual(manager.loadState(forModelPath: path), .unloaded)
    }

    func testUnloadAllCompletesWithoutThrowing() async {
        // Must not crash regardless of how many slots exist (zero, from a
        // never-touched path, or more from earlier tests in this run) — e.g.
        // the very first time Settings' "Unload All" is tapped.
        await TextGenerationManager.shared.unloadAll()
    }
}
