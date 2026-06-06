import AppIntents
import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

// Live Activity control intents. These run *outside* the app process (the system
// hosts them when a button on the Live Activity is tapped), so they reach Music
// Assistant via the self-contained `MARemoteControl` WS client and read connection
// details from the App Group defaults. They never import the app target.
//
// `LiveActivityIntent` tells the system the intent originates from a Live Activity,
// which keeps the app suspended (no foreground launch) while the command runs.

/// Toggle play/pause on the targeted MA player, then optimistically re-anchor the
/// running activity so the button feels instant before the app reconciles real state.
@available(iOS 17.0, *)
struct TogglePlayPauseIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Play / Pause"

    @Parameter(title: "Player ID")
    var playerId: String

    init() {}

    init(playerId: String) {
        self.playerId = playerId
    }

    func perform() async throws -> some IntentResult {
        // Issue the remote command; swallow transport errors so the button never
        // surfaces a failure dialog from the Live Activity.
        try? await MARemoteControl.send(.togglePlayPause, playerId: playerId)

        // Optimistically flip the visible state so the UI responds immediately.
        await optimisticToggle()

        return .result()
    }

    /// Find this player's running activity and re-anchor its progress for the flipped
    /// play state. Guarded so nothing here can throw out of `perform()`.
    private func optimisticToggle() async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard let activity = Activity<XonoraLiveActivityAttributes>.activities
            .first(where: { $0.attributes.playerId == playerId }) else { return }

        let state = activity.content.state
        let now = Date()
        let wasPlaying = state.isPlaying
        // If we were playing, fold the time since the last sample into elapsed before
        // re-anchoring; if paused, elapsed already reflects the frozen position.
        let projectedElapsed = wasPlaying ? state.elapsed + now.timeIntervalSince(state.asOf) : state.elapsed

        var newState = state
        newState.isPlaying = !wasPlaying
        newState.elapsed = projectedElapsed
        newState.asOf = now

        await activity.update(ActivityContent(state: newState, staleDate: nil))
        #endif
    }
}

/// Skip to the next track on the targeted MA player. No optimistic content change —
/// the app pushes the new track snapshot shortly after.
@available(iOS 17.0, *)
struct NextTrackIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Track"

    @Parameter(title: "Player ID")
    var playerId: String

    init() {}

    init(playerId: String) {
        self.playerId = playerId
    }

    func perform() async throws -> some IntentResult {
        try? await MARemoteControl.send(.next, playerId: playerId)
        return .result()
    }
}

/// Skip to the previous track on the targeted MA player.
@available(iOS 17.0, *)
struct PreviousTrackIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Track"

    @Parameter(title: "Player ID")
    var playerId: String

    init() {}

    init(playerId: String) {
        self.playerId = playerId
    }

    func perform() async throws -> some IntentResult {
        try? await MARemoteControl.send(.previous, playerId: playerId)
        return .result()
    }
}
