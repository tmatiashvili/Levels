import Foundation
import Synchronization
import Testing

/// A `Clock` that moves only when a test calls `advance(by:)`. `date` follows it, so
/// code that takes both a clock and a `now` closure sees one consistent time.
/// (Copied in LevelsReadersTests and LevelsSyncTests; the package has no test-support target.)
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        var id: UInt64
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
        var requests: [(duration: Duration, tolerance: Duration?)] = []
    }

    private let state = Mutex(State())
    let startDate: Date

    init(startDate: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.startDate = startDate
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// The wall-clock date matching `now`.
    var date: Date {
        let offset = now.offset.components
        return startDate.addingTimeInterval(TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18)
    }

    /// Sleeps currently waiting.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Every sleep requested so far: its length from `now` and its tolerance.
    var requests: [(duration: Duration, tolerance: Duration?)] { state.withLock { $0.requests } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let action: Result<Void, any Error>? = state.withLock { s in
                    s.requests.append((s.now.duration(to: deadline), tolerance))
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= s.now { return .success(()) }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let action { continuation.resume(with: action) }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: i).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let ready = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let ready = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return ready
        }
        for sleeper in ready { sleeper.continuation.resume() }
    }
}

/// Polls `condition` (yielding and briefly sleeping) until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Records an issue unless `condition` holds within `timeout`.
func waitFor(timeout: Duration = .seconds(2), sourceLocation: SourceLocation = #_sourceLocation,
             _ condition: @Sendable () async -> Bool) async {
    let ok = await eventually(timeout: timeout, condition)
    #expect(ok, "condition not met in time", sourceLocation: sourceLocation)
}

/// Lets queued tasks run, for checks that something did *not* happen.
func settle() async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
    for _ in 0..<50 { await Task.yield() }
}
