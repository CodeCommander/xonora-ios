import Foundation

struct MAPlayer: Identifiable, Codable, Hashable {
    let playerId: String
    let provider: String
    let name: String
    let type: String
    let available: Bool
    let state: PlayerState?
    let volume: Int?
    let currentMedia: CurrentMedia?
    let queueId: String?
    /// Player IDs synced under this player when it is a sync-group leader (MA `group_members`).
    let groupMembers: [String]?
    /// The leader this player is synced to, if it is a group member (MA `synced_to`).
    let syncedTo: String?

    var id: String { playerId }

    /// True when this player leads a sync group with one or more members.
    var isGroupLeader: Bool { !(groupMembers ?? []).isEmpty }

    /// True when this player is a member synced to another (leader) player.
    var isGroupMember: Bool { syncedTo != nil }

    /// SF Symbol for this player, matching the PWA's icon language: the on-device
    /// player shows a phone; a player leading a sync group shows a *pair* of
    /// speakers; an ungrouped external player shows a single speaker.
    var systemIcon: String {
        if provider == "sendspin" { return "iphone" }
        return isGroupLeader ? "hifispeaker.2.fill" : "speaker.wave.2"
    }

    enum CodingKeys: String, CodingKey {
        case playerId = "player_id"
        case provider
        case name
        case type
        case available
        case state = "playback_state"
        case volume = "volume_level"
        case currentMedia = "current_media"
        case queueId = "active_source"
        case groupMembers = "group_members"
        case syncedTo = "synced_to"
    }
}

enum PlayerState: String, Codable {
    case idle = "idle"
    case playing = "playing"
    case paused = "paused"
    case off = "off"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = PlayerState(rawValue: rawValue) ?? .unknown
    }
}

struct CurrentMedia: Codable, Hashable {
    let title: String?
    let artist: String?
    let album: String?
    private let imageUrl: String?
    private let image: String?
    let duration: TimeInterval?
    let position: TimeInterval?
    let uri: String?

    /// Returns the image URL, trying both possible field names from the API
    var imageUrlResolved: String? {
        imageUrl ?? image
    }

    enum CodingKeys: String, CodingKey {
        case title
        case artist
        case album
        case imageUrl = "image_url"
        case image
        case duration
        case position
        case uri
    }
}

struct QueueItem: Identifiable, Codable, Hashable {
    let queueItemId: String
    let name: String
    let artist: String?
    let album: String?
    let imageUrl: String?
    let duration: TimeInterval?
    let uri: String?

    var id: String { queueItemId }

    enum CodingKeys: String, CodingKey {
        case queueItemId = "queue_item_id"
        case name
        case artist
        case album
        case imageUrl = "image"
        case duration
        case uri
    }
}
