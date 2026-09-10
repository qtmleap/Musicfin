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
    /// - Note: AVPlayer は Authorization ヘッダーを付けにくいため、Jellyfin が公式に対応している
    ///         `api_key` クエリパラメータで認証する。
    func audioStreamURL(itemID: String, maxBitrate: Int = 320_000) -> URL? {
        guard let accessToken, let userID else { return nil }
        return url(
            "/Audio/\(itemID)/universal",
            query: [
                "userId": userID,
                "deviceId": deviceID,
                "api_key": accessToken,
                "container": Self.directPlayContainers,
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
