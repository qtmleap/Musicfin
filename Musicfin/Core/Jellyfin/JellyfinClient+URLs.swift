import Foundation

nonisolated extension JellyfinClient {
    // MARK: - アートワーク

    /// アイテムの Primary 画像 URL。tag を付けると内容が変わったときだけキャッシュが失効する。
    func artworkURL(itemID: String, tag: String?, maxSize: Int) -> URL? {
        let pixels = Int(Double(maxSize) * screenScale)
        return url(
            "/Items/\(itemID)/Images/Primary",
            query: [
                "tag": tag,
                "maxWidth": String(pixels),
                "maxHeight": String(pixels),
                "quality": "90",
            ])
    }

    func artworkURL(for item: MediaItem, maxSize: Int) -> URL? {
        guard let source = item.artworkSource else { return nil }
        return artworkURL(itemID: source.itemID, tag: source.tag, maxSize: maxSize)
    }

    /// アーティスト詳細などで使う背景画像。
    func backdropURL(itemID: String, tag: String?, maxWidth: Int = 1600) -> URL? {
        url(
            "/Items/\(itemID)/Images/Backdrop",
            query: [
                "tag": tag,
                "maxWidth": String(maxWidth),
                "quality": "80",
            ])
    }

    private var screenScale: Double { 3.0 }

    // MARK: - 音声ストリーム

    /// AVFoundation がそのまま再生できるコンテナ。ここに一致すればサーバーは無変換で配信する。
    private static let directPlayContainers = "mp3,aac,m4a|aac,m4b|aac,alac,m4a|alac,flac,wav,aiff"

    /// AVPlayer に渡すストリーム URL。
    ///
    /// - Important: Jellyfin 12 で `api_key` クエリパラメータによる認証は廃止され、
    ///   このエンドポイントは 401 を返すようになった。認証は `streamRequestHeaders` を
    ///   `AVURLAsset` に渡して行う。
    /// - Note: ビットレート上限を既定で付けない。上限を付けると可逆音源（FLAC は
    ///   700kbps を超えることが珍しくない）が常に変換対象になり、無変換配信の利点も
    ///   音質も失われる。AVFoundation は FLAC も ALAC もそのまま再生できる。
    func audioStreamURL(itemID: String, maxBitrate: Int? = nil) -> URL? {
        guard let userID else { return nil }
        return url(
            "/Audio/\(itemID)/universal",
            query: [
                "userId": userID,
                "deviceId": deviceID,
                "container": Self.directPlayContainers,
                "transcodingContainer": "ts",
                "transcodingProtocol": "hls",
                "audioCodec": "aac",
                "maxStreamingBitrate": maxBitrate.map(String.init),
                "startTimeTicks": "0",
                "enableRedirection": "true",
                "enableRemoteMedia": "false",
            ])
    }

    /// ストリーム取得時に付与すべき HTTP ヘッダー。
    ///
    /// `AVURLAsset(url:options:)` の `AVURLAssetHTTPHeaderFieldsKey` に渡す。このキーは
    /// 公開ヘッダーに定義が無いが、AVFoundation が長く受け付けている実質的な標準手段で、
    /// 他に AVPlayer へ認証ヘッダーを渡す方法が `AVAssetResourceLoaderDelegate` を
    /// 自前実装する以外に無い。
    var streamRequestHeaders: [String: String] {
        ["Authorization": authorizationHeader]
    }
}
