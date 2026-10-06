import Foundation

nonisolated enum LibraryFeed: CaseIterable, Hashable, Sendable {
    case recentlyAdded, frequentlyPlayed, favoriteTracks, recentlyPlayedAlbums, recentlyPlayedTracks, tracks

    var pageSize: Int { self == .tracks ? 100 : 20 }

    func query(userID: String, startIndex: Int) -> [String: String?] {
        let audio = self == .favoriteTracks || self == .recentlyPlayedTracks || self == .tracks
        let history = self == .recentlyPlayedAlbums || self == .recentlyPlayedTracks
        return [
            "userId": userID,
            "includeItemTypes": audio ? "Audio" : "MusicAlbum",
            "recursive": "true",
            "fields": "PrimaryImageAspectRatio,ParentId,Genres,ChildCount",
            "enableUserData": "true",
            "enableTotalRecordCount": "true",
            "startIndex": String(startIndex),
            "limit": String(pageSize),
            "sortBy": history
                ? "DatePlayed"
                : self == .recentlyAdded ? "DateCreated" : self == .frequentlyPlayed ? "PlayCount" : "SortName",
            "sortOrder": history || self == .recentlyAdded || self == .frequentlyPlayed ? "Descending" : "Ascending",
            "filters": self == .favoriteTracks ? "IsFavorite" : history || self == .frequentlyPlayed ? "IsPlayed" : nil,
        ]
    }
}
