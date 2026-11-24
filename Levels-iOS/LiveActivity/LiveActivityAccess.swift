// LIVE-001 R2, owner decision V: whether this build may start the "Live levels" Live Activity.
// Free or Pro is still open, so it says yes for now.

enum LiveActivityAccess {
    /// The one gate for the Live Activity. Every start goes through here.
    ///
    /// TODO(ProGate): owner decision V leaves Free vs Pro open (PUSH-001 R75 and open question 1
    /// recommend Pro). When decided, answer from the Levels Pro gate (MON-001 R19, `ProGate` on
    /// feature/levels-pro), e.g. `ProGate.load(appGroupID: LevelsAppConfig.appGroupID).isPro`,
    /// and end a running activity when Pro lapses.
    static func isAllowed() -> Bool { true }
}
