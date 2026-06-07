import Foundation

struct Track: Identifiable, Codable, Hashable {
    let itemId: String
    let provider: String
    let name: String
    let version: String?
    /// MA media type ("track", "radio", …). Used to tell live streams apart from
    /// seekable tracks, since radio carries no fixed/seekable duration.
    let mediaType: String?
    let duration: TimeInterval?
    let trackNumber: Int?
    let discNumber: Int?
    let uri: String
    let artists: [ArtistReference]?
    let album: AlbumReference?
    let metadata: MediaItemMetadata?
    let providerMappings: [ProviderMapping]?
    var favorite: Bool?

    var id: String { itemId }

    var artistNames: String {
        artists?.map { $0.name }.joined(separator: ", ") ?? "Unknown Artist"
    }

    var imageUrl: String? {
        metadata?.images?.first(where: { $0.type == "thumb" })?.path ?? 
        metadata?.images?.first?.path
    }

    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Returns the source provider (e.g., apple_music, spotify) extracted from URI or provider mappings
    /// This is useful when items are in the library but originally come from a streaming service
    var sourceProvider: String {
        // First try to extract from URI (e.g., "apple_music://track/123" -> "apple_music")
        if let scheme = URL(string: uri)?.scheme,
           !scheme.isEmpty && scheme != "library" && scheme != "file" {
            return scheme
        }
        // Then try provider mappings
        if let mapping = providerMappings?.first(where: { $0.providerDomain != "library" && $0.providerDomain != "filesystem" }) {
            return mapping.providerDomain
        }
        // Fall back to main provider
        return provider
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case provider
        case name
        case version
        case mediaType = "media_type"
        case duration
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case uri
        case artists
        case album
        case metadata
        case providerMappings = "provider_mappings"
    }
}

extension Track {
    /// Builds a display-only Track from a remote player's reported `current_media`
    /// (Mode R). Only the fields the now-playing surfaces read are populated; queue
    /// metadata (track/disc numbers, provider mappings, favorite) is left empty. This
    /// is the reliable now-playing signal for remote and synced-group playback, where
    /// the app holds no local queue.
    init(from media: CurrentMedia, provider: String) {
        let images: [MediaItemImage]? = media.imageUrlResolved.map {
            [MediaItemImage(type: "thumb", path: $0, provider: provider)]
        }
        self.init(
            itemId: media.uri ?? media.title ?? UUID().uuidString,
            provider: provider,
            name: media.title ?? "",
            version: nil,
            mediaType: nil,
            duration: media.duration,
            trackNumber: nil,
            discNumber: nil,
            uri: media.uri ?? "",
            artists: media.artist.map { [ArtistReference(itemId: nil, provider: nil, name: $0)] },
            album: media.album.map { AlbumReference(itemId: "", provider: provider, name: $0, metadata: nil) },
            metadata: images.map { MediaItemMetadata(images: $0) },
            providerMappings: nil,
            favorite: nil
        )
    }
}

struct MediaItemMetadata: Codable, Hashable {
    let images: [MediaItemImage]?
}

struct MediaItemImage: Codable, Hashable {
    let type: String
    let path: String
    let provider: String
}

struct ProviderMapping: Codable, Hashable {
    let itemId: String
    let providerDomain: String
    let providerInstance: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case providerDomain = "provider_domain"
        case providerInstance = "provider_instance"
    }
}

struct ArtistReference: Codable, Hashable {
    let itemId: String?
    let provider: String?
    let name: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case provider
        case name
    }
}

struct AlbumReference: Codable, Hashable {
    let itemId: String
    let provider: String
    let name: String
    let metadata: MediaItemMetadata?
    
    var imageUrl: String? {
        metadata?.images?.first(where: { $0.type == "thumb" })?.path ?? 
        metadata?.images?.first?.path
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case provider
        case name
        case metadata
    }
}
