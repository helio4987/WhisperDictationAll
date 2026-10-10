import XCTest
@testable import WhisperDictation

// MARK: - TextOperation.buildPrompt (pure, no network)

final class TextOperationPromptTests: XCTestCase {
    func testNeitherPrependNorAppendPassesSelectionThrough() {
        let operation = TextOperation(prependEnabled: false, appendEnabled: false)
        XCTAssertEqual(operation.buildPrompt(forSelection: "hello world"), "hello world")
    }

    func testPrependOnly() {
        let operation = TextOperation(prependEnabled: true, prependText: "Fix the grammar:")
        XCTAssertEqual(operation.buildPrompt(forSelection: "i has a dog"), "Fix the grammar:\n\ni has a dog")
    }

    func testAppendOnly() {
        let operation = TextOperation(appendEnabled: true, appendText: "Keep it under 10 words.")
        XCTAssertEqual(operation.buildPrompt(forSelection: "hello world"), "hello world\n\nKeep it under 10 words.")
    }

    func testPrependAndAppendTogether() {
        let operation = TextOperation(
            prependEnabled: true, prependText: "Translate to French:",
            appendEnabled: true, appendText: "Respond with only the translation."
        )
        XCTAssertEqual(
            operation.buildPrompt(forSelection: "good morning"),
            "Translate to French:\n\ngood morning\n\nRespond with only the translation."
        )
    }

    func testDisabledPrependIsIgnoredEvenIfTextIsSet() {
        // enabled=false must suppress the text even when it's non-empty — the
        // toggle is the source of truth, not just whether the field has content.
        let operation = TextOperation(prependEnabled: false, prependText: "should not appear")
        XCTAssertEqual(operation.buildPrompt(forSelection: "hello"), "hello")
    }

    func testEmptyPrependTextIsSkippedEvenWhenEnabled() {
        let operation = TextOperation(prependEnabled: true, prependText: "")
        XCTAssertEqual(operation.buildPrompt(forSelection: "hello"), "hello")
    }

    func testHasHotkeyFalseForUnassignedZero() {
        XCTAssertFalse(TextOperation(hotkeyKeyCode: 0).hasHotkey)
    }

    func testHasHotkeyTrueForAnyNonZeroKeyCode() {
        XCTAssertTrue(TextOperation(hotkeyKeyCode: 58).hasHotkey)
    }
}

// MARK: - TextOperationStore (CRUD + conflict detection, no network)

@MainActor
final class TextOperationStoreTests: XCTestCase {
    /// Each test clears the shared store's operations first, since it persists
    /// to disk — tests must not leak operations into each other via that file.
    private func freshStore() -> TextOperationStore {
        let store = TextOperationStore.shared
        for op in store.operations { store.remove(op) }
        return store
    }

    func testAddAppendsAndPersistsInMemory() {
        let store = freshStore()
        let op = TextOperation(name: "Test Op")
        store.add(op)
        XCTAssertEqual(store.operations.map(\.id), [op.id])
    }

    func testUpdateReplacesMatchingOperationById() {
        let store = freshStore()
        var op = TextOperation(name: "Original")
        store.add(op)

        op.name = "Renamed"
        store.update(op)

        XCTAssertEqual(store.operations.first?.name, "Renamed")
        XCTAssertEqual(store.operations.count, 1)
    }

    func testUpdateIsNoOpForUnknownId() {
        let store = freshStore()
        store.add(TextOperation(name: "Kept"))
        let unknown = TextOperation(name: "Not In Store")

        store.update(unknown)

        XCTAssertEqual(store.operations.count, 1)
        XCTAssertEqual(store.operations.first?.name, "Kept")
    }

    func testRemoveDropsOnlyTheMatchingOperation() {
        let store = freshStore()
        let keep = TextOperation(name: "Keep")
        let drop = TextOperation(name: "Drop")
        store.add(keep)
        store.add(drop)

        store.remove(drop)

        XCTAssertEqual(store.operations.map(\.id), [keep.id])
    }

    func testConflictingOperationFindsAnotherOperationWithSameHotkey() {
        let store = freshStore()
        let first = TextOperation(name: "First", hotkeyKeyCode: 58)
        let second = TextOperation(name: "Second", hotkeyKeyCode: 58)
        store.add(first)
        store.add(second)

        let conflict = store.conflictingOperation(forHotkeyKeyCode: 58, excluding: second.id)
        XCTAssertEqual(conflict?.id, first.id)
    }

    func testConflictingOperationExcludesSelf() {
        let store = freshStore()
        let only = TextOperation(name: "Only", hotkeyKeyCode: 58)
        store.add(only)

        XCTAssertNil(store.conflictingOperation(forHotkeyKeyCode: 58, excluding: only.id))
    }

    func testConflictingOperationIgnoresUnassignedZeroKeyCode() {
        let store = freshStore()
        store.add(TextOperation(name: "A", hotkeyKeyCode: 0))
        store.add(TextOperation(name: "B", hotkeyKeyCode: 0))

        XCTAssertNil(store.conflictingOperation(forHotkeyKeyCode: 0, excluding: UUID()))
    }

    func testOperationsReferencingReturnsOnlyMatchingOperations() {
        let store = freshStore()
        let referencing = TextOperation(name: "Uses model A", modelVariantId: "org/Repo/model-a.gguf")
        let other = TextOperation(name: "Uses model B", modelVariantId: "org/Repo/model-b.gguf")
        let unassigned = TextOperation(name: "No model")
        store.add(referencing)
        store.add(other)
        store.add(unassigned)

        let result = store.operationsReferencing(modelVariantId: "org/Repo/model-a.gguf")

        XCTAssertEqual(result.map(\.id), [referencing.id])
    }

    func testOperationsReferencingIncludesOperationsWithoutAHotkey() {
        // An operation without a hotkey yet is still a saved configuration
        // pointing at the model — deleting the model out from under it should
        // still be blocked (see TextModelVariantRow's delete guard), not just
        // for operations that already have a hotkey assigned.
        let store = freshStore()
        let noHotkeyYet = TextOperation(name: "Draft", hotkeyKeyCode: 0, modelVariantId: "org/Repo/model-a.gguf")
        store.add(noHotkeyYet)

        let result = store.operationsReferencing(modelVariantId: "org/Repo/model-a.gguf")

        XCTAssertEqual(result.map(\.id), [noHotkeyYet.id])
    }

    func testOperationsReferencingReturnsEmptyForUnreferencedModel() {
        let store = freshStore()
        store.add(TextOperation(name: "Uses model A", modelVariantId: "org/Repo/model-a.gguf"))

        XCTAssertTrue(store.operationsReferencing(modelVariantId: "org/Repo/model-z.gguf").isEmpty)
    }

    func testMoveReordersOperations() {
        let store = freshStore()
        let a = TextOperation(name: "A")
        let b = TextOperation(name: "B")
        let c = TextOperation(name: "C")
        store.add(a)
        store.add(b)
        store.add(c)

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(store.operations.map(\.name), ["B", "C", "A"])
    }
}
