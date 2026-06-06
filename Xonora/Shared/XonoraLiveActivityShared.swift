import Foundation
import ActivityKit

/// Constants and helpers shared between the Xonora app and its widget extension.
///
/// The widget extension cannot import the app target (or SendspinKit), so anything
/// both sides need — the Live Activity attributes, the App Group plumbing, the
/// connection details the control intents read — lives here and links into both
/// targets. Keep this file dependency-free beyond Foundation/ActivityKit.
enum XonoraShared {
    /// App Group container shared by the app and the widget extension. The app drops
    /// the current artwork and mirrors the MA connection details here so the Live
    /// Activity (and its control intents, which run outside the app's process) can
    /// reach them. Must match the `com.apple.security.application-groups` entitlement
    /// on both targets.
    ///
    /// Resolved at runtime from the `XonoraAppGroupID` Info.plist key, which the build
    /// injects from the `APP_GROUP_ID` build setting (`group.$(APP_BUNDLE_ID)`). That
    /// keeps it on whatever bundle namespace we sign under — e.g. `group.com.chibinet.xonora`
    /// — without hardcoding a personal value. `Bundle.main` is the app in the app process
    /// and the widget extension in the intent/widget process; both carry the same key, so
    /// the two sides agree. The literal fallback only applies if the key is somehow absent.
    static var appGroupId: String {
        if let id = Bundle.main.object(forInfoDictionaryKey: "XonoraAppGroupID") as? String,
           !id.isEmpty {
            return id
        }
        return "group.com.ma.xonora"
    }

    /// Keys the app mirrors into the App Group defaults so the control intents can
    /// reach Music Assistant while the app is suspended. The string values match the
    /// app's existing `UserDefaults.standard` keys so the two stores stay in lockstep.
    enum DefaultsKey {
        static let serverURL = "MusicAssistantServerURL"
        static let accessToken = "MusicAssistantAccessToken"
    }

    /// Shared `UserDefaults` for the app group. `nil` only if the App Group
    /// entitlement is missing/misconfigured.
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupId) }

    /// Directory inside the App Group container where the app writes artwork JPEGs
    /// for the widget to read (`UIImage(contentsOfFile:)`). Live Activity views can't
    /// fetch remote images at render time, so the bytes must already be on disk in a
    /// place both processes can see. Returns `nil` if the container is unavailable.
    static var artworkDirectory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let dir = base.appendingPathComponent("LiveActivityArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Absolute file URL for an artwork file name within the shared container.
    static func artworkURL(for fileName: String) -> URL? {
        artworkDirectory?.appendingPathComponent(fileName)
    }
}

/// ActivityKit attributes for a Now Playing Live Activity that mirrors a *remote*
/// Music Assistant speaker (Mode R — the phone is only a remote, producing no audio).
/// The app keeps at most one of these alive at a time.
@available(iOS 16.1, *)
struct XonoraLiveActivityAttributes: ActivityAttributes {
    typealias ContentState = State

    /// Per-update playback snapshot the app pushes via `activity.update(...)`.
    ///
    /// Progress is encoded as an *anchor* (`elapsed` sampled at `asOf`) rather than a
    /// live position, so the widget can render a self-advancing bar/clock with
    /// `ProgressView(timerInterval:)` / `Text(timerInterval:)` and we only push on real
    /// state changes — respecting the Live Activity update budget.
    struct State: Codable, Hashable {
        var title: String
        var artist: String
        var album: String
        /// File name (within `XonoraShared.artworkDirectory`) of the current artwork, if any.
        var artworkFileName: String?
        var isPlaying: Bool
        /// Track length in seconds; `0` when unknown (e.g. live streams).
        var duration: TimeInterval
        /// Server-reported elapsed seconds, sampled at `asOf`.
        var elapsed: TimeInterval
        /// Wall-clock instant `elapsed` was sampled. Lets the widget project progress
        /// forward without per-second pushes.
        var asOf: Date
        /// Radio / live stream: no fixed duration, no scrubber, no countdown.
        var isLive: Bool

        /// Instant the current track notionally started playing (`asOf - elapsed`).
        /// The progress bar/clock anchor for `timerInterval` views.
        var startDate: Date { asOf.addingTimeInterval(-elapsed) }

        /// Projected end of the current track (`startDate + duration`).
        var endDate: Date { startDate.addingTimeInterval(max(duration, 0)) }

        /// Static 0...1 fraction for paused state, where `timerInterval` can't be used.
        var staticProgress: Double {
            guard duration > 0 else { return 0 }
            return min(max(elapsed / duration, 0), 1)
        }
    }

    /// Static per-activity identity: which speaker this card represents. Shown as the
    /// card's subtitle ("Playing on Parlor") and used by the control intents to target
    /// the right MA queue.
    var playerName: String
    var playerId: String
}
