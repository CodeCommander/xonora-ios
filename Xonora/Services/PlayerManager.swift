import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UserNotifications

enum PlaybackState: Equatable {
    case stopped
    case playing
    case paused
    case loading
    case error(String)
}

enum RepeatMode: Int {
    case off = 0
    case all = 1
    case one = 2
}

@MainActor
class PlayerManager: ObservableObject {
    @Published var playbackState: PlaybackState = .stopped
    @Published var currentTrack: Track?
    @Published var currentTime: TimeInterval = 0 {
        didSet {
            lastUpdateTime = Date()
        }
    }
    @Published var duration: TimeInterval = 0
    @Published var lastUpdateTime: Date = Date()
    @Published var queue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var shuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Float = 1.0
    @Published var currentSource: String?
    @Published var isTransferringPlayback: Bool = false

    // Sleep Timer (persisted to survive app backgrounding)
    @Published var sleepTimerEndTime: Date? {
        didSet {
            // Persist to UserDefaults
            if let endTime = sleepTimerEndTime {
                UserDefaults.standard.set(endTime, forKey: "sleepTimerEndTime")
            } else {
                UserDefaults.standard.removeObject(forKey: "sleepTimerEndTime")
            }
        }
    }
    @Published var sleepTimerRemaining: TimeInterval = 0
    private var sleepTimerUpdateTimer: Timer?
    private static let sleepTimerNotificationId = "xonora.sleepTimer"

    private var progressTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackId: String?
    private var cachedArtwork: MPMediaItemArtwork?

    // Prevent queue advancement race conditions
    private var isUserInitiatedPlay = false
    private var userPlayDebounceTask: Task<Void, Never>?

    static let shared = PlayerManager()

    init() {
        // Setup remote commands and notifications asynchronously to avoid blocking init
        Task {
            await setupRemoteCommandCenter()
            await setupNotifications()
        }

        SendspinClient.shared.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isBuffering in
                guard let self = self else { return }
                if !isBuffering && self.playbackState == .loading {
                    self.playbackState = .playing
                    self.startProgressTimer()
                    print("[PlayerManager] Playback started, progress timer enabled")
                }
            }
            .store(in: &cancellables)

        // Restore sleep timer from UserDefaults
        restoreSleepTimer()

        // Observe app lifecycle for sleep timer
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkSleepTimerOnForeground()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSleepTimerNotification()
        }
    }
    
    private func startProgressTimer() {
        progressTimer?.invalidate()

        // Create timer on main run loop explicitly
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Simply increment by 1 second on main actor
            Task { @MainActor in
                if self.playbackState == .playing {
                    // Manually trigger objectWillChange to ensure SwiftUI views update
                    self.objectWillChange.send()
                    self.currentTime += 1.0

                    if self.duration > 0 && self.currentTime >= self.duration {
                        // Handle end? Server usually sends event.
                    }

                    // Only update now playing info periodically (every 5 seconds) to reduce lock screen thrashing
                    // or when the track changes. The system handles the elapsed time advancement if we set the rate.
                    if Int(self.currentTime) % 5 == 0 {
                        self.updateNowPlayingInfo()
                    }
                }
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.play()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.previous()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seek(to: positionEvent.positionTime)
            }
            return .success
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .queueUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self, let userInfo = notification.userInfo else { return }

                // Ignore events during player transfer to prevent state thrashing
                if self.isTransferringPlayback {
                    print("[PlayerManager] Ignoring queue event during player transfer")
                    // Still update duration if available
                    if let currentItem = userInfo["current_item"] as? [String: Any],
                       let duration = currentItem["duration"] as? Int {
                        self.duration = TimeInterval(duration)
                    }
                    return
                }

                // Ignore events during user-initiated play to prevent race conditions
                if self.isUserInitiatedPlay {
                    // Still update duration if available
                    if let currentItem = userInfo["current_item"] as? [String: Any],
                       let duration = currentItem["duration"] as? Int {
                        self.duration = TimeInterval(duration)
                    }
                    return
                }

                if let elapsed = userInfo["elapsed_time"] as? Double {
                    self.currentTime = elapsed
                }

                if let stateStr = userInfo["state"] as? String {
                    print("[PlayerManager] Queue event - state: '\(stateStr)', current playbackState: \(self.playbackState)")
                    if stateStr == "playing" {
                        self.playbackState = .playing
                        self.startProgressTimer()
                        SendspinClient.shared.resumePlayback()
                    } else if stateStr == "paused" {
                        self.playbackState = .paused
                        self.stopProgressTimer()
                        SendspinClient.shared.pausePlayback()
                    } else if stateStr == "idle" {
                        // Only handle track ended if we were actually playing
                        if self.playbackState == .playing {
                            self.handleTrackEnded()
                            SendspinClient.shared.stopPlayback()
                        } else {
                            print("[PlayerManager] Ignoring idle state (not currently playing, state was: \(self.playbackState))")
                        }
                    } else {
                        print("[PlayerManager] Unknown state '\(stateStr)', stopping playback")
                        self.playbackState = .stopped
                        self.stopProgressTimer()
                        SendspinClient.shared.stopPlayback()
                    }
                }

                // Handle current item updates (auto-advance)
                if let currentItem = userInfo["current_item"] as? [String: Any] {
                    // Update duration
                    if let duration = currentItem["duration"] as? Int {
                        self.duration = TimeInterval(duration)
                    } else if let duration = currentItem["duration"] as? Double {
                        self.duration = duration
                    }

                    // Update current track if it changed
                    if let mediaItemDict = currentItem["media_item"] as? [String: Any] {
                        do {
                            let data = try JSONSerialization.data(withJSONObject: mediaItemDict)
                            let track = try JSONDecoder().decode(Track.self, from: data)
                            if self.currentTrack?.uri != track.uri {
                                print("[PlayerManager] Server advanced to next track: \(track.name)")
                                self.currentTrack = track
                                self.currentTime = 0
                                // Reset lastTrackId to trigger artwork reload
                                self.lastTrackId = nil
                            }
                        } catch {
                            print("[PlayerManager] Failed to decode track from server: \(error)")
                        }
                    }
                }

                self.updateNowPlayingInfo()
            }
            .store(in: &cancellables)
    }

    private func handleTrackEnded() {
        // Don't auto-advance - let server handle queue
        // We only update UI state here
        playbackState = .stopped
        stopProgressTimer()
        print("[PlayerManager] Track ended")
    }



    // MARK: - Playback Control

    func playTrack(_ track: Track, fromQueue tracks: [Track]? = nil, sourceName: String? = nil) {
        if let tracks = tracks {
            queue = tracks
            currentIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        } else {
            // If no queue context provided, play just this track
            queue = [track]
            currentIndex = 0
        }
        
        self.currentSource = sourceName

        guard SendspinClient.shared.isConnected else {
            print("[PlayerManager] ERROR: Sendspin not connected")
            playbackState = .error("Sendspin not connected. Please enable it in Settings.")
            return
        }

        let targetPlayer = XonoraClient.shared.currentPlayer
        print("[PlayerManager] Playing: '\(track.name)' on player: '\(targetPlayer?.name ?? "NONE")' (id: \(targetPlayer?.playerId ?? "nil"))")

        // Force Shuffle OFF for direct track selection to ensure the selected track plays
        self.shuffleEnabled = false
        Task { try? await XonoraClient.shared.setShuffle(enabled: false) }

        // Sync Repeat Mode to ensure server matches client state (fixes stuck repeat issues)
        let modeString: String
        switch repeatMode {
        case .off: modeString = "off"
        case .all: modeString = "all"
        case .one: modeString = "one"
        }
        Task { try? await XonoraClient.shared.setRepeat(mode: modeString) }

        // Set debounce flag to ignore server events temporarily
        isUserInitiatedPlay = true
        userPlayDebounceTask?.cancel()
        userPlayDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await MainActor.run {
                self.isUserInitiatedPlay = false
            }
        }

        currentTrack = track
        currentTime = 0
        duration = track.duration ?? 0
        playbackState = .loading

        SendspinClient.shared.stopPlayback()
        stopProgressTimer()
        Task {
            await self.updateNowPlayingInfoAsync()
        }

        // Prepare URIs to play (current track + limited upcoming items)
        // Limit to 20 tracks to avoid sending huge payloads - server handles queue advancement
        let maxTracksToSend = 20
        let uris: [String]
        if !queue.isEmpty && currentIndex < queue.count {
            let endIndex = min(currentIndex + maxTracksToSend, queue.count)
            uris = Array(queue[currentIndex..<endIndex]).map { $0.uri }
        } else {
            uris = [track.uri]
        }

        // Tell server to play this track
        Task {
            do {
                try await XonoraClient.shared.playMedia(uris: uris)
            } catch {
                print("[PlayerManager] Failed to send play command: \(error)")
                
                // Suppress "Request timeout" error if it happens, as it often means the server 
                // processed the command but the acknowledgement was lost/delayed, while music plays fine.
                let nsError = error as NSError
                if nsError.code == -1 && nsError.userInfo[NSLocalizedDescriptionKey] as? String == "Request timeout" {
                    print("[PlayerManager] Suppressing Request timeout error.")
                    return
                }
                
                await MainActor.run {
                    self.playbackState = .error("Failed to play: \(error.localizedDescription)")
                }
            }
        }
    }

    func play() {
        Task {
            try? await XonoraClient.shared.play()
        }
    }

    func pause() {
        Task {
            try? await XonoraClient.shared.pause()
        }
    }

    func togglePlayPause() {
        Task {
            try? await XonoraClient.shared.playPause()
        }
    }

    func stop() {
        Task {
            try? await XonoraClient.shared.stop()
        }
        currentTrack = nil
        currentTime = 0
        duration = 0
        playbackState = .stopped
        stopProgressTimer()
        clearNowPlayingInfo()
    }

    func next() {
        guard !queue.isEmpty else { return }

        // Always advance sequentially. Shuffle is handled by reordering the queue itself.
        currentIndex = (currentIndex + 1) % queue.count

        let nextTrack = queue[currentIndex]
        playTrack(nextTrack, fromQueue: queue, sourceName: currentSource)
    }

    func previous() {
        // If we are more than 3 seconds into the track, restart it
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        guard !queue.isEmpty else { return }

        // Check if we are at the start of the queue
        if currentIndex > 0 {
            currentIndex -= 1
        } else {
            // Wrap around to the last track
            currentIndex = queue.count - 1
        }

        let previousTrack = queue[currentIndex]
        playTrack(previousTrack, fromQueue: queue, sourceName: currentSource)
    }

    func seek(to time: TimeInterval) {
        if SendspinClient.shared.isConnected {
            Task { try? await XonoraClient.shared.seek(position: time) }
        }
        currentTime = time
        Task {
            await self.updateNowPlayingInfoAsync()
        }
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        if SendspinClient.shared.isConnected {
            Task { try? await XonoraClient.shared.setVolume(Int(newVolume * 100)) }
        }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        Task { try? await XonoraClient.shared.setShuffle(enabled: shuffleEnabled) }
        
        guard !queue.isEmpty else { return }
        
        if shuffleEnabled {
            // Shuffle the queue, ensuring current track stays playing
            var tracks = queue
            if let current = currentTrack, let idx = tracks.firstIndex(where: { $0.id == current.id }) {
                tracks.remove(at: idx)
                tracks.shuffle()
                tracks.insert(current, at: 0)
                currentIndex = 0
            } else {
                tracks.shuffle()
                currentIndex = 0
            }
            queue = tracks
        } else {
            // Restore album order (approximate by sorting)
            var tracks = queue
            tracks.sort {
                let disc1 = $0.discNumber ?? 1
                let disc2 = $1.discNumber ?? 1
                if disc1 != disc2 { return disc1 < disc2 }
                return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
            }
            queue = tracks
            
            // Update currentIndex to match current track's new position
            if let current = currentTrack {
                currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
            }
        }
    }

    func cycleRepeatMode() {
        let nextRaw = (repeatMode.rawValue + 1) % 3
        repeatMode = RepeatMode(rawValue: nextRaw) ?? .off

        let modeString: String
        switch repeatMode {
        case .off: modeString = "off"
        case .all: modeString = "all"
        case .one: modeString = "one"
        }

        Task { try? await XonoraClient.shared.setRepeat(mode: modeString) }
    }

    /// Retarget the remote at `player` and reflect ITS current state.
    /// No audio is moved or copied: the now-playing card shows whatever the
    /// target is actually playing, or clears to stopped if it's idle. This is
    /// what a plain tap on a player selector should do (XON-008).
    ///
    /// Note: an idle player never broadcasts a `queue_updated` event, so we must
    /// *pull* its state via `fetchQueueFromServer` rather than wait for one.
    func selectPlayer(_ player: MAPlayer) {
        guard player.playerId != XonoraClient.shared.currentPlayer?.playerId else { return }

        print("[PlayerManager] Selecting (retarget) player: '\(player.name)' (id: \(player.playerId))")

        // Prevent auto-selection from overriding the user's choice.
        XonoraClient.shared.userSelectedPlayer = true
        XonoraClient.shared.currentPlayer = player

        // Pull the target's real queue + state and reflect it in the card.
        Task { await fetchQueueFromServer(for: player) }
    }

    /// Move the currently-playing track/queue onto `player` and STOP the source,
    /// so playback follows you to the new room instead of duplicating. Offered
    /// via long-press, not a plain tap. If nothing is playing, this degrades to
    /// a plain retarget.
    func movePlaybackHere(to player: MAPlayer) {
        let oldPlayer = XonoraClient.shared.currentPlayer
        let wasPlaying = isPlaying
        let savedTrack = currentTrack
        let savedPosition = currentTime
        let savedQueue = queue
        let savedIndex = currentIndex
        let savedSource = currentSource

        guard player.playerId != oldPlayer?.playerId else { return }

        // Nothing to move — just retarget and reflect the target.
        guard let track = savedTrack else {
            selectPlayer(player)
            return
        }

        // Set transfer flag to ignore transient state changes during the switch.
        isTransferringPlayback = true

        print("[PlayerManager] Moving playback '\(track.name)': '\(oldPlayer?.name ?? "none")' -> '\(player.name)' (was playing: \(wasPlaying))")

        // Mark as user-selected to prevent auto-selection from overriding.
        XonoraClient.shared.userSelectedPlayer = true
        XonoraClient.shared.currentPlayer = player

        // Restore queue state and play the track on the new player.
        queue = savedQueue
        currentIndex = savedIndex
        currentSource = savedSource
        playTrack(track, fromQueue: savedQueue, sourceName: savedSource)

        // Seek to the saved position after a short delay to let playback start.
        // Only seek if we had meaningful progress (more than 2 seconds).
        if savedPosition > 2 {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                if self.currentTrack?.uri == track.uri {
                    print("[PlayerManager] Seeking to saved position: \(savedPosition)s")
                    self.seek(to: savedPosition)
                }
            }
        }

        // Stop the source so we don't leave two rooms playing the same thing.
        if let old = oldPlayer {
            print("[PlayerManager] Stopping source player '\(old.name)' after move")
            Task { try? await XonoraClient.shared.stopPlayer(old.playerId) }
        }

        // Clear transfer flag after a delay to allow the server to stabilize.
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self.isTransferringPlayback = false
        }
    }

    /// Group `player` with the current player so they play in sync (MA grouping).
    /// Offered via long-press; the current player becomes the sync-group leader.
    /// Failures surface an alert rather than failing silently (MA sync reliability
    /// varies by provider). NOTE: if the app's selected player has drifted from
    /// the player MA actually has playing, grouping the live player under a silent
    /// leader can stop both — the underlying reflect drift is still open (XON-007/008).
    func syncPlaybackHere(to player: MAPlayer) {
        guard let leader = XonoraClient.shared.currentPlayer,
              leader.playerId != player.playerId else { return }

        print("[PlayerManager] Syncing '\(player.name)' with leader '\(leader.name)'")
        Task {
            do {
                try await XonoraClient.shared.groupPlayer(player.playerId, withTarget: leader.playerId)
            } catch {
                playbackState = .error("Couldn't sync \(player.name) with \(leader.name): \(errorReason(error))")
            }
        }
    }

    /// Removes a single member from its sync group ("Stop Playback Here"): that
    /// player leaves the group and stops, the rest keep playing. Surfaces failures.
    func ungroupPlayer(_ player: MAPlayer) {
        print("[PlayerManager] Ungrouping '\(player.name)' from its group")
        Task {
            do {
                try await XonoraClient.shared.ungroupPlayer(player.playerId)
            } catch {
                playbackState = .error("Couldn't remove \(player.name) from the group: \(errorReason(error))")
            }
        }
    }

    /// Makes `player` the only speaker producing audio ("Play Here Only"):
    /// - **Leader** (has `group_childs`): drop every member; the leader keeps playing.
    /// - **Member** (`synced_to` set): take playback over to it and stop the rest of
    ///   the group (see `promoteMemberToSolePlayer`).
    ///
    /// Each step is awaited and checked; any failure surfaces a "Playback Error"
    /// alert (via `playbackState = .error`) rather than failing silently.
    func playHereOnly(_ player: MAPlayer) {
        if player.isGroupLeader {
            Task { await disbandGroup(ledBy: player) }
        } else if let leaderId = player.syncedTo {
            Task { await promoteMemberToSolePlayer(player, leaderId: leaderId) }
        }
    }

    /// Disbands the sync group led by `leader`: ungroup every member, surfacing the
    /// first failure to the user. The leader keeps playing.
    private func disbandGroup(ledBy leader: MAPlayer) async {
        let children = leader.groupMembers ?? []
        guard !children.isEmpty else { return }

        print("[PlayerManager] Play here only — disbanding group led by '\(leader.name)' (\(children.count) member(s))")
        do {
            for childId in children {
                try await XonoraClient.shared.ungroupPlayer(childId)
            }
        } catch {
            playbackState = .error("Couldn't ungroup the speakers on \(leader.name): \(errorReason(error))")
        }
    }

    /// Promotes a synced member to the sole player. Sequenced and checked:
    ///   1. Stop the leader (and, by extension, its synced members).
    ///   2. Ungroup every member of the old group — await + verify each — so the
    ///      target is independent and the others won't keep playing.
    ///   3. Send the saved queue to the now-unsynced target.
    /// Any failure aborts and surfaces a "Playback Error" alert.
    private func promoteMemberToSolePlayer(_ player: MAPlayer, leaderId: String) async {
        // A synced member owns no queue (it lives on the leader), so we capture the
        // current playback and re-issue it on the target after detaching.
        guard let track = currentTrack else {
            // Nothing playing — just retarget and reflect.
            selectPlayer(player)
            return
        }
        let savedQueue = queue
        let savedIndex = currentIndex
        let savedSource = currentSource
        let savedPosition = currentTime

        // Every player in the old group (target + siblings). Stopping/ungrouping
        // these leaves only the target, which we then start.
        let leader = XonoraClient.shared.players.first { $0.playerId == leaderId }
        let groupMembers = leader?.groupMembers ?? [player.playerId]

        isTransferringPlayback = true
        print("[PlayerManager] Play here only — promoting member '\(player.name)' to sole player")

        do {
            // 1. Stop the leader so the whole synced group goes quiet.
            try await XonoraClient.shared.stopPlayer(leaderId)

            // 2. Ungroup every member (incl. target) so each is independent + idle,
            //    then detach the leader itself in case MA keeps a 1-player group.
            for memberId in groupMembers {
                try await XonoraClient.shared.ungroupPlayer(memberId)
            }
            try await XonoraClient.shared.ungroupPlayer(leaderId)

            // 3. Target is now unsynced — send it the fresh queue.
            XonoraClient.shared.userSelectedPlayer = true
            XonoraClient.shared.currentPlayer = player
            let uris = upcomingURIs(from: savedQueue, startingAt: savedIndex, fallback: track)
            try await XonoraClient.shared.playMedia(uris: uris)

            // Reflect the new state locally.
            queue = savedQueue
            currentIndex = savedIndex
            currentSource = savedSource
            currentTrack = track
            currentTime = 0
            playbackState = .playing
            startProgressTimer()
            updateNowPlayingInfo()

            // Re-seek to where we were, once playback has had a moment to start.
            if savedPosition > 2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if currentTrack?.uri == track.uri {
                    seek(to: savedPosition)
                }
            }
        } catch {
            // A lost-ack timeout on the final play usually means it worked anyway
            // (matches playTrack's behavior); anything else is a real failure to show.
            let nsError = error as NSError
            let isBenignTimeout = nsError.code == -1
                && (nsError.userInfo[NSLocalizedDescriptionKey] as? String) == "Request timeout"
            if isBenignTimeout {
                print("[PlayerManager] Play here only — suppressing benign play timeout")
                currentPlayerDidTakeOver(player, track: track, queue: savedQueue, index: savedIndex, source: savedSource)
            } else {
                playbackState = .error("Couldn't move playback to \(player.name): \(errorReason(error))")
            }
        }

        isTransferringPlayback = false
    }

    /// Local-state bookkeeping when the target player has taken over playback.
    private func currentPlayerDidTakeOver(_ player: MAPlayer, track: Track, queue savedQueue: [Track], index: Int, source: String?) {
        XonoraClient.shared.userSelectedPlayer = true
        XonoraClient.shared.currentPlayer = player
        queue = savedQueue
        currentIndex = index
        currentSource = source
        currentTrack = track
        playbackState = .playing
        startProgressTimer()
        updateNowPlayingInfo()
    }

    /// The URIs to send when (re)starting a queue: the current track plus a bounded
    /// window of upcoming items (the server handles advancement beyond that).
    private func upcomingURIs(from queue: [Track], startingAt index: Int, fallback track: Track) -> [String] {
        let maxTracksToSend = 20
        guard !queue.isEmpty, index >= 0, index < queue.count else { return [track.uri] }
        let endIndex = min(index + maxTracksToSend, queue.count)
        return Array(queue[index..<endIndex]).map { $0.uri }
    }

    /// Human-readable reason from a thrown command error, for user-facing alerts.
    private func errorReason(_ error: Error) -> String {
        let nsError = error as NSError
        return (nsError.userInfo[NSLocalizedDescriptionKey] as? String) ?? error.localizedDescription
    }

    /// Fetches the queue from the server for a specific player
    func fetchQueueFromServer(for player: MAPlayer) async {
        print("[PlayerManager] Fetching queue from server for '\(player.name)'")

        do {
            // Fetch queue items
            let tracks = try await XonoraClient.shared.fetchQueueItems(for: player.playerId)

            // Fetch queue state (current index, elapsed time)
            let state = try await XonoraClient.shared.fetchQueueState(for: player.playerId)

            await MainActor.run {
                if tracks.isEmpty {
                    // Target player is idle/empty — reflect that honestly rather than
                    // leaving the previous player's track frozen on the card (XON-008).
                    print("[PlayerManager] Server queue is empty — clearing now playing")
                    self.queue = []
                    self.currentTrack = nil
                    self.currentTime = 0
                    self.duration = 0
                    self.playbackState = .stopped
                    self.stopProgressTimer()
                    self.clearNowPlayingInfo()
                } else {
                    print("[PlayerManager] Loaded \(tracks.count) tracks from server queue")
                    self.queue = tracks
                    self.currentIndex = min(state.currentIndex, tracks.count - 1)
                    self.currentTime = state.elapsedTime

                    // Set current track from queue
                    if self.currentIndex < tracks.count {
                        self.currentTrack = tracks[self.currentIndex]
                    }

                    // Update playback state based on server state, and keep the
                    // progress timer + now-playing card in sync with it.
                    switch state.state {
                    case "playing":
                        self.playbackState = .playing
                        self.startProgressTimer()
                    case "paused":
                        self.playbackState = .paused
                        self.stopProgressTimer()
                    default:
                        self.playbackState = .stopped
                        self.stopProgressTimer()
                    }

                    self.updateNowPlayingInfo()
                }
            }
        } catch {
            print("[PlayerManager] Failed to fetch queue: \(error)")
        }
    }

    // MARK: - Queue Management

    func addToQueue(_ track: Track) {
        queue.append(track)
    }

    func addToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks)
    }

    func playNext(_ track: Track) {
        queue.insert(track, at: currentIndex + 1)
    }

    func clearQueue() {
        queue.removeAll()
        currentIndex = 0
    }

    func playAlbum(_ tracks: [Track], startingAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        let albumName = tracks[index].album?.name
        queue = tracks
        currentIndex = index
        playTrack(tracks[index], fromQueue: tracks, sourceName: albumName)
    }

    // MARK: - Sleep Timer

    /// Sets a sleep timer for the specified duration in minutes
    func setSleepTimer(minutes: Int) {
        setSleepTimer(seconds: TimeInterval(minutes * 60))
    }

    /// Sets a sleep timer for a custom duration in seconds
    func setSleepTimer(seconds: TimeInterval) {
        cancelSleepTimer()

        sleepTimerEndTime = Date().addingTimeInterval(seconds)
        sleepTimerRemaining = seconds

        let minutes = Int(seconds) / 60
        print("[PlayerManager] Sleep timer set for \(minutes) minutes (ends at \(sleepTimerEndTime!))")

        // Request notification permission for background timer
        requestNotificationPermission()

        // Start the UI update timer
        startSleepTimerUpdateLoop()
    }

    /// Cancels the current sleep timer
    func cancelSleepTimer() {
        sleepTimerUpdateTimer?.invalidate()
        sleepTimerUpdateTimer = nil
        sleepTimerEndTime = nil
        sleepTimerRemaining = 0

        // Cancel any scheduled notification
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.sleepTimerNotificationId]
        )

        print("[PlayerManager] Sleep timer cancelled")
    }

    /// Returns true if a sleep timer is currently active
    var isSleepTimerActive: Bool {
        guard let endTime = sleepTimerEndTime else { return false }
        return endTime > Date()
    }

    /// Formatted string for the remaining sleep timer time
    var sleepTimerRemainingFormatted: String {
        guard sleepTimerRemaining > 0 else { return "" }

        let hours = Int(sleepTimerRemaining) / 3600
        let minutes = (Int(sleepTimerRemaining) % 3600) / 60
        let seconds = Int(sleepTimerRemaining) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// Restore sleep timer from UserDefaults on app launch
    private func restoreSleepTimer() {
        if let savedEndTime = UserDefaults.standard.object(forKey: "sleepTimerEndTime") as? Date {
            if savedEndTime > Date() {
                // Timer hasn't expired yet
                sleepTimerEndTime = savedEndTime
                sleepTimerRemaining = savedEndTime.timeIntervalSinceNow
                startSleepTimerUpdateLoop()
                print("[PlayerManager] Restored sleep timer - \(Int(sleepTimerRemaining / 60)) minutes remaining")
            } else {
                // Timer expired while app was closed - fire it now
                print("[PlayerManager] Sleep timer expired while app was closed - pausing now")
                UserDefaults.standard.removeObject(forKey: "sleepTimerEndTime")
                sleepTimerFired()
            }
        }
    }

    /// Check sleep timer when app comes to foreground
    private func checkSleepTimerOnForeground() {
        guard let endTime = sleepTimerEndTime else { return }

        if endTime <= Date() {
            // Timer expired while in background
            print("[PlayerManager] Sleep timer expired in background - pausing now")
            sleepTimerFired()
        } else {
            // Timer still active, update remaining and restart update loop
            sleepTimerRemaining = endTime.timeIntervalSinceNow
            startSleepTimerUpdateLoop()
        }

        // Cancel notification since we're now in foreground
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.sleepTimerNotificationId]
        )
    }

    /// Schedule a notification to fire when timer expires (for background)
    private func scheduleSleepTimerNotification() {
        guard let endTime = sleepTimerEndTime, endTime > Date() else { return }

        // Stop the update timer when going to background
        sleepTimerUpdateTimer?.invalidate()
        sleepTimerUpdateTimer = nil

        let content = UNMutableNotificationContent()
        content.title = "Sleep Timer"
        content.body = "Stopping playback..."
        content.sound = nil // Silent

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: endTime.timeIntervalSinceNow,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: Self.sleepTimerNotificationId,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[PlayerManager] Failed to schedule sleep timer notification: \(error)")
            } else {
                print("[PlayerManager] Scheduled background sleep timer notification")
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if granted {
                print("[PlayerManager] Notification permission granted for sleep timer")
            }
        }
    }

    private func startSleepTimerUpdateLoop() {
        sleepTimerUpdateTimer?.invalidate()

        sleepTimerUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSleepTimerRemaining()
            }
        }
    }

    private func updateSleepTimerRemaining() {
        guard let endTime = sleepTimerEndTime else {
            sleepTimerRemaining = 0
            return
        }

        let remaining = endTime.timeIntervalSinceNow
        if remaining > 0 {
            sleepTimerRemaining = remaining
        } else {
            // Timer expired
            sleepTimerFired()
        }
    }

    private func sleepTimerFired() {
        print("[PlayerManager] Sleep timer fired - stopping playback")

        // Clean up timer state first
        sleepTimerUpdateTimer?.invalidate()
        sleepTimerUpdateTimer = nil
        sleepTimerEndTime = nil
        sleepTimerRemaining = 0

        // Stop playback on the server with retries
        Task {
            await stopPlaybackWithRetry(maxAttempts: 3)
        }

        playbackState = .paused
    }

    private func stopPlaybackWithRetry(maxAttempts: Int) async {
        for attempt in 1...maxAttempts {
            do {
                try await XonoraClient.shared.stop()
                print("[PlayerManager] Sleep timer: stopped (attempt \(attempt))")
                return
            } catch {
                print("[PlayerManager] Sleep timer: stop failed \(attempt)/\(maxAttempts) - \(error)")
                do {
                    try await XonoraClient.shared.pause()
                    print("[PlayerManager] Sleep timer: paused (attempt \(attempt))")
                    return
                } catch {
                    print("[PlayerManager] Sleep timer: pause failed \(attempt)/\(maxAttempts)")
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        print("[PlayerManager] Sleep timer: failed after \(maxAttempts) attempts")
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        Task { await updateNowPlayingInfoAsync() }
    }

    private func clearNowPlayingInfo() {
        lastTrackId = nil
        cachedArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // Drive the system playback state to .stopped so iOS relinquishes the slot cleanly.
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Maps our internal playback state to the system's now-playing state.
    /// iOS requires this to be set explicitly for apps that don't drive an AVPlayer
    /// (we remote-control players / use SendspinKit's AVAudioEngine); without it the
    /// lock-screen Now Playing card appears then intermittently disappears (XON-010).
    private var systemPlaybackState: MPNowPlayingPlaybackState {
        switch playbackState {
        case .playing: return .playing
        case .paused: return .paused
        case .loading: return .playing
        case .stopped, .error: return .stopped
        }
    }

    private func updateNowPlayingInfoAsync() async {
        guard let track = currentTrack else { return }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artistNames
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = track.album?.name ?? ""

        await MainActor.run {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = self.duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.currentTime
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = self.playbackState == .playing ? 1.0 : 0.0
        }

        if track.id != lastTrackId {
            await MainActor.run {
                self.lastTrackId = track.id
                self.cachedArtwork = nil
            }

            if let imageURLString = track.imageUrl ?? track.album?.imageUrl,
               let imageURL = XonoraClient.shared.getImageURL(for: imageURLString, size: .medium) {
                let artwork = await loadArtworkAsync(from: imageURL, trackId: track.id)
                if let artwork = artwork {
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                }
            }
        } else {
            let artwork = await MainActor.run { self.cachedArtwork }
            if let artwork = artwork {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
        }

        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            // Keep the system playback state in lockstep so iOS keeps the slot (XON-010).
            MPNowPlayingInfoCenter.default().playbackState = self.systemPlaybackState
            // Live streams can't be scrubbed — drop the lock-screen seek bar for them.
            MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !self.isLiveStream
        }
    }

    private func loadArtworkAsync(from url: URL, trackId: String) async -> MPMediaItemArtwork? {
        if let cachedImage = await ImageCache.shared.image(for: url) {
            let artwork = MPMediaItemArtwork(boundsSize: cachedImage.size) { _ in cachedImage }
            await MainActor.run {
                guard self.currentTrack?.id == trackId else { return }
                self.cachedArtwork = artwork
            }
            return artwork
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }

            await ImageCache.shared.setImage(image, for: url)

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard self.currentTrack?.id == trackId else { return }
                self.cachedArtwork = artwork
            }
            return artwork
        } catch {
            print("[PlayerManager] Failed to load artwork: \(error)")
            return nil
        }
    }

    // MARK: - State Helpers

    var isPlaying: Bool {
        if case .playing = playbackState {
            return true
        }
        return false
    }

    /// True when the current item is a live stream (radio): MA reports it as
    /// media_type "radio" and it carries no fixed, seekable duration. Such items
    /// have no meaningful "time remaining" and can't be scrubbed. The duration
    /// fallback covers payloads that omit the media type.
    var isLiveStream: Bool {
        guard currentTrack != nil else { return false }
        if currentTrack?.mediaType == "radio" { return true }
        return duration <= 0
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
}
