import Foundation
import Cocoa

/// What a Custom Operation hotkey press is currently doing, surfaced for a
/// future menu bar indicator (not wired into the UI yet — this milestone
/// focuses on the engine itself). Deliberately simpler than
/// `DictationState`: there's no `.recording` phase since a selection is
/// captured instantly rather than streamed over time.
enum CustomOperationState: Equatable {
    case idle
    case capturingSelection
    case loadingModel
    case generating
    case typing
}

/// Push-to-talk only, same scope decision as secondary-language dictation:
/// press the hotkey, the current text selection is captured, run through the
/// operation's model + prompt framing, and the result replaces the
/// selection — one hotkey press runs the operation to completion, there's no
/// hold-to-record phase (there's nothing to record; the selection already
/// exists in the frontmost app before the key is even pressed).
///
/// Owns one `HotkeyMonitor` per operation that currently has a hotkey
/// assigned, created/torn down as operations are added, edited, or removed
/// (via `TextOperationStore.onOperationsChanged`). Only one operation can run
/// at a time — a press while another operation is running is ignored, same
/// "only one dictation session active" rule `DictationEngine` already
/// enforces for its two hotkeys.
@Observable
@MainActor
final class CustomOperationEngine {
    private(set) var state: CustomOperationState = .idle
    /// Name of the operation currently running, if any — lets a future menu
    /// bar indicator say e.g. "Running Translate to PT..." instead of a bare
    /// state name.
    private(set) var runningOperationName: String?
    private(set) var lastError: String?

    private let textInjector: TextInjector
    private let soundFeedback: SoundFeedback
    private var hotkeyMonitors: [UUID: HotkeyMonitor] = [:]
    private var runningOperationId: UUID?

    init(textInjector: TextInjector, soundFeedback: SoundFeedback) {
        self.textInjector = textInjector
        self.soundFeedback = soundFeedback
        rebuildHotkeyMonitors()
        TextOperationStore.shared.onOperationsChanged = { [weak self] in
            self?.rebuildHotkeyMonitors()
        }
    }

    /// Recreates every operation's `HotkeyMonitor` from scratch against the
    /// current list. Simpler and safer than diffing old vs. new (add one,
    /// remove one, rename one, change a hotkey — all collapse to the same
    /// "throw everything away and rebuild" path) and this only runs on
    /// explicit user edits in Settings, not on any hot path.
    private func rebuildHotkeyMonitors() {
        for monitor in hotkeyMonitors.values { monitor.stop() }
        hotkeyMonitors.removeAll()

        for operation in TextOperationStore.shared.operations where operation.hasHotkey {
            let operationId = operation.id
            let monitor = HotkeyMonitor(
                onKeyDown: { [weak self] in self?.handleHotkeyDown(operationId: operationId) },
                onKeyUp: { },
                keyCodeProvider: { [weak self] in
                    // Read live from the store (not the captured `operation`)
                    // so a later hotkey edit without a full rebuild — there
                    // isn't one today, but this is the same "read live"
                    // guard HotkeyMonitor's own doc comment calls out for
                    // Settings changes — can never leave a monitor watching
                    // a stale key code.
                    self?.operation(forId: operationId)?.hotkeyKeyCode ?? 0
                }
            )
            monitor.start()
            hotkeyMonitors[operationId] = monitor
        }
    }

    private func operation(forId id: UUID) -> TextOperation? {
        TextOperationStore.shared.operations.first { $0.id == id }
    }

    func stopAllMonitors() {
        for monitor in hotkeyMonitors.values { monitor.stop() }
        hotkeyMonitors.removeAll()
    }

    // MARK: - Running an operation

    private func handleHotkeyDown(operationId: UUID) {
        guard state == .idle else {
            fputs("[CustomOperationEngine] Ignoring hotkey press — an operation is already running.\n", stderr)
            return
        }
        guard let operation = operation(forId: operationId) else { return }
        guard let modelVariantId = operation.modelVariantId,
              let variant = TextModelManager.shared.downloadedVariants.first(where: { $0.id == modelVariantId })
        else {
            lastError = "\"\(operation.name)\" has no model assigned. Open Settings to pick one."
            return
        }

        runningOperationId = operationId
        runningOperationName = operation.name
        lastError = nil
        state = .capturingSelection

        Task {
            await run(operation: operation, variant: variant)
        }
    }

    private func run(operation: TextOperation, variant: TextModelVariant) async {
        defer {
            state = .idle
            runningOperationId = nil
            runningOperationName = nil
        }

        let selection: String
        do {
            selection = try await SelectionCapture.captureSelection()
        } catch {
            fputs("[CustomOperationEngine] Selection capture failed: \(error)\n", stderr)
            lastError = error.localizedDescription
            soundFeedback.playStopSound()
            return
        }

        state = .loadingModel
        let modelPath = TextModelManager.shared.localPath(for: variant).path
        let bridge: TextGenerationBridge
        do {
            bridge = try await TextGenerationManager.shared.bridge(forModelPath: modelPath)
        } catch {
            fputs("[CustomOperationEngine] Model load failed: \(error)\n", stderr)
            lastError = "Couldn't load \"\(operation.name)\"'s model: \(error.localizedDescription)"
            soundFeedback.playStopSound()
            return
        }

        // A newer press of a DIFFERENT operation (or this one again) could in
        // principle have changed `runningOperationId` if the single-flight
        // guard in `handleHotkeyDown` were ever bypassed — it isn't today,
        // but checking here costs nothing and keeps this method correct even
        // if that guard's shape changes later.
        guard runningOperationId == operation.id else { return }

        state = .generating
        let prompt = operation.buildPrompt(forSelection: selection)
        let result: String
        do {
            result = try await bridge.generate(prompt: prompt)
        } catch {
            fputs("[CustomOperationEngine] Generation failed: \(error)\n", stderr)
            lastError = "\"\(operation.name)\" failed: \(error.localizedDescription)"
            soundFeedback.playStopSound()
            return
        }

        guard !result.isEmpty else {
            lastError = "\"\(operation.name)\" produced no output."
            soundFeedback.playStopSound()
            return
        }

        state = .typing
        // The selection captured above is still selected in the frontmost
        // app (Cmd+C never changes selection state) — typing now replaces it
        // in place, the same behavior as selecting text and typing over it
        // in any standard text field. No explicit delete step is needed.
        textInjector.type(text: result)
        textInjector.flush()
        soundFeedback.playDoneSound()
    }
}
