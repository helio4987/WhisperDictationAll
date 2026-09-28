import Foundation

/// Load lifecycle for one language's model resource, independent of whichever other
/// slot(s) exist. Generic over `Resource` (in production, `WhisperBridge`) purely so
/// the load/unload/idle-timeout state machine can be unit-tested without touching
/// whisper.cpp or downloading real model files — tests inject a fake `Resource` and
/// fake load/unload closures with a fake or accelerated clock.
///
/// Lifecycle:
/// - `.unloaded` — nothing in memory.
/// - `.loading` — a load is in flight. Concurrent `ensureLoaded()` calls collapse
///   into the same in-flight load rather than starting a second one.
/// - `.ready` — `resource` is non-nil and usable.
/// - `.failed(message)` — the most recent load attempt threw; `resource` is nil.
///
/// Idle unload: every successful `ensureLoaded()` (i.e. every time the resource is
/// actually used) resets an idle timer. If the timer fires — no use for
/// `idleTimeoutMinutes()` minutes — the resource is unloaded automatically.
/// `idleTimeoutMinutes() == 0` disables auto-unload entirely.
///
/// An `actor`: concurrent `ensureLoaded()` callers are properly serialized by the
/// runtime, so the "collapse into one load" guarantee is real rather than a race
/// (a plain class here would let two concurrent callers both observe `loadingTask
/// == nil` and both start a load — verified by
/// `LanguageModelSlotTests.testConcurrentEnsureLoadedCallsCollapseIntoOneLoad`).
actor LanguageModelSlot<Resource> {
    enum LoadState: Equatable {
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .unloaded
    private(set) var resource: Resource?

    /// Async-callable alias for `resource`, for call sites that only have `async`
    /// access to the actor (e.g. cancelling an in-flight decode without going
    /// through `ensureLoaded()`, which would trigger a load if none is active).
    var currentResource: Resource? { resource }

    /// Read live (not captured once) so a Settings change to the idle timeout takes
    /// effect on the next reschedule without recreating the slot.
    private let idleTimeoutMinutes: () -> Double

    private let load: () async throws -> Resource
    private let unloadResource: (Resource) -> Void

    /// Injectable clock/scheduler seam for tests. Production uses a real `Timer`
    /// scheduled on the main run loop; tests can substitute a fast or
    /// manually-fired scheduler.
    private let scheduleIdleUnload: (_ afterSeconds: TimeInterval, _ fire: @escaping () -> Void) -> IdleTimerHandle

    private var loadingTask: Task<Resource, Error>?
    private var idleTimerHandle: IdleTimerHandle?

    /// Opaque cancel handle for a scheduled idle-unload callback.
    struct IdleTimerHandle {
        let cancel: () -> Void
    }

    init(
        idleTimeoutMinutes: @escaping () -> Double,
        load: @escaping () async throws -> Resource,
        unload unloadResource: @escaping (Resource) -> Void,
        scheduleIdleUnload: @escaping (_ afterSeconds: TimeInterval, _ fire: @escaping () -> Void) -> IdleTimerHandle = LanguageModelSlot.defaultScheduler
    ) {
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.load = load
        self.unloadResource = unloadResource
        self.scheduleIdleUnload = scheduleIdleUnload
    }

    /// Default production scheduler: a one-shot `Timer` on the main run loop.
    static func defaultScheduler(afterSeconds seconds: TimeInterval, fire: @escaping () -> Void) -> IdleTimerHandle {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return IdleTimerHandle { timer.invalidate() }
    }

    /// Returns the loaded resource, loading it first if needed. Concurrent callers
    /// while a load is already in flight all await that same load rather than
    /// triggering redundant loads. Resets the idle-unload timer on success.
    @discardableResult
    func ensureLoaded() async throws -> Resource {
        if let resource, loadState == .ready {
            resetIdleTimer()
            return resource
        }

        if let loadingTask {
            return try await loadingTask.value
        }

        loadState = .loading
        let task = Task { () throws -> Resource in
            try await self.load()
        }
        loadingTask = task

        do {
            let resource = try await task.value
            self.resource = resource
            loadState = .ready
            loadingTask = nil
            resetIdleTimer()
            return resource
        } catch {
            self.resource = nil
            loadState = .failed(error.localizedDescription)
            loadingTask = nil
            throw error
        }
    }

    /// Free the resource immediately (idle timeout fired, or an explicit user action
    /// in a future settings UI). Idempotent — a no-op when already unloaded.
    func unload() {
        idleTimerHandle?.cancel()
        idleTimerHandle = nil
        if let resource {
            unloadResource(resource)
        }
        resource = nil
        loadState = .unloaded
    }

    private func resetIdleTimer() {
        idleTimerHandle?.cancel()
        idleTimerHandle = nil
        let minutes = idleTimeoutMinutes()
        guard minutes > 0 else { return }
        idleTimerHandle = scheduleIdleUnload(minutes * 60) { [weak self] in
            Task { await self?.unload() }
        }
    }
}
