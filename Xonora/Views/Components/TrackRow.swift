import SwiftUI

struct TrackRow: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    let track: Track
    let index: Int?
    let showArtwork: Bool
    let isPlaying: Bool
    let numberFirst: Bool
    let onTap: () -> Void

    init(track: Track, index: Int? = nil, showArtwork: Bool = false, isPlaying: Bool = false, numberFirst: Bool = false, onTap: @escaping () -> Void) {
        self.track = track
        self.index = index
        self.showArtwork = showArtwork
        self.isPlaying = isPlaying
        self.numberFirst = numberFirst
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Track number or playing indicator (before artwork if numberFirst is true)
                if numberFirst, let index = index {
                    if isPlaying {
                        NowPlayingBars()
                    } else {
                        Text("\(index)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 24)
                    }
                }

                // Artwork
                if showArtwork {
                    CachedAsyncImage(url: XonoraClient.shared.getImageURL(for: track.imageUrl ?? track.album?.imageUrl, size: .thumbnail)) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: "music.note")
                                    .foregroundColor(.gray)
                            }
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Track number or playing indicator (after artwork if numberFirst is false)
                if !numberFirst, let index = index {
                    if isPlaying {
                        NowPlayingBars()
                    } else {
                        Text("\(index)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 24)
                    }
                }

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.body)
                        .foregroundColor(isPlaying ? .accentColor : .primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        ProviderIcon(provider: track.sourceProvider, size: 12)
                        Text(track.artistNames)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Duration
                Text(track.formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Favorite toggle
                Button {
                    Task {
                        await libraryViewModel.toggleFavorite(item: track)
                    }
                } label: {
                    Image(systemName: (track.favorite ?? false) ? "heart.fill" : "heart")
                        .foregroundColor((track.favorite ?? false) ? .pink : .secondary)
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                // More options menu
                Menu {
                    Button {
                        PlayerManager.shared.playTrack(track)
                    } label: {
                        Label("Play", systemImage: "play")
                    }
                    
                    if let album = track.album {
                        Button {
                            Task {
                                if let tracks = try? await XonoraClient.shared.fetchAlbumTracks(albumId: album.itemId, provider: album.provider) {
                                    await MainActor.run {
                                        PlayerManager.shared.playAlbum(tracks)
                                    }
                                }
                            }
                        } label: {
                            Label("Play Album", systemImage: "opticaldisc")
                        }
                    }

                    Button {
                        PlayerManager.shared.playNext(track)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        PlayerManager.shared.addToQueue(track)
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }

                    Divider()

                    // Play on specific player
                    if !XonoraClient.shared.players.filter({ $0.available }).isEmpty {
                        Menu {
                            ForEach(XonoraClient.shared.players.filter { $0.available }) { player in
                                Button {
                                    print("[TrackRow] Playing '\(track.name)' on player: \(player.name) (id: \(player.playerId))")
                                    XonoraClient.shared.userSelectedPlayer = true
                                    XonoraClient.shared.currentPlayer = player
                                    PlayerManager.shared.playTrack(track)
                                } label: {
                                    HStack {
                                        Image(systemName: player.systemIcon)
                                        Text(player.name)
                                        if player.playerId == XonoraClient.shared.currentPlayer?.playerId {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Play on...", systemImage: "airplayaudio")
                        }
                    }

                    if track.provider != "library" {
                        Button {
                            Task {
                                try? await XonoraClient.shared.addToLibrary(itemId: track.itemId, provider: track.provider)
                            }
                        } label: {
                            Label("Add to Library", systemImage: "plus.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                PlayerManager.shared.playTrack(track)
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                PlayerManager.shared.playNext(track)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                PlayerManager.shared.addToQueue(track)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }

            Divider()

            // Play on specific player submenu
            if !XonoraClient.shared.players.filter({ $0.available }).isEmpty {
                Menu {
                    ForEach(XonoraClient.shared.players.filter { $0.available }) { player in
                        Button {
                            print("[TrackRow] Context menu: Playing '\(track.name)' on player: \(player.name) (id: \(player.playerId))")
                            XonoraClient.shared.userSelectedPlayer = true
                            XonoraClient.shared.currentPlayer = player
                            PlayerManager.shared.playTrack(track)
                        } label: {
                            HStack {
                                Image(systemName: player.systemIcon)
                                Text(player.name)
                                if player.playerId == XonoraClient.shared.currentPlayer?.playerId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Play on...", systemImage: "airplayaudio")
                }
            }

            Divider()

            Button {
                Task {
                    await libraryViewModel.toggleFavorite(item: track)
                }
            } label: {
                Label(
                    (track.favorite ?? false) ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: (track.favorite ?? false) ? "heart.slash" : "heart"
                )
            }

            if track.provider != "library" {
                Button {
                    Task {
                        try? await XonoraClient.shared.addToLibrary(itemId: track.itemId, provider: track.provider)
                    }
                } label: {
                    Label("Add to Library", systemImage: "plus.circle")
                }
            }
        }
    }
}

// MARK: - Now Playing Bars

/// Animated equalizer-style indicator for the currently playing row. Four capsules
/// bounce out of phase, anchored to a common baseline — reads as "audio playing"
/// far better than a pulsing waveform glyph, and works on all supported iOS versions.
struct NowPlayingBars: View {
    var color: Color = .accentColor

    @State private var animating = false

    // Per-bar peak heights and durations; mismatched durations + staggered start
    // delays keep the bars from bouncing in unison.
    private let peakHeights: [CGFloat] = [7, 14, 9, 12]
    private let durations: [Double] = [0.46, 0.55, 0.40, 0.50]
    private let restHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<peakHeights.count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 2.5, height: animating ? peakHeights[index] : restHeight)
                    .animation(
                        .easeInOut(duration: durations[index])
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: animating
                    )
            }
        }
        .frame(width: 24, height: 16)
        .onAppear { animating = true }
        .accessibilityLabel("Now playing")
    }
}

struct TrackRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            TrackRow(
                track: Track(
                    itemId: "1",
                    provider: "apple_music",
                    name: "Sample Track",
                    version: nil,
                    duration: 210,
                    trackNumber: 1,
                    discNumber: 1,
                    uri: "apple_music://track/1",
                    artists: [ArtistReference(itemId: "1", provider: "apple_music", name: "Sample Artist")],
                    album: nil,
                    metadata: nil,
                    providerMappings: nil
                ),
                index: 1,
                isPlaying: false,
                onTap: {}
            )

            TrackRow(
                track: Track(
                    itemId: "2",
                    provider: "apple_music",
                    name: "Currently Playing Track",
                    version: nil,
                    duration: 185,
                    trackNumber: 2,
                    discNumber: 1,
                    uri: "apple_music://track/2",
                    artists: [ArtistReference(itemId: "1", provider: "apple_music", name: "Sample Artist")],
                    album: nil,
                    metadata: nil,
                    providerMappings: nil
                ),
                index: 2,
                isPlaying: true,
                onTap: {}
            )
        }
        .padding()
    }
}
