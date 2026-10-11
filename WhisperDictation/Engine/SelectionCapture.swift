import Cocoa
import CoreGraphics

/// Captures the current text selection in the frontmost app by simulating
/// Cmd+C and reading the result from the clipboard, then restores whatever
/// was on the clipboard beforehand — the same approach launcher-style tools
/// (Alfred, Raycast) use, since there is no generic cross-app "give me the
/// current selection" API: the Accessibility API's `AXSelectedText` works in
/// some apps but not reliably in Electron apps, web views, or terminals.
///
/// This silently overwrites and restores the system clipboard for the
/// duration of one capture. That's a real, if brief, side effect worth
/// stating plainly rather than hiding: another app polling the clipboard
/// during that window would observe the selected text transiently. No
/// existing code path in this app reads the clipboard that way, and the
/// restore happens as soon as the read completes.
enum SelectionCapture {
    enum CaptureError: LocalizedError {
        case noSelection
        case accessibilityNotTrusted

        var errorDescription: String? {
            switch self {
            case .noSelection:
                return "No text is selected."
            case .accessibilityNotTrusted:
                return "Accessibility access is required to read the selected text."
            }
        }
    }

    /// How long to wait, after sending Cmd+C, for the frontmost app to update
    /// the clipboard before giving up. 500ms covers normal apps comfortably;
    /// a slower/unresponsive app surfaces as `.noSelection` rather than
    /// hanging the operation indefinitely.
    private static let copyTimeout: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 0.02

    /// Captures the current selection and restores the clipboard's prior
    /// contents before returning (success or failure). Must be called from
    /// the main actor — `CGEvent.post` and `NSPasteboard` are UI-thread
    /// operations, same expectation as `HotkeyMonitor`'s callbacks.
    @MainActor
    static func captureSelection() async throws -> String {
        guard AXIsProcessTrusted() else {
            throw CaptureError.accessibilityNotTrusted
        }

        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousContents = PasteboardSnapshot(pasteboard: pasteboard)

        defer { previousContents.restore(to: pasteboard) }

        sendCopyKeystroke()

        let deadline = Date().addingTimeInterval(copyTimeout)
        while pasteboard.changeCount == previousChangeCount, Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        guard pasteboard.changeCount != previousChangeCount,
              let copiedText = pasteboard.string(forType: .string),
              !copiedText.isEmpty
        else {
            throw CaptureError.noSelection
        }

        return copiedText
    }

    /// Simulates physically pressing Cmd+C — a key-down for Cmd, a key-down
    /// and key-up for "C", then releasing Cmd — posted to the HID event tap
    /// so the frontmost app (not this one) receives it, same tap level
    /// `TextInjector` already types into.
    private static func sendCopyKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode: CGKeyCode = 55
        let cKeyCode: CGKeyCode = 8

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
              let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else { return }

        cDown.flags = .maskCommand
        cUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        cDown.post(tap: .cghidEventTap)
        cUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
    }
}

/// Captures every representation on the pasteboard (not just plain text) so
/// restoring afterward doesn't silently downgrade e.g. a copied image, rich
/// text, or file reference to plain text — whatever was there before a
/// Custom Operation ran comes back exactly as it was.
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var typesAndData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typesAndData[type] = data
                }
            }
            return typesAndData
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let writers: [NSPasteboardWriting] = items.map { typesAndData in
            let writer = PasteboardDataWriter(typesAndData: typesAndData)
            return writer
        }
        pasteboard.writeObjects(writers)
    }
}

/// Minimal `NSPasteboardWriting` adapter that replays a captured
/// type→data map verbatim, so `PasteboardSnapshot.restore` can write back
/// multi-representation items without re-deriving them from a concrete type
/// (there's no public API to write a raw `[type: Data]` map directly).
private final class PasteboardDataWriter: NSObject, NSPasteboardWriting {
    private let typesAndData: [NSPasteboard.PasteboardType: Data]

    init(typesAndData: [NSPasteboard.PasteboardType: Data]) {
        self.typesAndData = typesAndData
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        Array(typesAndData.keys)
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        typesAndData[type]
    }
}
