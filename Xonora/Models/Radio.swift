import Foundation

struct Radio: Identifiable, Codable, Hashable {
    let itemId: String
    let provider: String
    let name: String
    let uri: String
    let metadata: MediaItemMetadata?
    var favorite: Bool?

    var id: String { itemId }

    var imageUrl: String? {
        metadata?.images?.first(where: { $0.type == "thumb" })?.path ??
        metadata?.images?.first?.path
    }

    /// Returns the source provider (e.g., tunein, radiobrowser) extracted from URI.
    /// Stations are surfaced through the MA radio media type but originate from a
    /// concrete provider; prefer that over the generic library wrapper.
    var sourceProvider: String {
        if let scheme = URL(string: uri)?.scheme,
           !scheme.isEmpty && scheme != "library" && scheme != "file" {
            return scheme
        }
        return provider
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case provider
        case name
        case uri
        case metadata
        case favorite
    }
}
