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
    private static let losslessContainers = "mp3,aac,m4a|aac,m4b|aac,alac,m4a|alac,flac,wav,aiff"
    /// 圧縮音源だけを無変換で通す。ロスレスは含めず、サーバー側で AAC にトランスコードさせる。
    private static let lossyContainers = "mp3,aac,m4a|aac,m4b|aac"

    /// AVPlayer に渡すストリーム URL。
    /// - Note: AVPlayer は Authorization ヘッダーを付けにくいため、クエリパラメータで認証する。
    ///         Jellyfin 12 は旧来の `api_key` を受け付けず 401 を返すので `ApiKey` を使う（10.10 は両方通る）。
    func audioStreamURL(itemID: String, quality: StreamQuality) -> URL? {
        guard let accessToken, let userID else { return nil }
        let container: String
        let maxBitrate: Int
        switch quality {
        case .lossless:
            container = Self.losslessContainers
            // ロスレスを直接再生させるため、ビットレート上限で弾かれないよう十分に大きくする。
            maxBitrate = 10_000_000
        case .high:
            container = Self.lossyContainers
            maxBitrate = 256_000
        case .saver:
            container = Self.lossyContainers
            maxBitrate = 128_000
        }
        return url(
            "/Audio/\(itemID)/universal",
            query: [
                "userId": userID,
                "deviceId": deviceID,
                "ApiKey": accessToken,
                "container": container,
                "transcodingContainer": "ts",
                "transcodingProtocol": "hls",
                "audioCodec": "aac",
                "maxStreamingBitrate": String(maxBitrate),
                "startTimeTicks": "0",
                "enableRedirection": "true",
                "enableRemoteMedia": "false",
            ])
    }
}
