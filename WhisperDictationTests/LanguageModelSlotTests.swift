import XCTest
@testable import WhisperDictation

/// Fake resource — a simple reference type so we can assert identity/unload calls
/// without touching whisper.cpp.
private final class FakeResource {
    let id: Int
    init(id: Int) { self.id = id }
}

/// Test-controlled "clock": captures every scheduled idle-unload callback along with
/// its delay, and lets the test fire it manually instead of waiting on a real Timer.
private final class FakeScheduler {
    struct Scheduled {
        let afterSeconds: TimeInterval
        let fire: () -> Void
        var cancelled = false
    }

    private(set) var scheduled: [Scheduled] = []

    func schedule(afterSeconds seconds: TimeInterval, fire: @escaping () -> Void) -> LanguageModelSlot<FakeResource>.IdleTimerHandle {
        let index = scheduled.count
        scheduled.append(Scheduled(afterSeconds: seconds, fire: fire))
        return LanguageModelSlot<FakeResource>.IdleTimerHandle { [weak self] in
            self?.scheduled[index].cancelled = true
        }
    }

    /// Fire the most recently scheduled, non-cancelled timer (simulates the idle
    /// timeout elapsing). The slot's own callback dispatches the actual `unload()`
    /// onto a detached `Task` (required since `resetIdleTimer`'s callback isn't
    /// actor-isolated) — callers must `await Task.yield()` (or similar) afterward
    /// for that unload to have actually run before asserting on it.
    func fireLatest() {
        guard let last = scheduled.last, !last.cancelled else { return }
        last.fire()
    }

    var activeCount: Int { scheduled.filter { !$0.cancelled }.count }
}

/// Reference-type mutable boxes so closures captured by `LanguageModelSlot` can
/// safely record call counts / unloaded ids across async boundaries (a `Swift`
/// `&inout` pointer would dangle once the enclosing call returns).
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class LanguageModelSlotTests: XCTestCase {

    private func makeSlot(
        idleTimeoutMinutes: Double,
        scheduler: FakeScheduler,
        loadCallCount: Box<Int>? = nil,
        unloadedIds: Box<[Int]>? = nil,
        loadImpl: (@Sendable () async throws -> FakeResource)? = nil
    ) -> LanguageModelSlot<FakeResource> {
        let nextId = Box(0)
        return LanguageModelSlot<FakeResource>(
            idleTimeoutMinutes: { idleTimeoutMinutes },
            load: {
                loadCallCount?.value += 1
                if let loadImpl { return try await loadImpl() }
                nextId.value += 1
                return FakeResource(id: nextId.value)
            },
            unload: { resource in
                unloadedIds?.value.append(resource.id)
            },
            scheduleIdleUnload: { seconds, fire in
                scheduler.schedule(afterSeconds: seconds, fire: fire)
            }
        )
    }

    // MARK: - State transitions

    func testStartsUnloaded() async {
        let scheduler = FakeScheduler()
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)
        let state = await slot.loadState
        let resource = await slot.resource
        XCTAssertEqual(state, .unloaded)
        XCTAssertNil(resource)
    }

    func testEnsureLoadedTransitionsToReady() async throws {
        let scheduler = FakeScheduler()
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)

        let resource = try await slot.ensureLoaded()
        let state = await slot.loadState
        let stored = await slot.resource
        XCTAssertEqual(state, .ready)
        XCTAssertNotNil(stored)
        XCTAssertEqual(resource.id, stored?.id)
    }

    func testEnsureLoadedWhenAlreadyReadyReturnsSameResourceWithoutReloading() async throws {
        let scheduler = FakeScheduler()
        let loadCalls = Box(0)
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler, loadCallCount: loadCalls)

        let first = try await slot.ensureLoaded()
        let second = try await slot.ensureLoaded()

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(loadCalls.value, 1, "a second ensureLoaded() while already ready must not reload")
    }

    func testFailedLoadSetsFailedStateAndClearsResource() async {
        let scheduler = FakeScheduler()
        struct BoomError: Error {}
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler, loadImpl: { throw BoomError() })

        do {
            _ = try await slot.ensureLoaded()
            XCTFail("expected load to throw")
        } catch {
            // expected
        }

        let state = await slot.loadState
        if case .failed = state {
            // ok
        } else {
            XCTFail("expected .failed state, got \(state)")
        }
        let resource = await slot.resource
        XCTAssertNil(resource)
    }

    // MARK: - Concurrent ensureLoaded() collapses into one load

    func testConcurrentEnsureLoadedCallsCollapseIntoOneLoad() async throws {
        let scheduler = FakeScheduler()
        let loadCalls = Box(0)

        // A load that takes a moment, so concurrent callers overlap it.
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler, loadCallCount: loadCalls, loadImpl: {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            return FakeResource(id: 42)
        })

        async let a = slot.ensureLoaded()
        async let b = slot.ensureLoaded()
        async let c = slot.ensureLoaded()

        let (ra, rb, rc) = try await (a, b, c)
        XCTAssertEqual(ra.id, 42)
        XCTAssertEqual(rb.id, 42)
        XCTAssertEqual(rc.id, 42)
        XCTAssertEqual(loadCalls.value, 1, "three concurrent ensureLoaded() calls must trigger exactly one load")
    }

    // MARK: - Unload

    func testUnloadFreesResourceAndCallsUnloadClosure() async throws {
        let scheduler = FakeScheduler()
        let unloadedIds = Box<[Int]>([])
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler, unloadedIds: unloadedIds)

        let resource = try await slot.ensureLoaded()
        await slot.unload()

        let state = await slot.loadState
        let stored = await slot.resource
        XCTAssertEqual(state, .unloaded)
        XCTAssertNil(stored)
        XCTAssertEqual(unloadedIds.value, [resource.id])
    }

    func testUnloadWhenAlreadyUnloadedIsANoOp() async {
        let scheduler = FakeScheduler()
        let unloadedIds = Box<[Int]>([])
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler, unloadedIds: unloadedIds)

        await slot.unload() // no-op, never loaded
        let state = await slot.loadState
        XCTAssertEqual(state, .unloaded)
        XCTAssertTrue(unloadedIds.value.isEmpty)
    }

    // MARK: - Idle timeout

    func testIdleTimeoutFiringUnloadsResource() async throws {
        let scheduler = FakeScheduler()
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)

        _ = try await slot.ensureLoaded()
        let readyState = await slot.loadState
        XCTAssertEqual(readyState, .ready)

        scheduler.fireLatest()
        // The fired callback dispatches `unload()` onto a detached Task (see
        // `resetIdleTimer`) since it isn't itself actor-isolated. Poll briefly
        // instead of asserting immediately.
        var finalState = await slot.loadState
        for _ in 0..<50 where finalState != .unloaded {
            try await Task.sleep(nanoseconds: 2_000_000)
            finalState = await slot.loadState
        }
        XCTAssertEqual(finalState, .unloaded)
        let resource = await slot.resource
        XCTAssertNil(resource)
    }

    func testZeroTimeoutNeverSchedulesUnload() async throws {
        let scheduler = FakeScheduler()
        let slot = makeSlot(idleTimeoutMinutes: 0, scheduler: scheduler)

        _ = try await slot.ensureLoaded()
        XCTAssertEqual(scheduler.activeCount, 0, "timeout of 0 must never schedule an idle-unload timer")
        let state = await slot.loadState
        XCTAssertEqual(state, .ready, "resource must remain loaded with no timer to fire")
    }

    func testEachSuccessfulEnsureLoadedResetsTheIdleTimer() async throws {
        let scheduler = FakeScheduler()
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)

        _ = try await slot.ensureLoaded()
        _ = try await slot.ensureLoaded()
        _ = try await slot.ensureLoaded()

        // Only the latest timer should still be active; earlier ones cancelled.
        XCTAssertEqual(scheduler.activeCount, 1)
    }

    func testScheduledDelayMatchesConfiguredMinutes() async throws {
        let scheduler = FakeScheduler()
        let slot = makeSlot(idleTimeoutMinutes: 5, scheduler: scheduler)

        _ = try await slot.ensureLoaded()
        XCTAssertEqual(scheduler.scheduled.last?.afterSeconds, 300)
    }

    // MARK: - onStateChange notifications (menu bar mirroring)

    func testOnStateChangeFiresForLoadingThenReady() async throws {
        let scheduler = FakeScheduler()
        let observed = Box<[LanguageModelSlot<FakeResource>.LoadState]>([])
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)
        await slot.setOnStateChange { state, _ in observed.value.append(state) }

        _ = try await slot.ensureLoaded()

        XCTAssertEqual(observed.value, [.loading, .ready])
    }

    /// The callback also receives the resource itself, non-nil only for `.ready`.
    func testOnStateChangePassesResourceOnlyWhenReady() async throws {
        let scheduler = FakeScheduler()
        let observedResources = Box<[FakeResource?]>([])
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)
        await slot.setOnStateChange { _, resource in observedResources.value.append(resource) }

        _ = try await slot.ensureLoaded()

        XCTAssertEqual(observedResources.value.count, 2)
        XCTAssertNil(observedResources.value[0], "no resource while .loading")
        XCTAssertNotNil(observedResources.value[1], "resource present at .ready")
    }

    func testOnStateChangeFiresFailedOnLoadError() async {
        let scheduler = FakeScheduler()
        let observed = Box<[LanguageModelSlot<FakeResource>.LoadState]>([])
        struct BoomError: Error {}
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler, loadImpl: { throw BoomError() })
        await slot.setOnStateChange { state, _ in observed.value.append(state) }

        _ = try? await slot.ensureLoaded()

        XCTAssertEqual(observed.value.count, 2)
        XCTAssertEqual(observed.value.first, .loading)
        if case .failed = observed.value.last {
            // ok
        } else {
            XCTFail("expected .failed as last observed state, got \(String(describing: observed.value.last))")
        }
    }

    func testOnStateChangeFiresUnloadedOnUnload() async throws {
        let scheduler = FakeScheduler()
        let observed = Box<[LanguageModelSlot<FakeResource>.LoadState]>([])
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)
        await slot.setOnStateChange { state, _ in observed.value.append(state) }

        _ = try await slot.ensureLoaded()
        await slot.unload()

        XCTAssertEqual(observed.value, [.loading, .ready, .unloaded])
    }

    func testSetOnStateChangeCanBeReplaced() async throws {
        let scheduler = FakeScheduler()
        let firstObserved = Box<Int>(0)
        let secondObserved = Box<Int>(0)
        let slot = makeSlot(idleTimeoutMinutes: 10, scheduler: scheduler)

        await slot.setOnStateChange { _, _ in firstObserved.value += 1 }
        await slot.setOnStateChange { _, _ in secondObserved.value += 1 }
        _ = try await slot.ensureLoaded()

        XCTAssertEqual(firstObserved.value, 0, "replaced callback must not fire")
        XCTAssertEqual(secondObserved.value, 2, "loading + ready")
    }
}
