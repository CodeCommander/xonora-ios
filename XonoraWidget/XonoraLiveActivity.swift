import SwiftUI
import WidgetKit
import ActivityKit
import UIKit

// Now Playing Live Activity for a remote Music Assistant speaker (Mode R — the
// phone is a remote only). Progress renders from the State's elapsed/asOf anchor so
// the bar and clocks self-advance without per-second pushes.

@available(iOS 16.2, *)
struct XonoraLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: XonoraLiveActivityAttributes.self) { context in
            // Lock screen / banner presentation.
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.25))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArtworkView(fileName: state.artworkFileName, size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.playerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(state.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ProgressBar(state: state)
                        ControlsRow(playerId: context.attributes.playerId,
                                    isPlaying: state.isPlaying,
                                    spacing: 28)
                    }
                }
            } compactLeading: {
                ArtworkView(fileName: state.artworkFileName, size: 20)
            } compactTrailing: {
                PlayPauseButton(playerId: context.attributes.playerId,
                                isPlaying: state.isPlaying)
            } minimal: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .keylineTint(.accentColor)
        }
    }
}

// MARK: - Lock screen / banner

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<XonoraLiveActivityAttributes>

    private var state: XonoraLiveActivityAttributes.ContentState { context.state }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(fileName: state.artworkFileName, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Playing on \(context.attributes.playerName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressBar(state: state)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomTrailing) {
            ControlsRow(playerId: context.attributes.playerId,
                        isPlaying: state.isPlaying,
                        spacing: 22)
        }
        .padding(14)
    }
}

// MARK: - Progress

@available(iOS 16.2, *)
private struct ProgressBar: View {
    let state: XonoraLiveActivityAttributes.ContentState

    var body: some View {
        if state.isLive {
            LiveBadge()
        } else if state.isPlaying && state.duration > 0 {
            // Self-advancing bar + clocks driven by the anchor window; no pushes needed.
            VStack(spacing: 2) {
                ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .labelsHidden()
                HStack {
                    Text(timerInterval: state.startDate...state.endDate, countsDown: false)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(timerInterval: state.startDate...state.endDate, countsDown: true)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } else {
            // Paused (or unknown duration): freeze the bar and show static MM:SS.
            VStack(spacing: 2) {
                ProgressView(value: state.staticProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .labelsHidden()
                if state.duration > 0 {
                    HStack {
                        Text(formatTime(state.elapsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(formatTime(max(state.duration - state.elapsed, 0)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

@available(iOS 16.2, *)
private struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red, in: Capsule())
    }
}

// MARK: - Controls

@available(iOS 16.2, *)
private struct ControlsRow: View {
    let playerId: String
    let isPlaying: Bool
    var spacing: CGFloat = 24

    var body: some View {
        HStack(spacing: spacing) {
            Button(intent: PreviousTrackIntent(playerId: playerId)) {
                Image(systemName: "backward.fill")
            }
            Button(intent: TogglePlayPauseIntent(playerId: playerId)) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            Button(intent: NextTrackIntent(playerId: playerId)) {
                Image(systemName: "forward.fill")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.primary)
    }
}

/// Standalone play/pause control used in the Dynamic Island compact trailing slot.
@available(iOS 16.2, *)
private struct PlayPauseButton: View {
    let playerId: String
    let isPlaying: Bool

    var body: some View {
        Button(intent: TogglePlayPauseIntent(playerId: playerId)) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artwork

@available(iOS 16.2, *)
private struct ArtworkView: View {
    let fileName: String?
    let size: CGFloat

    private var cornerRadius: CGFloat { max(size * 0.18, 4) }

    var body: some View {
        Group {
            if let image = loadArtwork(for: fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.45, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Helpers

/// Loads artwork bytes off the App Group disk. Live Activity views can't fetch remote
/// images at render time, so the app must have already written the file there.
private func loadArtwork(for fileName: String?) -> UIImage? {
    guard let fileName, !fileName.isEmpty,
          let url = XonoraShared.artworkURL(for: fileName) else { return nil }
    return UIImage(contentsOfFile: url.path)
}

/// Formats a non-negative number of seconds as `M:SS` (or `H:MM:SS` past an hour).
private func formatTime(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}
