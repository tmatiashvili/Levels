import Network

/// When the Mac hub retries a listener that failed to start, and what the owner sees
/// meanwhile (NET-001 R1, R14). Pure state: `HubServer` owns the timer and the listener.
///
/// - Backoff: 5 s, 15 s, 1 min, then every 5 min.
/// - The first failure still shows "Starting…"; from the second on, "Couldn't start sharing".
/// - A listener that is ready again (or a start that succeeded) resets the count.
/// - A network path that becomes satisfied while a retry waits retries at once.
/// - `.waiting` is not a failure: Network.framework brings a running listener back itself.
public struct HubRetryPolicy: Sendable, Equatable {
    /// What a failed start leads to.
    public struct Retry: Sendable, Equatable {
        /// Wait this long, then try again.
        public let delay: Duration
        /// Show "Couldn't start sharing" (with Retry) instead of "Starting…".
        public let showsFailed: Bool
    }

    /// Consecutive failed starts; 0 after a start succeeds.
    public private(set) var failures = 0
    private var lastPath: NWPath.Status?

    public init() {}

    /// Backoff between retries: 5 s, 15 s, 1 min, then every 5 min.
    public static func delay(afterFailures n: Int) -> Duration {
        switch n {
        case ...1: .seconds(5)
        case 2: .seconds(15)
        case 3: .seconds(60)
        default: .seconds(300)
        }
    }

    /// A start failed, or a running listener failed for good.
    public mutating func startFailed() -> Retry {
        failures += 1
        return Retry(delay: Self.delay(afterFailures: failures), showsFailed: failures >= 2)
    }

    /// The listener is ready (a start succeeded or it came back by itself), or the owner
    /// opened the pairing window: the next failure starts the backoff from the beginning.
    public mutating func reset() {
        failures = 0
    }

    /// A network path update. `true` when a waiting retry should run now: the path changed
    /// to satisfied (Wi-Fi back, another interface), the likeliest moment a start succeeds.
    /// The first update after launch only records the path.
    public mutating func pathChanged(to path: NWPath.Status, retryPending: Bool) -> Bool {
        defer { lastPath = path }
        guard let lastPath else { return false }
        return path != lastPath && path == .satisfied && retryPending
    }
}
