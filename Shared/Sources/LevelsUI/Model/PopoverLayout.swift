import CoreGraphics

/// Height of the Mac menu-bar popover (UI-004 R6): fits the content up to ``maxHeight``,
/// then the list scrolls. Pure, unit-tested; the numbers match the rendered rows.
public enum PopoverLayout {
    public static let maxHeight: CGFloat = 480
    /// One device row: name and age lines next to a 28 pt ring (about 40 pt rendered, plus slack).
    public static let rowHeight: CGFloat = 42
    /// One AirPods group row: component titles, rings and percentages.
    public static let groupRowHeight: CGFloat = 66
    /// The sync banner section above the list, when visible.
    public static let bannerHeight: CGFloat = 56
    /// The "only this device" footer under the rows.
    public static let footerNoteHeight: CGFloat = 28
    /// Footer bar, divider and the list's own insets.
    public static let chromeHeight: CGFloat = 56
    /// Room for the empty and loading states.
    public static let minHeight: CGFloat = 140
    /// Stacked rows at accessibility text sizes (UI-001 R10) are taller.
    public static let stackedRowHeight: CGFloat = 80
    public static let stackedGroupRowHeight: CGFloat = 104

    public static func height(rows: [DeviceRowModel], state: DeviceListStore.State,
                              isReportingOff: Bool, isStacked: Bool = false) -> CGFloat {
        let (row, group) = isStacked ? (stackedRowHeight, stackedGroupRowHeight) : (rowHeight, groupRowHeight)
        var content = rows.reduce(CGFloat(0)) { $0 + ($1.isGroup ? group : row) }
        if SyncStatusBanner.isVisible(state: state, isReportingOff: isReportingOff) { content += bannerHeight }
        if state == .onlyThisDevice { content += footerNoteHeight }
        return min(maxHeight, max(minHeight, content + chromeHeight))
    }
}
