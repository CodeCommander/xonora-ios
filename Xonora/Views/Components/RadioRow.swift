import SwiftUI

/// A tappable row for a radio station. Stations have no track list — tapping a
/// row plays the stream immediately, so the row carries a play affordance rather
/// than a disclosure chevron.
struct RadioRow: View {
    let radio: Radio
    var isPlaying: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: XonoraClient.shared.getImageURL(for: radio.imageUrl, size: .thumbnail)) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundColor(.gray)
                        }
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(radio.name)
                        .font(.body)
                        .foregroundColor(isPlaying ? .accentColor : .primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        ProviderIcon(provider: radio.sourceProvider, size: 12)
                        Text("Radio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                    .font(.title3)
                    .foregroundColor(isPlaying ? .accentColor : .secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
