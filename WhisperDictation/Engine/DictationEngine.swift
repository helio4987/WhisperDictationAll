import Foundation
import Observation
import Cocoa

enum DictationState: String {
    case idle
    case recording
    /// Recording has stopped and the active language's model is still being loaded
    /// (secondary-language cold start, or primary after an idle-unload). Distinct
    /// from `.processing` (model ready, whisper is decoding audio) so the menu bar
    /// can show a different message for "waiting on a multi-second model load" vs
    /// "transcribing your speech".
    case loadingModel
    case processing
    case typing
}

/// Which hotkey/language a recording in progress belongs to. Both hotkeys share the
/// same recording/transcribe state machine — only one dictation is ever active — this
/// just tracks which `WhisperBridge`/vocabulary/language to use for it.
enum ActiveLanguage {
    case primary
    case secondary
}

@Observable
final class DictationEngine {
    private(set) var state: DictationState = .idle
    private(set) var lastTranscription: String = ""
    /// Mirrors `primarySlot`'s actor-isolated `loadState` onto the main thread,
    /// same pattern as `secondaryModelLoadState`. `isModelLoaded`/`modelLoadError`
    /// below are computed from this for external API compatibility.
    private(set) var primaryModelLoadState: LanguageModelSlot<WhisperBridge>.LoadState = .unloaded
    var isModelLoaded: Bool { primaryModelLoadState == .ready }
    var modelLoadError: String? {
        if case .failed(let message) = primaryModelLoadState { return message }
        return nil
    }

    /// Synchronously-readable cache of the primary bridge, mirrored from
    /// `primarySlot` via its `onStateChange` callback (nil except while
    /// `primaryModelLoadState == .ready`). Exists ONLY for
    /// `startLiveSessionIfEnabled()`, which runs synchronously inside
    /// `startRecording()` and can't `await` into the actor without delaying the
    /// start of audio capture. Every other primary code path goes through
    /// `primarySlot.ensureLoaded()` properly (which also resets the idle timer —
    /// this cache does not, and must never be used as a substitute for it).
    private var cachedPrimaryBridge: WhisperBridge?

    /// Last transcription/recording failure surfaced to the user (inference failure,
    /// audio input configuration change). Cleared when a new recording starts and on
    /// the next successful dictation.
    private(set) var transcriptionError: String?

    /// True while the user is holding the hotkey but the toggle-mode threshold hasn't yet fired.
    /// Drives the menu bar hold indicator.
    private(set) var isHoldingForToggle: Bool = false

    /// Mirrors `secondarySlot`'s actor-isolated `loadState` onto the main thread so
    /// SwiftUI (menu bar) can display it without awaiting into the actor on every
    /// render. Updated via `secondarySlot`'s `onStateChange` callback at each real
    /// transition — not polled.
    private(set) var secondaryModelLoadState: LanguageModelSlot<WhisperBridge>.LoadState = .unloaded

    private let audioCapture = AudioCapture()
    private let textInjector = TextInjector()
    private let soundFeedback = SoundFeedback()
    private var hotkeyMonitor: HotkeyMonitor?

    /// Primary (English) dictation, lazily loaded/auto-unloaded via
    /// `LanguageModelSlot` — mirrors `secondarySlot` exactly. Nothing loads at
    /// launch; the first primary hotkey press triggers the same
    /// startRecording()-kicks-off-load/transcribe-step-awaits-it flow secondary
    /// already used, and `primaryIdleTimeoutMinutes` (previously an inert
    /// setting) now actually unloads the model after that many idle minutes.
    private let primarySlot = LanguageModelSlot<WhisperBridge>(
        idleTimeoutMinutes: { AppSettings.shared.primaryIdleTimeoutMinutes },
        load: {
            guard let modelPath = ModelManager.shared.activeModelPath() else {
                throw WhisperError.modelLoadFailed("No model found. Open Settings to download a model.")
            }
            let bridge = try WhisperBridge(modelPath: modelPath)
            await bridge.warmup()
            return bridge
        },
        unload: { bridge in
            bridge.shutdownAndFree()
        }
    )

    /// Secondary-language dictation: a second hotkey, lazily loaded/auto-unloaded
    /// via `LanguageModelSlot`. Push-to-talk only (see class doc) — no toggle mode,
    /// no live dictation for the secondary path in this iteration.
    private var secondaryHotkeyMonitor: HotkeyMonitor?
    private let secondarySlot = LanguageModelSlot<WhisperBridge>(
        idleTimeoutMinutes: { AppSettings.shared.secondaryIdleTimeoutMinutes },
        load: {
            let language = AppSettings.shared.secondaryLanguageCode
            guard !language.isEmpty else {
                throw WhisperError.modelLoadFailed("No secondary language chosen. Pick one in Settings.")
            }
            guard let modelPath = ModelManager.shared.secondaryModelPath() else {
                throw WhisperError.modelLoadFailed("No secondary-language model downloaded")
            }
            let bridge = try WhisperBridge(modelPath: modelPath, language: language)
            await bridge.warmup()
            return bridge
        },
        unload: { bridge in
            bridge.shutdownAndFree()
        }
    )
    /// Which language a recording currently in progress (or being transcribed)
    /// belongs to. Set when a hotkey starts a recording; read by the
    /// transcribe/finish path to pick the right bridge, language, and vocabulary.
    /// Both hotkeys drive the SAME state machine — only one dictation is ever
    /// active — so this is just a routing tag, not a second parallel session.
    private var activeLanguage: ActiveLanguage = .primary

    private let minRecordingDuration: TimeInterval = 0.3
    private var recordingStartTime: Date?

    private var accessibilityPoller: Timer?

    /// Pending toggle-mode hold timer. Cancelled if the user releases the key
    /// before the threshold; cleared after firing.
    private var holdWorkItem: DispatchWorkItem?

    init() {
        let axTrusted = AXIsProcessTrusted()
        fputs("[DictationEngine] Init. Accessibility: \(axTrusted)\n", stderr)
        audioCapture.onConfigurationChange = { [weak self] in
            self?.handleInputConfigurationChange()
        }
        audioCapture.onMaxDurationReached = { [weak self] in
            self?.handleMaxRecordingDurationReached()
        }
        setupHotkeyMonitor()
        hotkeyMonitor?.start()
        setupSecondaryHotkeyMonitor()
        secondaryHotkeyMonitor?.start()
        LaunchAtLoginHelper.reconcile()

        let primary = primarySlot
        let secondary = secondarySlot
        Task { [weak self] in
            await primary.setOnStateChange { [weak self] newState, resource in
                Task { @MainActor in
                    self?.primaryModelLoadState = newState
                    self?.cachedPrimaryBridge = resource
                }
            }
            await secondary.setOnStateChange { [weak self] newState, _ in
                Task { @MainActor in
                    self?.secondaryModelLoadState = newState
                }
            }
        }

        // Free whisper's Metal-backed contexts before exit(): NSApplication's
        // terminate path never runs Swift deinits, and ggml aborts at exit
        // (GGML_ASSERT in ggml_metal_rsets_free) if Metal resources are still
        // alive when its static device registry is destroyed. Posted on the
        // main thread; the engine lives for the whole process, so the observer
        // is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForTermination()
        }

        if !axTrusted {
            startAccessibilityPoller()
        }
    }

    private func startAccessibilityPoller() {
        accessibilityPoller?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                fputs("[DictationEngine] Accessibility granted! Restarting hotkey monitor.\n", stderr)
                timer.invalidate()
                self?.accessibilityPoller = nil
                self?.restartHotkeyMonitor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPoller = timer
    }

    func restartHotkeyMonitor() {
        cancelPendingToggle()
        hotkeyMonitor?.stop()
        setupHotkeyMonitor()
        hotkeyMonitor?.start()
        restartSecondaryHotkeyMonitor()
    }

    // MARK: - Model Loading

    /// Set when `reloadModel()` is requested while a transcription is in flight.
    /// Consumed on the return to idle. Main-actor only.
    private var pendingModelReload = false

    /// Swap the active primary model. If a transcription is mid-flight, unloading
    /// now would strand that task or drop the utterance — the `.recording` state
    /// hasn't captured a bridge reference yet, but `.loadingModel`/`.processing`/
    /// `.typing` did (via `ensureLoaded()`'s return value), and that reference is
    /// used straight through to completion regardless of what happens to the slot
    /// afterward. So only unload immediately when idle; otherwise defer until the
    /// engine returns to idle. The new selection is already persisted in
    /// `AppSettings.selectedModel` by the caller, so the next `ensureLoaded()` —
    /// whenever that happens, deferred or not — picks it up via
    /// `ModelManager.activeModelPath()` reading the (now-changed) setting live.
    /// Called on the main actor.
    func reloadModel() {
        guard state == .idle else {
            pendingModelReload = true
            return
        }
        performModelReload()
    }

    private func performModelReload() {
        pendingModelReload = false
        let slot = primarySlot
        Task { await slot.unload() }
    }

    /// Manually unload a language's model, independent of its idle timer (which
    /// keeps running on its own schedule regardless — this is just an immediate,
    /// user-triggered version of what the timer eventually does on its own).
    /// Safe to call at any time: an in-flight transcription already holds its own
    /// reference to the resource (captured via `ensureLoaded()`'s return value), so
    /// unloading the slot underneath it doesn't interrupt that transcription — only
    /// the *next* `ensureLoaded()` call reloads from disk.
    func unloadModel(for language: ActiveLanguage) {
        let slot = language == .primary ? primarySlot : secondarySlot
        Task { await slot.unload() }
    }

    /// Transition to idle and, if a model reload was deferred while the engine was
    /// busy, perform it now. Main-actor only.
    private func returnToIdle() {
        state = .idle
        drainCancelFlag = nil
        if pendingModelReload { performModelReload() }
    }

    // MARK: - Hotkey

    private func setupHotkeyMonitor() {
        hotkeyMonitor = HotkeyMonitor(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() }
        )
    }

    private func setupSecondaryHotkeyMonitor() {
        secondaryHotkeyMonitor = HotkeyMonitor(
            onKeyDown: { [weak self] in self?.handleSecondaryKeyDown() },
            onKeyUp: { [weak self] in self?.handleSecondaryKeyUp() },
            keyCodeProvider: { AppSettings.shared.secondaryHotkeyKeyCode }
        )
    }

    func startMonitoring() {
        hotkeyMonitor?.start()
        secondaryHotkeyMonitor?.start()
    }

    func stopMonitoring() {
        cancelPendingToggle()
        hotkeyMonitor?.stop()
        secondaryHotkeyMonitor?.stop()
    }

    func restartSecondaryHotkeyMonitor() {
        secondaryHotkeyMonitor?.stop()
        setupSecondaryHotkeyMonitor()
        secondaryHotkeyMonitor?.start()
    }

    // MARK: - Secondary Hotkey Dispatch (push-to-talk only)

    /// Secondary-language dictation is push-to-talk only — no toggle mode, no live
    /// dictation — so its dispatch is a straight subset of the primary push-to-talk
    /// case, not a mirror of the full mode-aware `keyDownAction`/`toggleHoldAction`
    /// machinery above. A key-down while busy cancels, same as primary push-to-talk.
    private func handleSecondaryKeyDown() {
        let isBusy = state == .loadingModel || state == .processing || state == .typing
        if isBusy {
            cancelTranscription()
        } else if state == .idle {
            // No language chosen yet (default is empty — see AppSettings) — stay
            // inert rather than attempting to load a model with an empty Whisper
            // language code. Surface this once per press so it's discoverable
            // without needing to open Settings proactively.
            guard !AppSettings.shared.secondaryLanguageCode.isEmpty else {
                transcriptionError = "Choose a secondary language in Settings before using this hotkey."
                return
            }
            activeLanguage = .secondary
            startRecording()
        }
        // A key-down while already `.recording` (from either hotkey) is ignored —
        // matches primary push-to-talk's "held key generates repeat key-downs" case,
        // which HotkeyMonitor already filters via `isKeyHeld` before calling back.
    }

    private func handleSecondaryKeyUp() {
        guard activeLanguage == .secondary else { return }
        stopRecordingAndTranscribe()
    }

    // MARK: - Hotkey Mode Dispatch

    /// What a key-DOWN should do, given the hotkey mode and current state.
    /// Pure/static so the mode dispatch is unit-testable without hardware.
    ///
    /// Cancel semantics follow each mode's existing intent model:
    /// - Push-to-talk: any key-down is deliberate, so a key-down while transcribing
    ///   cancels the in-flight inference immediately. This handler is only invoked
    ///   for genuine key-down / modifier-press events — the HotkeyMonitor watchdog
    ///   only ever synthesizes key-UP — so a cancel can never come from watchdog
    ///   recovery.
    /// - Toggle: every action requires the deliberate ~1.5s hold, and a quick tap is
    ///   ignored. An instant cancel here would let a stray tap destroy a transcription
    ///   (worst case: the 5-min cap or a device change auto-stopped a long recording,
    ///   the user taps to "stop", and the tap lands during .processing). So toggle
    ///   always goes through `scheduleToggleAction`; the cancel happens only if the
    ///   full hold completes while transcribing (see `toggleHoldAction`).
    enum KeyDownAction: Equatable { case startRecording, scheduleToggle, cancelTranscription }

    static func keyDownAction(mode: AppSettings.HotkeyMode, state: DictationState) -> KeyDownAction {
        switch mode {
        case .pushToTalk:
            let isBusy = state == .loadingModel || state == .processing || state == .typing
            return isBusy ? .cancelTranscription : .startRecording
        case .toggle:
            return .scheduleToggle
        }
    }

    /// What the toggle hold work item should do when it fires after the full hold
    /// duration. Pure/static for unit testing. A completed hold during
    /// .processing/.typing is as deliberate as one during .recording — it cancels
    /// the in-flight transcription (silently; already-typed segments remain).
    enum ToggleHoldAction: Equatable { case startRecording, stopAndTranscribe, cancelTranscription }

    static func toggleHoldAction(state: DictationState) -> ToggleHoldAction {
        switch state {
        case .idle: return .startRecording
        case .recording: return .stopAndTranscribe
        case .loadingModel, .processing, .typing: return .cancelTranscription
        }
    }

    private func handleKeyDown() {
        switch Self.keyDownAction(mode: AppSettings.shared.hotkeyMode, state: state) {
        case .cancelTranscription:
            cancelTranscription()
        case .startRecording:
            activeLanguage = .primary
            startRecording()
        case .scheduleToggle:
            scheduleToggleAction()
        }
    }

    /// Ask the active bridge to abort the running decode. The `transcribe` call then
    /// throws `WhisperError.cancelled`, which the transcription task treats as a silent
    /// reset to idle (no error surfaced). Already-typed segments remain.
    ///
    /// A live session draining after stop cancels differently: it flips its own shared
    /// session flag, which every queued chunk decode polls. `bridge.cancelTranscription()`
    /// would be wrong there — its single-flight `activeCancelFlag` is overwritten as each
    /// queued call enters and cleared as each finishes, so it can target the wrong decode
    /// (or none at all).
    ///
    /// A cancel while `.loadingModel` (secondary cold start still loading) has no
    /// bridge to cancel yet — `stopRecordingAndTranscribe`'s `Task` checks
    /// `cancelRequested` before awaiting the load and exits without transcribing.
    private func cancelTranscription() {
        fputs("[DictationEngine] Cancel requested during \(state.rawValue) (\(activeLanguage)).\n", stderr)
        if let liveFlagForDrain = drainCancelFlag {
            liveFlagForDrain.cancel()
        } else {
            cancelRequested = true
            let slot = activeLanguage == .primary ? primarySlot : secondarySlot
            Task { await slot.currentResource?.cancelTranscription() }
        }
    }

    /// Set when a cancel arrives while `.loadingModel` — there's no bridge yet to
    /// call `cancelTranscription()` on. Checked once the load resolves so the
    /// engine drops straight to idle instead of transcribing a cancelled recording.
    /// Cleared at the start of every new recording.
    private var cancelRequested = false

    private func handleKeyUp() {
        switch AppSettings.shared.hotkeyMode {
        case .pushToTalk:
            stopRecordingAndTranscribe()
        case .toggle:
            cancelPendingToggle()
        }
    }

    /// Toggle mode: schedule a deferred start/stop after `toggleHoldDuration` seconds.
    /// If the user releases the key first, `cancelPendingToggle()` aborts the work item.
    private func scheduleToggleAction() {
        cancelPendingToggle()
        isHoldingForToggle = true
        // Capture the duration ONCE at schedule time. We pass this same value to the
        // trim path so the audio trimmed at stop matches what was actually waited out,
        // even if the slider value changes between schedule and stop.
        let duration = AppSettings.shared.toggleHoldDuration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isHoldingForToggle = false
            self.holdWorkItem = nil
            // Defensive: settings may have changed mid-hold.
            guard AppSettings.shared.hotkeyMode == .toggle else { return }
            switch Self.toggleHoldAction(state: self.state) {
            case .startRecording:
                self.startRecording()
            case .stopAndTranscribe:
                self.stopRecordingAndTranscribe(trimTrailingSeconds: duration)
            case .cancelTranscription:
                self.cancelTranscription()
            }
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func cancelPendingToggle() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if isHoldingForToggle { isHoldingForToggle = false }
    }

    // MARK: - Prompt Assembly

    /// Whisper's initial_prompt is capped at ~1024 tokens (~750 words). Exceeding it
    /// triggers `whisper_tokenize: too many resulting tokens` and degrades accuracy
    /// (see CLAUDE.md). We budget 700 words as a safe margin.
    static let promptWordBudget = 700

    /// Builds the whisper initial_prompt from the base vocabulary prompt plus the
    /// user's custom terms, staying within `promptWordBudget` words. The base prompt
    /// is truncated first if it alone exceeds the budget; custom terms then fill any
    /// remaining word budget. Pure/static so it is unit-testable without the engine.
    ///
    /// - Parameter transcriptTail: text already committed in this dictation, used by
    ///   live mode so each chunk decodes with the preceding words as context. Empty
    ///   (the default) leaves the prompt byte-identical to the non-live build.
    static func buildPrompt(base: String, customTerms: [String], transcriptTail: String = "") -> String {
        let baseWords = base.split(separator: " ")
        let cappedBase = baseWords.count > promptWordBudget
            ? baseWords.prefix(promptWordBudget).joined(separator: " ")
            : base

        let termBudget = max(0, promptWordBudget - baseWords.count)
        let termsToAdd = Array(customTerms.prefix(termBudget))
        let withTerms = termsToAdd.isEmpty
            ? cappedBase
            : cappedBase + ", " + termsToAdd.joined(separator: ", ")

        // Committed-transcript tail: budgeted by ACTUAL word count (terms above
        // deliberately keep their historical one-unit-each accounting), capped
        // at 50 words, appended last — closest to the decode.
        let tailWords = transcriptTail.split(separator: " ")
        let usedWords = min(baseWords.count, promptWordBudget) + termsToAdd.count
        let tailBudget = min(50, max(0, promptWordBudget - usedWords))
        guard tailBudget > 0, !tailWords.isEmpty else { return withTerms }
        return withTerms + " " + tailWords.suffix(tailBudget).joined(separator: " ")
    }

    // MARK: - Recording Flow

    /// Both languages load lazily, symmetrically: neither has its model loaded at
    /// launch. A cold hotkey press starts capturing audio immediately while the
    /// relevant `LanguageModelSlot.ensureLoaded()` kicks off in the background —
    /// the transcribe step (`stopRecordingAndTranscribe`) awaits it — so the first
    /// words spoken are never lost to a multi-second model load.
    private func startRecording() {
        guard state == .idle else { return }

        transcriptionError = nil
        cancelRequested = false
        state = .recording
        recordingStartTime = Date()
        soundFeedback.playStartSound()

        // Fire-and-forget: kick off the load now so it's as far along as possible
        // by the time the user releases the key. Errors surface at the transcribe
        // step via ensureLoaded()'s throw, not here.
        let slot = activeLanguage == .primary ? primarySlot : secondarySlot
        Task {
            _ = try? await slot.ensureLoaded()
        }

        // Live dictation (commit-on-pause streaming) is primary-only for now.
        let live = activeLanguage == .primary && startLiveSessionIfEnabled()
        fputs("[DictationEngine] Recording (live: \(live), language: \(activeLanguage))\n", stderr)

        do {
            try audioCapture.startRecording()
        } catch {
            fputs("[DictationEngine] Failed to start recording: \(error)\n", stderr)
            teardownLiveSession()
            state = .idle
        }
    }

    /// - Parameter trimTrailingSeconds: number of seconds to trim from the end of the audio
    ///   buffer before transcription. Used by toggle mode to discard the silent hold-to-stop
    ///   interval (otherwise Whisper hallucinates trailing punctuation/filler from the silence).
    ///   Push-to-talk passes 0.
    private func stopRecordingAndTranscribe(trimTrailingSeconds: TimeInterval = 0) {
        guard state == .recording else { return }
        if isLiveSession {
            stopLiveSession(trimTrailingSeconds: trimTrailingSeconds)
            return
        }

        let audioBuffer = audioCapture.stopRecording(trimTrailingSeconds: trimTrailingSeconds)
        soundFeedback.playStopSound()

        // Check minimum duration
        if let start = recordingStartTime,
           Date().timeIntervalSince(start) < minRecordingDuration {
            returnToIdle()
            return
        }

        guard !audioBuffer.isEmpty else {
            returnToIdle()
            return
        }

        let language = activeLanguage
        // Either language's model may not be loaded/ready yet (lazy load kicked
        // off in startRecording()) — that's `.loadingModel`, distinct from
        // `.processing` (model ready, whisper actively decoding).
        state = .loadingModel

        let promptBase = language == .secondary
            ? AppSettings.shared.effectiveSecondaryVocabularyBase
            : AppSettings.shared.vocabularyPrompt
        let prompt = Self.buildPrompt(
            base: promptBase,
            customTerms: AppSettings.shared.customTerms
        )
        let injector = self.textInjector
        let feedback = self.soundFeedback
        let primarySlot = self.primarySlot
        let secondarySlot = self.secondarySlot

        Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for all enqueued typing to drain, then surface the result and go idle.
            // injector.flush() blocks this cooperative-pool thread — but it is only a
            // wait (typing itself runs on the injector's own queue), which is the same
            // accepted tradeoff the old synchronous transcribe made.
            func finish(transcript: String?, error: String?) async {
                injector.flush()
                await MainActor.run { [weak self] in
                    if let error { self?.transcriptionError = error }
                    if let transcript, !transcript.isEmpty {
                        self?.lastTranscription = transcript
                        self?.transcriptionError = nil
                    }
                    feedback.playDoneSound()
                    self?.returnToIdle()
                }
            }

            let slot = language == .primary ? primarySlot : secondarySlot
            let resolvedBridge: WhisperBridge
            do {
                resolvedBridge = try await slot.ensureLoaded()
            } catch {
                fputs("[DictationEngine] \(language) model load failed: \(error)\n", stderr)
                let label = language == .primary ? "primary" : "secondary language"
                await finish(transcript: nil, error: "Couldn't load \(label) model: \(error.localizedDescription)")
                return
            }
            // A cancel that arrived while still loading has no bridge to target —
            // honor it now instead of transcribing a recording the user aborted.
            let wasCancelled = await MainActor.run { [weak self] in self?.cancelRequested ?? false }
            if wasCancelled {
                fputs("[DictationEngine] \(language) recording cancelled during model load.\n", stderr)
                await finish(transcript: nil, error: nil)
                return
            }

            await MainActor.run { [weak self] in
                self?.state = .typing
            }

            // Stream: correct and type each segment as it's decoded. Segments are
            // enqueued to the injector (non-blocking) and accumulated for the final
            // lastTranscription. The collector is written only from the whisper queue
            // (segment callbacks are serial) and read after `await` returns, which
            // happens-after all writes — so @unchecked Sendable is sound.
            let collected = TranscriptCollector()
            do {
                _ = try await resolvedBridge.transcribe(audioBuffer: audioBuffer, prompt: prompt) { segment in
                    let corrected = TextCorrector.shared.correct(segment)
                    // Never log transcribed content — it's the user's private dictation.
                    injector.type(text: collected.joinAndAppend(corrected))
                }
            } catch let error as WhisperError where error.isCancellation {
                // User-intended cancel: reset to idle without surfacing an error.
                // Any segments already decoded were already typed — that's acceptable.
                fputs("[DictationEngine] Transcription cancelled by user.\n", stderr)
                await finish(transcript: nil, error: nil)
                return
            } catch {
                fputs("[DictationEngine] Transcription failed: \(error)\n", stderr)
                await finish(transcript: nil, error: error.localizedDescription)
                return
            }

            await finish(transcript: collected.text, error: nil)
        }
    }

    // MARK: - Live Dictation Session

    private enum LiveWorkItem {
        case chunk([Float])
        case residual([Float])
    }

    /// Residual minimum is SAMPLE COUNT (≈0.3 s @16 kHz) — the wall-clock
    /// minRecordingDuration check measures the whole session and would always
    /// pass after a live session. Distinct from VADChunkGate.minSpeechWindows,
    /// which gates chunks by accumulated speech, not raw length.
    static let residualMinSeconds = 0.3
    static func residualMeetsMinimum(sampleCount: Int) -> Bool {
        Double(sampleCount) >= 16000 * residualMinSeconds
    }

    /// Stop-time termination (append-only): a session whose committed text
    /// never ended a sentence gets exactly one period at stop. Chunks are
    /// never auto-terminated (a "final chunk" is unknowable at commit time —
    /// toggle mode's hold-to-stop guarantees the last utterance commits as an
    /// intermediate chunk).
    static func needsTerminalPeriod(committed: String) -> Bool {
        guard let last = committed.last else { return false }
        return !".!?".contains(last)
    }

    private var liveSegmenter: VADSegmenter?
    private var liveContinuation: AsyncStream<LiveWorkItem>.Continuation?
    private var liveSessionFlag: CancellationFlag?

    /// The session flag kept alive for the drain phase (stop → consumer finish),
    /// after the main-actor session references are cleared. This is what a cancel
    /// during .processing/.typing flips. Cleared in `returnToIdle()`.
    private var drainCancelFlag: CancellationFlag?

    private var isLiveSession: Bool { liveSegmenter != nil }

    /// Engine-side guard (evaluated per session): the setting stores intent;
    /// live runs only when the VAD model is actually on disk, resolved fresh
    /// (WhisperBridge's cached copy from its own init must not be reused).
    private func startLiveSessionIfEnabled() -> Bool {
        guard AppSettings.shared.liveDictationEnabled,
              let vadPath = ModelManager.shared.vadModelPath(),
              let bridge = cachedPrimaryBridge else { return false }
        do {
            let segmenter = try VADSegmenter(vadModelPath: vadPath)
            let sessionFlag = CancellationFlag()
            let (stream, continuation) = AsyncStream.makeStream(of: LiveWorkItem.self)

            liveSegmenter = segmenter
            liveContinuation = continuation
            liveSessionFlag = sessionFlag

            // Invoked synchronously on the segmenter's queue, so it must touch
            // NO main-actor state: the continuation is captured by value, never
            // read back through `self.liveContinuation`. `yield` is thread-safe
            // and non-blocking, and the stop path's `finishAndCollectResidual()`
            // barrier happens-after every commit's yield — so every committed
            // chunk is in the stream before the residual and `finish()`, and none
            // can be orphaned by the stop path clearing `liveContinuation`.
            segmenter.onChunk = { chunk in continuation.yield(.chunk(chunk)) }
            audioCapture.onSamples = { samples in segmenter.append(samples) }
            segmenter.start()
            runLiveConsumer(stream: stream, bridge: bridge, sessionFlag: sessionFlag)
            return true
        } catch {
            fputs("[DictationEngine] VAD init failed — falling back to non-live: \(error)\n", stderr)
            return false
        }
    }

    /// ONE sequential consumer: strict output order and a natural drain point
    /// fall out of the single loop (per-chunk Tasks would guarantee neither).
    /// Owns the whole post-stream finish: terminal period, flush, done sound,
    /// lastTranscription, returnToIdle — unconditionally, even when the
    /// residual was empty (the common case; the non-live empty shortcut must
    /// never be taken here or queued typing gets stranded).
    private func runLiveConsumer(
        stream: AsyncStream<LiveWorkItem>,
        bridge: WhisperBridge,
        sessionFlag: CancellationFlag
    ) {
        let injector = self.textInjector
        let feedback = self.soundFeedback
        let collected = TranscriptCollector()
        let slot = primarySlot

        Task.detached(priority: .userInitiated) { [weak self] in
            var surfacedError: String?

            for await item in stream {
                if sessionFlag.isCancelled && surfacedError == nil {
                    continue   // user cancel during drain: skip remaining work silently
                }
                let (samples, isResidual): ([Float], Bool)
                switch item {
                case .chunk(let s): (samples, isResidual) = (s, false)
                case .residual(let s): (samples, isResidual) = (s, true)
                }
                guard surfacedError == nil else { continue }  // failure: drain and discard

                // Re-touch the slot before every chunk so its idle timer resets
                // for the duration of this session — a multi-minute live session
                // must never have its model unloaded out from under `bridge`
                // (captured once, above, and reused directly for the whole
                // session rather than re-resolved per chunk). ensureLoaded() is
                // a cheap no-op here since the resource is already `.ready`.
                _ = try? await slot.ensureLoaded()

                let prompt = Self.buildPrompt(
                    base: AppSettings.shared.vocabularyPrompt,
                    customTerms: AppSettings.shared.customTerms,
                    transcriptTail: collected.text
                )
                do {
                    _ = try await bridge.transcribe(
                        audioBuffer: samples,
                        prompt: prompt,
                        cancelFlag: sessionFlag,
                        vad: isResidual   // chunks are pre-trimmed; residual is raw
                    ) { segment in
                        let context = CorrectionContext(
                            atSentenceStart: collected.atSentenceStart,
                            appendPeriod: false   // termination is the stop-time rule
                        )
                        let corrected = TextCorrector.shared.correct(segment, context: context)
                        guard !corrected.isEmpty else { return }
                        injector.type(text: collected.joinAndAppend(corrected))
                    }
                } catch let error as WhisperError where error.isCancellation {
                    continue   // silent: user cancel, or cascade after a failure
                } catch {
                    fputs("[DictationEngine] Live decode failed: \(error)\n", stderr)
                    surfacedError = error.localizedDescription
                    sessionFlag.cancel()   // abort the queue; cascade drains silently above
                }
            }

            // Stream closed: stop-time finish (unconditional drain + flush).
            if surfacedError == nil, Self.needsTerminalPeriod(committed: collected.text) {
                injector.type(text: ".")
            }
            injector.flush()

            let finalError = surfacedError
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let finalError {
                    self.transcriptionError = finalError
                } else if !collected.text.isEmpty {
                    var transcript = collected.text
                    if Self.needsTerminalPeriod(committed: transcript) { transcript += "." }
                    self.lastTranscription = transcript
                    self.transcriptionError = nil
                }
                feedback.playDoneSound()
                self.returnToIdle()
            }
        }
    }

    /// Live stop: discard the full capture buffer (its speech was already
    /// committed chunk-by-chunk), collect the segmenter's residual, and close
    /// the stream — the consumer owns everything after this point, including
    /// returnToIdle. State moves to .processing/.typing to cover the drain.
    private func stopLiveSession(trimTrailingSeconds: TimeInterval) {
        audioCapture.onSamples = nil
        _ = audioCapture.stopRecording()   // tap removed; buffer intentionally discarded
        soundFeedback.playStopSound()
        recordingStartTime = nil

        var residual = liveSegmenter?.finishAndCollectResidual() ?? []
        if trimTrailingSeconds > 0 {
            let toTrim = Int(trimTrailingSeconds * 16000)
            residual = residual.count > toTrim ? Array(residual.dropLast(toTrim)) : []
        }

        state = .processing
        if Self.residualMeetsMinimum(sampleCount: residual.count) {
            state = .typing
            liveContinuation?.yield(.residual(residual))
        }
        liveContinuation?.finish()   // consumer drains, flushes, returns to idle
        drainCancelFlag = liveSessionFlag
        clearLiveSessionReferences()
    }

    /// Drop main-actor references to the session. The consumer task holds its
    /// own copies (stream, flag, collector) and finishes independently.
    private func clearLiveSessionReferences() {
        liveSegmenter = nil
        liveContinuation = nil
        liveSessionFlag = nil
    }

    /// App is terminating (main thread; exit() follows, skipping all deinits).
    /// Stop capture, tear down any live session, and free the whisper context
    /// explicitly via `shutdownAndFree()` — ggml's at-exit Metal assert fires if
    /// it is still alive, and refcounted deinit cannot be relied on here: a
    /// live-session consumer task holds its own bridge reference and finishes
    /// on the main actor, which is blocked in this very handler. The segmenter's
    /// VAD context is CPU-only (not implicated in the Metal assert); its release
    /// through teardown stays best-effort.
    private func prepareForTermination() {
        fputs("[DictationEngine] Terminating — freeing whisper contexts\n", stderr)
        audioCapture.onSamples = nil
        if audioCapture.isRecording { _ = audioCapture.stopRecording() }
        // Cancel BEFORE the teardown drain so chunks committed during the drain
        // abort instead of starting fresh decodes (same rule as teardownLiveSession).
        liveSessionFlag?.cancel()
        teardownLiveSession()

        // Both slots' `unload()` (an actor method, so only callable async) must
        // complete before this handler returns — NSApplication's terminate path
        // calls exit() right after, skipping Swift deinits, and ggml's at-exit
        // Metal assert (GGML_ASSERT in ggml_metal_rsets_free) fires if either
        // context's Metal resources are still alive when its static device
        // registry is destroyed. `prepareForTermination()` itself is synchronous
        // (called from a `willTerminateNotification` observer), so block on a
        // semaphore rather than downgrading to fire-and-forget best-effort —
        // both languages get the same deterministic guarantee the primary bridge
        // had before secondary-language support existed.
        let primary = primarySlot
        let secondary = secondarySlot
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await primary.unload()
            await secondary.unload()
            semaphore.signal()
        }
        semaphore.wait()
        fputs("[DictationEngine] Whisper contexts freed\n", stderr)
    }

    /// Full teardown for paths where the consumer must ALSO stop (start
    /// failure, config change): close the stream so the consumer's finish
    /// block runs, then clear references.
    private func teardownLiveSession() {
        audioCapture.onSamples = nil
        _ = liveSegmenter?.finishAndCollectResidual()   // discard residual
        liveContinuation?.finish()
        // Same hand-off as stopLiveSession: a cancel arriving during this drain
        // must flip the session flag deterministically. Without it the cancel
        // falls through to the bridge's single-flight flag, which only happens
        // to work while a chunk decode is in flight. Cleared in returnToIdle().
        drainCancelFlag = liveSessionFlag
        clearLiveSessionReferences()
    }

    /// Invoked (on the audio tap thread) when a recording reaches the maximum
    /// duration cap. Route it through the normal stop-and-transcribe path on the main
    /// actor so what was captured is still transcribed, and surface a brief,
    /// non-error explanation. `stopRecordingAndTranscribe()` leaves any transcript we
    /// produce intact (it clears the status on success once text is typed).
    private func handleMaxRecordingDurationReached() {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            fputs("[DictationEngine] Max recording duration reached — transcribing what was captured.\n", stderr)
            self.stopRecordingAndTranscribe()
            // Set after stop so it isn't cleared by startRecording's reset; visible
            // during processing until the successful transcript clears it.
            self.transcriptionError = "Reached the \(Int(AudioCapture.maxRecordingSeconds / 60))-minute recording limit. Transcribing what was captured."
        }
    }

    /// Invoked (on an arbitrary thread) when the audio engine's configuration
    /// changes mid-recording — a device being unplugged, a newly plugged-in device
    /// becoming default, or a sample-rate change. All invalidate the running tap,
    /// so stop cleanly and surface the reason. No auto-restart in this phase.
    private func handleInputConfigurationChange() {
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            if self.isLiveSession {
                fputs("[DictationEngine] Audio input changed during live session — stopping.\n", stderr)
                self.audioCapture.onSamples = nil
                _ = self.audioCapture.stopRecording()
                self.soundFeedback.playStopSound()
                self.recordingStartTime = nil
                self.state = .processing        // consumer's finish returns to idle
                self.teardownLiveSession()      // residual discarded; committed text remains
                self.transcriptionError = "Audio input changed. Recording stopped."
                return
            }
            fputs("[DictationEngine] Audio input configuration changed during recording — stopping.\n", stderr)
            _ = self.audioCapture.stopRecording()
            self.soundFeedback.playStopSound()
            self.recordingStartTime = nil
            self.returnToIdle()
            self.transcriptionError = "Audio input changed. Recording stopped."
        }
    }
}

/// Accumulates corrected transcript segments during a streaming transcription.
/// Appended to only from the whisper decode queue (segment callbacks are delivered
/// serially) and read once after the transcribe `await` returns, which happens-after
/// all appends. That ordering makes the unsynchronized access sound; hence
/// `@unchecked Sendable`.
///
/// The live consumer extends that ordering rather than breaking it: one collector is
/// shared across a session's sequential decodes, and its reads (`text` for the next
/// chunk's prompt tail and the finish block; `atSentenceStart` inside a later decode's
/// segment callback) are still never concurrent with a write. Each `await transcribe`
/// in the single consumer loop is a happens-after edge over that decode's whisper-queue
/// writes, and the next decode — the only other writer — starts only after that await
/// returns. So at any instant exactly one thread touches `text`.
final class TranscriptCollector: @unchecked Sendable {
    private(set) var text: String = ""

    /// True when the next appended segment begins a sentence: nothing has
    /// been collected yet, or the collected text ends in terminal punctuation.
    var atSentenceStart: Bool {
        guard let last = text.last else { return true }
        return ".!?".contains(last)
    }

    /// Returns `segment` as it should be typed — with a leading space when
    /// joining onto already-collected text — and appends that same piece to
    /// `text`, so the typed stream and the collected transcript cannot drift.
    /// The separator is applied AFTER correction: the corrector trims leading
    /// whitespace, so a pre-correction separator would be eaten.
    func joinAndAppend(_ segment: String) -> String {
        let piece = text.isEmpty ? segment : " " + segment
        text += piece
        return piece
    }
}
