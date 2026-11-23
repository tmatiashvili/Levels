import Foundation
import Synchronization

/// Scripted ``BatteryReader`` for unit tests and previews (ADR-0010 rule 7).
///
/// `read()` returns the queued readings in order and then keeps returning the last one.
/// `emit(_:)` pushes a change onto the single ``changes()`` stream; emitted readings are
/// buffered, so a consumer that subscribes later still sees them in order.
public final class FixedBatteryReader: BatteryReader {
    private struct State {
        var queue: [BatteryReading]
        var current: BatteryReading
        var readCount = 0
    }

    private let state: Mutex<State>
    private let stream: AsyncStream<BatteryReading>
    private let continuation: AsyncStream<BatteryReading>.Continuation

    /// - Parameter readings: returned by `read()` in order; the last one repeats. Must not be empty.
    public init(_ readings: [BatteryReading]) {
        precondition(!readings.isEmpty, "FixedBatteryReader needs at least one reading")
        state = Mutex(State(queue: Array(readings.dropFirst()), current: readings[0]))
        (stream, continuation) = AsyncStream.makeStream(of: BatteryReading.self)
    }

    public convenience init(_ reading: BatteryReading) { self.init([reading]) }

    public func read() async -> BatteryReading {
        state.withLock { s in
            s.readCount += 1
            let value = s.current
            if !s.queue.isEmpty { s.current = s.queue.removeFirst() }
            return value
        }
    }

    /// The one change stream. Call it once; a second consumer would share its elements.
    public func changes() -> AsyncStream<BatteryReading> { stream }

    /// Makes `reading` the value `read()` returns from now on (dropping the queue).
    public func set(_ reading: BatteryReading) {
        state.withLock { s in
            s.queue = []
            s.current = reading
        }
    }

    /// Sets `reading` as current and emits it on ``changes()``.
    public func emit(_ reading: BatteryReading) {
        set(reading)
        continuation.yield(reading)
    }

    /// Ends the change stream.
    public func finish() { continuation.finish() }

    /// How many times `read()` ran.
    public var readCount: Int { state.withLock { $0.readCount } }
}
