import Foundation

// MARK: - 認証

nonisolated extension JellyfinClient {
    private struct AuthenticateByNameBody: Encodable, Sendable {
        var username: String
        var pw: String

        // Jellyfin は "Username" / "Pw" を要求する。
        private enum CodingKeys: String, CodingKey {
            case username = "Username"
            case pw = "Pw"
        }
    }

    private struct QuickConnectBody: Encodable, Sendable {
        var secret: String

        private enum CodingKeys: String, CodingKey {
            case secret = "Secret"
        }
    }

    func fetchPublicSystemInfo() async throws -> PublicSystemInfo {
        try await get("/System/Info/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        try await post(
            "/Users/AuthenticateByName",
            body: AuthenticateByNameBody(username: username, pw: password),
            as: AuthenticationResult.self
        )
    }

    func initiateQuickConnect() async throws -> QuickConnectResult {
        // Jellyfin 10.9 以降は GET を受け付けず 405 を返す。
        try await post("/QuickConnect/Initiate")
    }

    func pollQuickConnect(secret: String) async throws -> QuickConnectResult {
        try await get("/QuickConnect/Connect", query: ["secret": secret])
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        try await post(
            "/Users/AuthenticateWithQuickConnect",
            body: QuickConnectBody(secret: secret),
            as: AuthenticationResult.self
        )
    }
}

// MARK: - ライブラリ取得

nonisolated extension JellyfinClient {
    /// 一覧取得で共通して要求するフィールド。増やすとレスポンスが重くなるので最小限に。
    private static let listFields = "PrimaryImageAspectRatio,ParentId,Genres,ChildCount"

    private func itemsQuery(extra: [String: String?]) throws -> [String: String?] {
        guard let userID else { throw JellyfinError.missingCredentials }
        var query: [String: String?] = ["userId": userID, "fields": Self.listFields]
        for (key, value) in extra { query[key] = value }
        return query
    }

    /// アルバム一覧。
    func fetchAlbums(
        startIndex: Int = 0,
        limit: Int = 100,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending"
    ) async throws -> QueryResult<MediaItem> {
        try await get(
            "/Items",
            query: itemsQuery(extra: [
                "includeItemTypes": "MusicAlbum",
                "recursive": "true",
                "sortBy": sortBy,
                "sortOrder": sortOrder,
                "startIndex": String(startIndex),
                "limit": String(limit),
            ]))
    }

    /// アルバムアーティスト一覧。/Artists は userId を受け取る専用エンドポイント。
    func fetchAlbumArtists(startIndex: Int = 0, limit: Int = 200) async throws -> QueryResult<MediaItem> {
        try await get(
            "/Artists/AlbumArtists",
            query: itemsQuery(extra: [
                "sortBy": "SortName",
                "sortOrder": "Ascending",
                "startIndex": String(startIndex),
                "limit": String(limit),
            ]))
    }

    func fetchPlaylists(limit: Int = 200) async throws -> QueryResult<MediaItem> {
        try await get(
            "/Items",
            query: itemsQuery(extra: [
                "includeItemTypes": "Playlist",
                "recursive": "true",
                "sortBy": "SortName",
                "limit": String(limit),
            ]))
    }

    /// アルバム内のトラック。ディスク番号 → トラック番号の順で並べる。
    func fetchTracks(inAlbum albumID: String) async throws -> QueryResult<MediaItem> {
        try await get(
            "/Items",
            query: itemsQuery(extra: [
                "parentId": albumID,
                "includeItemTypes": "Audio",
                "sortBy": "ParentIndexNumber,IndexNumber,SortName",
                "limit": "500",
            ]))
    }

    /// プレイリスト内のトラック。並び順はプレイリストの定義に従う。
    func fetchTracks(inPlaylist playlistID: String) async throws -> QueryResult<MediaItem> {
        guard let userID else { throw JellyfinError.missingCredentials }
        return try await get(
            "/Playlists/\(playlistID)/Items",
            query: [
                "userId": userID,
                "fields": Self.listFields,
                "limit": "1000",
            ])
    }

    func fetchAlbums(byArtist artistID: String) async throws -> QueryResult<MediaItem> {
        try await get(
            "/Items",
            query: itemsQuery(extra: [
                "albumArtistIds": artistID,
                "includeItemTypes": "MusicAlbum",
                "recursive": "true",
                "sortBy": "PremiereDate,ProductionYear,SortName",
                "sortOrder": "Descending",
                "limit": "200",
            ]))
    }

    func fetchItem(id: String) async throws -> MediaItem {
        guard let userID else { throw JellyfinError.missingCredentials }
        return try await get("/Items/\(id)", query: ["userId": userID, "fields": Self.listFields])
    }

    // MARK: ホーム画面用のセクション

    func fetchRecentlyAdded(limit: Int = 20) async throws -> [MediaItem] {
        try await fetchAlbums(limit: limit, sortBy: "DateCreated", sortOrder: "Descending").items
    }

    func fetchFrequentlyPlayed(limit: Int = 20) async throws -> [MediaItem] {
        let result: QueryResult<MediaItem> = try await get(
            "/Items",
            query: itemsQuery(extra: [
                "includeItemTypes": "MusicAlbum",
                "recursive": "true",
                "sortBy": "PlayCount",
                "sortOrder": "Descending",
                "filters": "IsPlayed",
                "limit": String(limit),
            ]))
        return result.items
    }

    func fetchFavoriteTracks(limit: Int = 200) async throws -> [MediaItem] {
        let result: QueryResult<MediaItem> = try await get(
            "/Items",
            query: itemsQuery(extra: [
                "includeItemTypes": "Audio",
                "recursive": "true",
                "filters": "IsFavorite",
                "sortBy": "SortName",
                "limit": String(limit),
            ]))
        return result.items
    }

    // MARK: 検索

    func search(term: String, limit: Int = 40) async throws -> QueryResult<MediaItem> {
        try await get(
            "/Items",
            query: itemsQuery(extra: [
                "searchTerm": term,
                "includeItemTypes": "Audio,MusicAlbum,MusicArtist,Playlist",
                "recursive": "true",
                "limit": String(limit),
            ]))
    }

    /// 指定トラックを起点にした自動生成プレイリスト。
    func fetchInstantMix(from itemID: String, limit: Int = 100) async throws -> [MediaItem] {
        guard let userID else { throw JellyfinError.missingCredentials }
        let result: QueryResult<MediaItem> = try await get(
            "/Items/\(itemID)/InstantMix",
            query: [
                "userId": userID,
                "fields": Self.listFields,
                "limit": String(limit),
            ])
        return result.items
    }

    // MARK: 歌詞

    /// 時間同期歌詞。サーバーに歌詞が無い場合は 404 になるので nil を返す。
    func fetchLyrics(itemID: String) async throws -> [LyricLine]? {
        do {
            let response: LyricResponse = try await get("/Audio/\(itemID)/Lyrics")
            return response.lyrics
        } catch let JellyfinError.http(status, _) where status == 404 {
            return nil
        }
    }

    // MARK: お気に入り

    func setFavorite(_ isFavorite: Bool, itemID: String) async throws {
        guard let userID else { throw JellyfinError.missingCredentials }
        let path = "/UserFavoriteItems/\(itemID)"
        if isFavorite {
            try await post(path, query: ["userId": userID])
        } else {
            try await delete(path, query: ["userId": userID])
        }
    }
}

// MARK: - 再生状況の報告

nonisolated struct PlaybackProgressBody: Encodable, Sendable {
    var itemId: String
    var playSessionId: String
    var positionTicks: Int64
    var isPaused: Bool
    var isMuted: Bool = false
    var canSeek: Bool = true
    var playMethod: String = "DirectStream"
    var repeatMode: String = "RepeatNone"
}

nonisolated struct PlaybackStoppedBody: Encodable, Sendable {
    var itemId: String
    var playSessionId: String
    var positionTicks: Int64
}

nonisolated extension JellyfinClient {
    func reportPlaybackStart(_ body: PlaybackProgressBody) async throws {
        try await post("/Sessions/Playing", body: body)
    }

    func reportPlaybackProgress(_ body: PlaybackProgressBody) async throws {
        try await post("/Sessions/Playing/Progress", body: body)
    }

    func reportPlaybackStopped(_ body: PlaybackStoppedBody) async throws {
        try await post("/Sessions/Playing/Stopped", body: body)
    }
}
