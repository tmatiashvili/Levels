import Network
import Testing
@testable import LevelsNet

/// NET-001 R1, R14: the Mac hub's listener retry rules (`HubServer` applies them).
@Suite("NET-001 hub retry policy")
struct HubRetryPolicyTests {
    @Test func backoffIs5s15s1minThenEvery5min() {
        var policy = HubRetryPolicy()
        let delays = (0..<6).map { _ in policy.startFailed().delay }
        #expect(delays == [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(300), .seconds(300)])
    }

    @Test func failedShowsOnlyFromTheSecondFailure() {
        var policy = HubRetryPolicy()
        do { let r = policy.startFailed().showsFailed; #expect(r == false) }  // "Starting…"
        do { let r = policy.startFailed().showsFailed; #expect(r) }
        do { let r = policy.startFailed().showsFailed; #expect(r) }
    }

    @Test func resetStartsTheBackoffOver() {
        var policy = HubRetryPolicy()
        _ = policy.startFailed()
        _ = policy.startFailed()
        _ = policy.startFailed()
        policy.reset()  // listener ready, or pairing window opened
        #expect(policy.failures == 0)
        do { let r = policy.startFailed(); #expect(r == .init(delay: .seconds(5), showsFailed: false)) }
    }

    @Test func firstPathUpdateOnlyRecordsThePath() {
        var policy = HubRetryPolicy()
        do { let r = policy.pathChanged(to: .satisfied, retryPending: true); #expect(!r) }
    }

    @Test func pathBecomingSatisfiedRetriesAWaitingRetryNow() {
        var policy = HubRetryPolicy()
        _ = policy.pathChanged(to: .unsatisfied, retryPending: true)
        do { let r = policy.pathChanged(to: .satisfied, retryPending: true); #expect(r) }
    }

    @Test func pathChangeWithoutAWaitingRetryDoesNothing() {
        var policy = HubRetryPolicy()
        _ = policy.pathChanged(to: .unsatisfied, retryPending: false)
        do { let r = policy.pathChanged(to: .satisfied, retryPending: false); #expect(!r) }
    }

    @Test func onlyAChangeToSatisfiedRetries() {
        var policy = HubRetryPolicy()
        _ = policy.pathChanged(to: .satisfied, retryPending: true)
        do { let r = policy.pathChanged(to: .satisfied, retryPending: true); #expect(!r) }  // no change
        do { let r = policy.pathChanged(to: .unsatisfied, retryPending: true); #expect(!r) }  // lost, not back
        do { let r = policy.pathChanged(to: .requiresConnection, retryPending: true); #expect(!r) }
        do { let r = policy.pathChanged(to: .satisfied, retryPending: true); #expect(r) }
    }
}
