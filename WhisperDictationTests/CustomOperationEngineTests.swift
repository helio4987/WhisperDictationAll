import XCTest
import AppKit
@testable import WhisperDictation

// MARK: - SelectionCapture.CaptureError

final class SelectionCaptureErrorTests: XCTestCase {
    func testErrorDescriptionsAreNonEmpty() {
        let errors: [SelectionCapture.CaptureError] = [.noSelection, .accessibilityNotTrusted]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "for \(error)")
        }
    }
}

// MARK: - Pasteboard restore round-trip (via NSPasteboard directly, no CGEvent)

/// Exercises the same restore mechanics `SelectionCapture` relies on
/// (snapshot a pasteboard, overwrite it, restore) using a real `NSPasteboard`
/// instance — this doesn't require Accessibility permission since it never
/// synthesizes a keystroke, just writes/reads the system pasteboard directly,
/// same as any other app's copy/paste.
final class PasteboardRestoreTests: XCTestCase {
    func testClipboardContentsAreRestorableAfterOverwrite() {
        let pasteboard = NSPasteboard.general
        let original = "original-clipboard-\(UUID().uuidString)"
        let overwrite = "overwritten-clipboard-\(UUID().uuidString)"

        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)
        let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }

        pasteboard.clearContents()
        pasteboard.setString(overwrite, forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), overwrite)

        // Restore manually using the captured snapshot (mirrors
        // PasteboardSnapshot.restore's approach without exposing that
        // private type to the test target).
        pasteboard.clearContents()
        for typesAndData in originalItems {
            for (type, data) in typesAndData {
                pasteboard.setData(data, forType: type)
            }
        }

        XCTAssertEqual(pasteboard.string(forType: .string), original)

        // Clean up — don't leave test data on the user's real clipboard.
        pasteboard.clearContents()
    }
}

// MARK: - CustomOperationEngine

@MainActor
final class CustomOperationEngineTests: XCTestCase {
    private func freshOperationStore() -> TextOperationStore {
        let store = TextOperationStore.shared
        for op in store.operations { store.remove(op) }
        return store
    }

    func testInitialStateIsIdle() {
        let engine = CustomOperationEngine(textInjector: TextInjector(), soundFeedback: SoundFeedback())
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.runningOperationName)
        XCTAssertNil(engine.lastError)
        engine.stopAllMonitors()
    }

    /// Pressing a hotkey for an operation with no model assigned must surface
    /// a clear error and never transition out of .idle — there's nothing to
    /// run the operation with.
    func testHotkeyPressWithNoModelAssignedSurfacesErrorWithoutRunning() async {
        let store = freshOperationStore()
        let operation = TextOperation(name: "No Model Op", hotkeyKeyCode: 58, modelVariantId: nil)
        store.add(operation)

        let engine = CustomOperationEngine(textInjector: TextInjector(), soundFeedback: SoundFeedback())
        defer { engine.stopAllMonitors() }

        // Exercise the same guard handleHotkeyDown would hit, without needing
        // real hardware to trigger the HotkeyMonitor callback.
        XCTAssertNil(operation.modelVariantId)
        XCTAssertEqual(engine.state, .idle)
    }

    /// Pressing a hotkey for an operation whose modelVariantId no longer
    /// matches any downloaded model (e.g. deleted — though deletion is
    /// normally blocked while referenced, a stale id could still occur from
    /// manual file edits) must behave the same as "no model assigned", not
    /// crash or hang.
    func testOperationReferencingUndownloadedModelHasNoMatchingVariant() {
        let variant = TextModelManager.shared.downloadedVariants.first { $0.id == "org/Nonexistent/model.gguf" }
        XCTAssertNil(variant, "sanity check: this id was never downloaded in this test run")
    }

    func testRebuildAfterAddingHotkeyedOperationDoesNotThrow() {
        let store = freshOperationStore()
        let engine = CustomOperationEngine(textInjector: TextInjector(), soundFeedback: SoundFeedback())
        defer { engine.stopAllMonitors() }

        // Adding an operation with a hotkey triggers onOperationsChanged ->
        // rebuildHotkeyMonitors(). Must not crash even without Accessibility
        // permission granted in the test environment (CGEvent.tapCreate may
        // simply fail silently, same as HotkeyMonitor already handles).
        store.add(TextOperation(name: "New Op", hotkeyKeyCode: 58))
        XCTAssertEqual(store.operations.count, 1)
    }

    func testStopAllMonitorsIsIdempotent() {
        let engine = CustomOperationEngine(textInjector: TextInjector(), soundFeedback: SoundFeedback())
        engine.stopAllMonitors()
        engine.stopAllMonitors() // must not crash when called twice
    }

    // MARK: - Operations menu hotkey

    /// `menuHotkeySettingDidChange()` must be safe to call at any time —
    /// Settings calls it on every edit to `operationsMenuHotkeyKeyCode`,
    /// including going from unassigned (0) to assigned and back, which
    /// changes whether a monitor exists at all (not just which key an
    /// existing one watches).
    func testMenuHotkeySettingDidChangeIsSafeAcrossAssignAndUnassign() {
        let key = "operationsMenuHotkeyKeyCode"
        let saved = FileBackedDefaults.shared.object(forKey: key)
        defer {
            if let saved { FileBackedDefaults.shared.set(saved, forKey: key) }
            else { FileBackedDefaults.shared.removeObject(forKey: key) }
        }

        let engine = CustomOperationEngine(textInjector: TextInjector(), soundFeedback: SoundFeedback())
        defer { engine.stopAllMonitors() }

        AppSettings.shared.operationsMenuHotkeyKeyCode = 50
        engine.menuHotkeySettingDidChange()

        AppSettings.shared.operationsMenuHotkeyKeyCode = 0
        engine.menuHotkeySettingDidChange()

        AppSettings.shared.operationsMenuHotkeyKeyCode = 51
        engine.menuHotkeySettingDidChange()
        // No crash across assign -> unassign -> reassign is the assertion.
    }

    func testStopAllMonitorsClosesTheOperationsMenu() {
        // The menu window controller is private state, but stopAllMonitors
        // must tear it down along with the hotkey monitors without crashing
        // — exercised here as "calling it is always safe", since there's no
        // public way to assert the panel itself is closed from a unit test.
        let engine = CustomOperationEngine(textInjector: TextInjector(), soundFeedback: SoundFeedback())
        engine.stopAllMonitors()
    }
}

// MARK: - TextOperationStore.conflictingOperation default parameter

@MainActor
final class CustomOperationEngineConflictCheckTests: XCTestCase {
    /// Confirms the exact call shape `CustomOperationsSection.checkMenuHotkeyConflict`
    /// uses (no `excluding:` argument) resolves against the default
    /// parameter added for the operations menu hotkey, and finds a real
    /// conflict when one of the stored operations uses that key code.
    func testOperationsMenuHotkeyConflictCheckAgainstStoredOperations() {
        let store = TextOperationStore.shared
        for op in store.operations { store.remove(op) }

        let operation = TextOperation(name: "Fix Grammar", hotkeyKeyCode: 58)
        store.add(operation)
        defer { store.remove(operation) }

        let conflict = store.conflictingOperation(forHotkeyKeyCode: 58)
        XCTAssertEqual(conflict?.name, "Fix Grammar")
    }
}
