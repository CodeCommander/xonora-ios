// ABOUTME: Drives a Now Playing Live Activity for REMOTE Music Assistant speakers (Mode R).
// ABOUTME: Mode P (phone-as-output / sendspin) is left to the native MPNowPlayingInfoCenter card.

import Foundation
import ActivityKit
import UIKit

/// Reconciles a single Now Playing Live Activity with the app's playback state.
///
/// Two playback modes drive whether a Live Activity exists at all:
/// - **Mode P** (phone-as-output, provider `sendspin`): the phone produces audio and
///   iOS awards the native lock-screen card. We show NO Live Activity here.
/// - **Mode R** (remote control, provider != `sendspin`): audio plays on another MA
///   device, the phone makes no sound, so iOS surfaces no native card. We drive a
///   Live Activity to give the user a lock-screen Now Playing surface.
///
/// The controller is the single owner of the running `Activity`. It starts, updates,
/// and ends it in response to `reconcile()` calls hung off PlayerManager's now-playing
/// refresh points. All ActivityKit use is guarded for iOS 16.1+ and never throws out.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private init() {}

    // The running activity and last-pushed state are only meaningful on iOS 16.1+.
    // `Any` boxing keeps the stored properties free of an availability annotation
    // (stored properties can't carry `@available`); casts happen behind the guard.
    private var activityBox: Any?
    private var lastPushedStateBox: Any?

    /// Track id whose artwork we've already kicked off a load for, to avoid redundant
    /// fetches and to detect when the track changed.
    private var lastArtworkTrackId: String?
    /// Artwork file name (within the shared container) for the current track, once written.
    private var currentArtworkFileName: String?

    @available(iOS 16.1, *)
    private var activity: Activity<XonoraLiveActivityAttributes>? {
        get { activityBox as? Activity<XonoraLiveActivityAttributes> }
        set { activityBox = newValue }
    }

    @available(iOS 16.1, *)
    private var lastPushedState: XonoraLiveActivityAttributes.ContentState? {
        get { lastPushedStateBox as? XonoraLiveActivityAttributes.ContentState }
        set { lastPushedStateBox = newValue }
    }

    // MARK: - Reconcile

    /// Reconciles the Live Activity with the current PlayerManager / current player state.
    /// Call this wherever the now-playing card refreshes (PlayerManager's
    /// `updateNowPlayingInfoAsync` / `clearNowPlayingInfo`).
    func reconcile() {
        guard #available(iOS 16.1, *) else { return }

        // Can't show a Live Activity if the user has them disabled. Surface this loudly:
        // a silent bail here looks identical to a broken feature. The toggle lives at
        // Settings ▸ Xonora ▸ Live Activities (per-app) and Settings ▸ Face ID &
        // Passcode ▸ Live Activities (system-wide).
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] Skipping: areActivitiesEnabled == false (enable in Settings ▸ Xonora ▸ Live Activities)")
            return
        }

        let manager = PlayerManager.shared
        let player = XonoraClient.shared.currentPlayer

        // END conditions: no player, Mode P (sendspin owns the native card), no track,
        // or playback is fully stopped / errored. Anything here means we hold no activity.
        let shouldEnd = player == nil
            || player?.provider == "sendspin"
            || manager.currentTrack == nil
            || isTerminal(manager.playbackState)

        guard !shouldEnd, let player = player, let track = manager.currentTrack else {
            endActivity()
            // Reset artwork tracking so a future Mode-R track reloads cleanly.
            lastArtworkTrackId = nil
            currentArtworkFileName = nil
            return
        }

        // The activity is bound to one player (attributes are immutable). If the user
        // retargeted to a different speaker, tear the old one down and start fresh.
        if let running = activity, running.attributes.playerId != player.playerId {
            endActivity()
        }

        // Artwork lives in the shared container and loads asynchronously; kick it off
        // when the track changes, then re-reconcile once the bytes are on disk.
        if track.id != lastArtworkTrackId {
            lastArtworkTrackId = track.id
            currentArtworkFileName = nil
            loadArtwork(for: track)
        }

        let state = makeState(track: track, manager: manager)

        if activity == nil {
            // We hold no activity in memory, but ActivityKit activities outlive the app
            // (a rebuild / relaunch doesn't end them). Adopt one that's already running
            // for this player instead of starting a duplicate, and end any strays —
            // otherwise every relaunch orphans the old card and stacks a new one.
            if #available(iOS 16.2, *) {
                adoptOrEndExistingActivities(currentPlayerId: player.playerId)
            }
        }

        if activity == nil {
            startActivity(state: state, player: player)
        } else {
            updateActivity(state: state)
        }
    }

    /// Reconnects to a Live Activity left running from a previous app launch: adopts the
    /// one matching the current player (so reconcile updates it in place) and ends every
    /// other one, so we never stack duplicate cards for the same speaker.
    @available(iOS 16.2, *)
    private func adoptOrEndExistingActivities(currentPlayerId: String) {
        for existing in Activity<XonoraLiveActivityAttributes>.activities {
            if activity == nil && existing.attributes.playerId == currentPlayerId {
                activity = existing
                lastPushedState = existing.content.state
                print("[LiveActivity] Adopted running activity for '\(existing.attributes.playerName)'")
            } else {
                print("[LiveActivity] Ending stray activity for '\(existing.attributes.playerName)'")
                Task { await existing.end(existing.content, dismissalPolicy: .immediate) }
            }
        }
    }

    /// Returns true for playback states where no Live Activity should be shown.
    private func isTerminal(_ state: PlaybackState) -> Bool {
        switch state {
        case .stopped, .error:
            return true
        case .playing, .paused, .loading:
            return false
        }
    }

    @available(iOS 16.1, *)
    private func makeState(track: Track, manager: PlayerManager) -> XonoraLiveActivityAttributes.ContentState {
        XonoraLiveActivityAttributes.ContentState(
            title: track.name,
            artist: track.artistNames,
            album: track.album?.name ?? "",
            artworkFileName: currentArtworkFileName,
            isPlaying: manager.isPlaying,
            duration: manager.duration,
            elapsed: manager.currentTime,
            asOf: Date(),
            isLive: manager.isLiveStream
        )
    }

    // MARK: - Activity lifecycle

    @available(iOS 16.1, *)
    private func startActivity(state: XonoraLiveActivityAttributes.ContentState, player: MAPlayer) {
        let attributes = XonoraLiveActivityAttributes(
            playerName: player.name,
            playerId: player.playerId
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            self.activity = activity
            self.lastPushedState = state
            print("[LiveActivity] Started for '\(player.name)' (\(player.playerId))")
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    @available(iOS 16.1, *)
    private func updateActivity(state: XonoraLiveActivityAttributes.ContentState) {
        guard let activity = activity else { return }

        // Respect the update budget: only push when something actually changed. Artwork
        // arriving mid-track also changes the state (artworkFileName), so this naturally
        // covers the "push the follow-up when artwork finishes loading" requirement.
        guard state != lastPushedState else { return }

        lastPushedState = state
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Ends the running activity, if any, dismissing it immediately.
    private func endActivity() {
        guard #available(iOS 16.1, *) else { return }
        guard let activity = activity else { return }

        // `lastPushedState` is set on every start/update, so it's non-nil whenever an
        // activity exists; the empty fallback is purely defensive.
        let finalState = lastPushedState ?? emptyState()
        self.activity = nil
        self.lastPushedState = nil
        print("[LiveActivity] Ending for '\(activity.attributes.playerName)'")
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    @available(iOS 16.1, *)
    private func emptyState() -> XonoraLiveActivityAttributes.ContentState {
        XonoraLiveActivityAttributes.ContentState(
            title: "",
            artist: "",
            album: "",
            artworkFileName: nil,
            isPlaying: false,
            duration: 0,
            elapsed: 0,
            asOf: Date(),
            isLive: false
        )
    }

    // MARK: - Artwork

    /// Loads artwork for `track` into the shared container, then re-reconciles so the
    /// running activity picks up the file. Guards against the track changing mid-flight.
    private func loadArtwork(for track: Track) {
        let trackId = track.id
        let imageRef = track.imageUrl ?? track.album?.imageUrl
        guard let imageURL = XonoraClient.shared.getImageURL(for: imageRef, size: .small) else {
            return
        }

        Task { [weak self] in
            // Prefer the in-app cache; fall back to a network fetch and warm the cache.
            var image = await ImageCache.shared.image(for: imageURL)
            if image == nil {
                do {
                    let (data, _) = try await URLSession.shared.data(from: imageURL)
                    if let fetched = UIImage(data: data) {
                        await ImageCache.shared.setImage(fetched, for: imageURL)
                        image = fetched
                    }
                } catch {
                    print("[LiveActivity] Artwork fetch failed: \(error)")
                }
            }

            guard let image = image else { return }
            guard let fileName = Self.writeArtwork(image, trackId: trackId) else { return }

            await MainActor.run {
                guard let self = self else { return }
                // The track may have changed while we were loading — bail if so.
                guard self.lastArtworkTrackId == trackId else { return }
                self.currentArtworkFileName = fileName
                // Re-reconcile so the running activity gets the artwork (forces an update
                // because artworkFileName now differs from the last pushed state).
                self.reconcile()
            }
        }
    }

    /// Downscales, JPEG-encodes, and writes `image` to the shared container. Returns the
    /// file name (not the full path) on success.
    nonisolated private static func writeArtwork(_ image: UIImage, trackId: String) -> String? {
        let scaled = downscale(image, maxDimension: 256)
        guard let data = scaled.jpegData(compressionQuality: 0.8) else { return nil }

        let sanitized = sanitize(trackId)
        let fileName = "\(sanitized).jpg"
        guard let url = XonoraShared.artworkURL(for: fileName) else { return nil }

        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            print("[LiveActivity] Artwork write failed: \(error)")
            return nil
        }
    }

    /// Downscales `image` so its longest side is at most `maxDimension` points,
    /// preserving aspect ratio. Returns the original if already small enough.
    nonisolated private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let scale = maxDimension / longest
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Replaces every non-alphanumeric character with `_` so the track id is safe as a
    /// file name.
    nonisolated private static func sanitize(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    // MARK: - Connection settings mirroring

    /// Mirrors the MA connection details into the App Group defaults so the Live
    /// Activity's control intents (which run outside the app's process) can reach the
    /// server while the app is suspended. Empty/nil values clear the stored key.
    func mirrorConnectionSettings(serverURL: String?, accessToken: String?) {
        guard let defaults = XonoraShared.defaults else {
            print("[LiveActivity] App Group defaults unavailable; can't mirror connection settings")
            return
        }

        if let serverURL = serverURL, !serverURL.isEmpty {
            defaults.set(serverURL, forKey: XonoraShared.DefaultsKey.serverURL)
        } else {
            defaults.removeObject(forKey: XonoraShared.DefaultsKey.serverURL)
        }

        if let accessToken = accessToken, !accessToken.isEmpty {
            defaults.set(accessToken, forKey: XonoraShared.DefaultsKey.accessToken)
        } else {
            defaults.removeObject(forKey: XonoraShared.DefaultsKey.accessToken)
        }
    }
}
