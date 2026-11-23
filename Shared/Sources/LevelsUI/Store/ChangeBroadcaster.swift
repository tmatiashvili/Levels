import Foundation
import Synchronization

/// Fans one "changed" signal out to every `AsyncStream` handed out by ``stream()``.
public final class ChangeBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    public init() {}

    /// A new stream; it ends when the consumer stops iterating or the task is cancelled.
    public func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// Signals every open stream.
    public func send() {
        for c in continuations.withLock({ Array($0.values) }) { c.yield() }
    }
}
