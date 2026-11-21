import AVKit
import OSLog

/// Picture in Picture for one tab, as the address bar presents it.
///
/// Chromium starts Picture in Picture only when it can tell which video is meant: one
/// video playing with sound. Otherwise the request does nothing, so a request that the
/// engine does not confirm in time becomes `refused`, and the bar explains why. Where
/// the system offers no Picture in Picture at all, the button never appears.
struct CuriumPictureInPictureState: Equatable {
    enum Phase: String {
        /// No video is playing, or the system has no Picture in Picture; the button is hidden.
        case unavailable
        /// A video is playing; the button offers Picture in Picture.
        case available
        /// Asked the engine; waiting for the system window.
        case starting
        /// The engine did not start it; the bar shows a hint.
        case refused
        /// The system window is showing; the button exits it.
        case active
    }

    enum Command { case enter, exit }

    static let confirmationTimeout: Duration = .seconds(3)
    static let hintDuration: Duration = .seconds(3)

    private(set) var phase: Phase = .unavailable
    private var hasVideo = false
    /// AVKit's answer for this device, fixed for the life of the process.
    private let systemSupported: Bool

    init(systemSupported: Bool = Self.systemSupported) {
        self.systemSupported = systemSupported
    }

    static let systemSupported: Bool = {
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        if !supported { log.notice("pip unsupported by this device; the button stays hidden") }
        return supported
    }()

    mutating func engineReported(hasVideo rawHasVideo: Bool, active: Bool) {
        let hasVideo = rawHasVideo && systemSupported
        self.hasVideo = hasVideo
        if active {
            transition(to: .active, because: "engine active")
        } else if phase == .starting {
            return
        } else if phase == .refused && hasVideo {
            return
        } else {
            transition(to: hasVideo ? .available : .unavailable, because: "engine report")
        }
    }

    /// The reader tapped the button. Returns what to ask the engine, if anything.
    mutating func requested() -> Command? {
        switch phase {
        case .active:
            return .exit
        case .available, .refused:
            transition(to: .starting, because: "requested")
            return .enter
        case .unavailable, .starting:
            return nil
        }
    }

    mutating func confirmationTimedOut() {
        guard phase == .starting else { return }
        transition(to: .refused, because: "no confirmation")
    }

    mutating func hintExpired() {
        guard phase == .refused else { return }
        transition(to: hasVideo ? .available : .unavailable, because: "hint expired")
    }

    private mutating func transition(to next: Phase, because reason: String) {
        guard next != phase else { return }
        let previous = phase.rawValue
        Self.log.notice("pip \(previous, privacy: .public) -> \(next.rawValue, privacy: .public) (\(reason, privacy: .public))")
        phase = next
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "pip")
}
