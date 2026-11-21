import CoreGraphics
import OSLog

/// The address bar's collapse for one tab.
///
/// Blink owns the scroll, so the engine reports how far the bar has collapsed; the
/// reader can pin it open by tapping the pill. The bar draws only what `collapse`
/// derives from this state and two view facts: focus and whether a page is loaded.
struct CuriumChromeState: Equatable {
    enum Source: Equatable {
        /// The engine has no compositor top controls; the bar stays full.
        case fixed
        /// Blink's compositor reports the collapse: 0 is the full bar, 1 the pill.
        case compositor(collapse: CGFloat)
    }

    enum UnpinReason: String {
        case scrolled, reachedTop, navigated, replacedEngine
    }

    private(set) var source: Source = .fixed
    /// The reader tapped the pill. Holds until they scroll, reach the top, or navigate.
    private(set) var pinnedOpen = false

    func collapse(focused: Bool, hasPage: Bool) -> CGFloat {
        guard hasPage, !focused, !pinnedOpen, case .compositor(let collapse) = source else { return 0 }
        return collapse
    }

    mutating func engineReported(collapse: CGFloat?) {
        let next: Source = collapse.map { .compositor(collapse: Self.quantize($0)) } ?? .fixed
        guard next != source else { return }
        if (next == .fixed) != (source == .fixed) {
            Self.log.notice("chrome source: \(next == .fixed ? "fixed" : "compositor", privacy: .public)")
        }
        source = next
        if pinnedOpen, case .compositor(let value) = next, value == 0 { unpin(.reachedTop) }
    }

    /// Snaps sub-pixel compositor drift into 0.005 steps and settles endpoints cleanly.
    private static func quantize(_ raw: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, raw))
        if clamped <= 0.005 { return 0 }
        if clamped >= 0.995 { return 1 }
        return (clamped * 200).rounded() / 200
    }

    mutating func pin() {
        guard !pinnedOpen, case .compositor(let value) = source, value > 0 else { return }
        pinnedOpen = true
        Self.log.notice("chrome pinned open")
    }

    mutating func unpin(_ reason: UnpinReason) {
        guard pinnedOpen else { return }
        pinnedOpen = false
        Self.log.notice("chrome unpinned: \(reason.rawValue, privacy: .public)")
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "chrome")
}
