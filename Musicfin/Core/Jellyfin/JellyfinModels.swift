import Foundation

/// 1 秒 = 10,000,000 tick。Jellyfin の時間表現はすべてこの単位。
nonisolated let ticksPerSecond: Int64 = 10_000_000

nonisolated extension Int64 {
    var secondsFromTicks: TimeInterval { TimeInterval(self) / TimeInterval(ticksPerSecond) }
}

nonisolated extension TimeInterval {
    var ticks: Int64 { Int64(self * TimeInterval(ticksPerSecond)) }
}

// MARK: - 共通レスポンス

nonisolated struct QueryResult<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]
    var totalRecordCount: Int
    var startIndex: Int

    private enum CodingKeys: String, CodingKey {
        case items, totalRecordCount, startIndex
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Element].self, forKey: .items) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? items.count
        startIndex = try container.decodeIfPresent(Int.self, forKey: .startIndex) ?? 0
    }
}

// MARK: - サーバー情報

nonisolated struct PublicSystemInfo: Decodable, Sendable {
    var serverName: String?
    var version: String?
    var id: String?
    var startupWizardCompleted: Bool?
}

// MARK: - 認証

nonisolated struct AuthenticationResult: Decodable, Sendable {
    var user: UserDto?
    var accessToken: String?
    var serverId: String?
}

nonisolated struct UserDto: Decodable, Sendable, Identifiable {
    var id: String
    var name: String?
    var primaryImageTag: String?
}

nonisolated struct QuickConnectResult: Decodable, Sendable {
    var authenticated: Bool?
    var secret: String?
    var code: String?
}

// MARK: - アイテム

nonisolated struct NameIdPair: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
}

nonisolated struct ImageTags: Decodable, Sendable, Hashable {
    var primary: String?
    var backdrop: String?
    var logo: String?
    var banner: String?
}

nonisolated struct UserItemData: Decodable, Sendable, Hashable {
    var isFavorite: Bool?
    var played: Bool?
    var playCount: Int?
    var playbackPositionTicks: Int64?
}

/// Jellyfin の BaseItemDto のうち、音楽再生に必要なフィールドだけを持つ縮小版。
nonisolated struct MediaItem: Decodable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String?
    var type: ItemKind?
    var serverId: String?

    var album: String?
    var albumId: String?
    var albumArtist: String?
    var albumArtists: [NameIdPair]?
    var artistItems: [NameIdPair]?
    var artists: [String]?

    var indexNumber: Int?
    var parentIndexNumber: Int?
    var productionYear: Int?
    var runTimeTicks: Int64?
    var childCount: Int?
    var genres: [String]?
    var overview: String?

    var imageTags: ImageTags?
    var albumPrimaryImageTag: String?
    var backdropImageTags: [String]?
    var parentBackdropImageTags: [String]?
    var userData: UserItemData?

    // MARK: 表示用の派生プロパティ

    var displayName: String { name ?? "不明なタイトル" }

    /// トラックなら演奏者、アルバムならアルバムアーティストを優先して返す。
    var displayArtist: String? {
        if let artistItems, !artistItems.isEmpty {
            return artistItems.compactMap(\.name).joined(separator: "、")
        }
        if let artists, !artists.isEmpty { return artists.joined(separator: "、") }
        return albumArtist
    }

    var duration: TimeInterval? { runTimeTicks.map(\.secondsFromTicks) }
    var isFavorite: Bool { userData?.isFavorite ?? false }

    /// アートワーク取得に使う (itemId, tag) の組。トラックは自身のタグが無ければアルバムのものを使う。
    var artworkSource: (itemID: String, tag: String?)? {
        if let tag = imageTags?.primary { return (id, tag) }
        if let albumId, let tag = albumPrimaryImageTag { return (albumId, tag) }
        if let albumId { return (albumId, nil) }
        return (id, nil)
    }
}

nonisolated enum ItemKind: String, Decodable, Sendable, Hashable {
    case audio = "Audio"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case playlist = "Playlist"
    case musicGenre = "MusicGenre"
    case collectionFolder = "CollectionFolder"
    case userView = "UserView"
    case folder = "Folder"
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemKind(rawValue: raw) ?? .unknown
    }
}

// MARK: - 歌詞

nonisolated struct LyricResponse: Decodable, Sendable {
    var lyrics: [LyricLine]?
}

nonisolated struct LyricLine: Decodable, Sendable, Hashable, Identifiable {
    var start: Int64?
    var text: String

    var id: String { "\(start ?? -1)-\(text)" }
    /// 同期歌詞なら開始秒。プレーンテキスト歌詞なら nil。
    var startSeconds: TimeInterval? { start.map(\.secondsFromTicks) }
}
