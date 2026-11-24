// WidgetKit asks each widget (Home Screen small, Lock Screen circular, …) for its own timeline,
// often at the same moment. Each one used to run its own Bonjour browse and TLS connection to
// the Mac. They now share one fetch: callers that arrive while it runs wait for it, and callers
// shortly after reuse its result.
import Foundation

/// Single-flight for one async job, with a short reuse window. Unit-tested.
public actor SharedFetch<Value: Sendable> {
    private let reuseFor: TimeInterval
    private let now: @Sendable () -> Date
    private var running: Task<Value, Never>?
    private var last: (value: Value, at: Date)?

    /// - Parameter reuseFor: seconds a finished result is handed to later callers.
    public init(reuseFor: TimeInterval, now: @escaping @Sendable () -> Date = Date.init) {
        self.reuseFor = reuseFor
        self.now = now
    }

    /// The running job's result, a result from the last `reuseFor` seconds, or a new run of `work`.
    public func run(_ work: @escaping @Sendable () async -> Value) async -> Value {
        if let running { return await running.value }
        if let last, now().timeIntervalSince(last.at) < reuseFor, now() >= last.at { return last.value }
        let task = Task { await work() }
        running = task
        let value = await task.value
        running = nil
        last = (value, now())
        return value
    }
}
