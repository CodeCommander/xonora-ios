import SwiftUI

struct PlaylistGridItem: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A clear square sizer fixes the cell to 1:1 at the column width; the
            // artwork fills it via overlay and is hard-clipped, so non-square mosaic
            // covers (common for playlists) can't bleed out of the cell.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    CachedAsyncImage(url: XonoraClient.shared.getImageURL(for: playlist.imageUrl, size: .small)) {
                        playlistPlaceholder
                    }
                    .aspectRatio(contentMode: .fill)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    ProviderIcon(provider: playlist.sourceProvider, size: 12)
                    Text("Playlist")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var playlistPlaceholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundColor(.gray)
            }
    }
}
