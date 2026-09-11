import Foundation

nonisolated extension JellyfinClient {
    /// プレイリスト取得専用のセッション。共通セッションは `Accept: application/json` を付けるので使わない。
    private static let playlistSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private static let hlsMIMETypes: Set<String> = [
        "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl",
    ]

    /// AVPlayer に渡す最終的なストリーム URL。
    ///
    /// Jellyfin 12 はトランスコード時に返すマスタープレイリストの子 URI に生のスペースを含めるため
    /// （`TranscodeReasons=ContainerNotSupported, VideoCodecNotSupported`）、AVFoundation がそのまま要求して
    /// -1005 で失敗する。ここでマスターを先読みし、補正した子 URI（メディアプレイリスト）を直接渡す。
    /// 直接再生やメディアプレイリストの場合、また取得に失敗した場合は元の URL を返し、成否は AVPlayer に委ねる。
    @concurrent
    func resolvedAudioStreamURL(itemID: String, quality: StreamQuality) async throws -> URL {
        guard let url = audioStreamURL(itemID: itemID, quality: quality) else {
            throw JellyfinError.missingCredentials
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.apple.mpegurl, */*", forHTTPHeaderField: "Accept")

        // 直接再生だと応答本体は音声ファイルそのものなので、ヘッダーを見た時点で読むのをやめる。
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.playlistSession.bytes(for: request)
        } catch {
            return url
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let mimeType = http.mimeType?.lowercased(), Self.hlsMIMETypes.contains(mimeType)
        else { return url }

        var lines: [String] = []
        do {
            for try await line in bytes.lines { lines.append(line) }
        } catch {
            return url
        }
        return Self.variantURL(inMasterPlaylist: lines, relativeTo: http.url ?? url) ?? url
    }

    /// マスタープレイリストから最初のバリアントの絶対 URL を取り出す。メディアプレイリストなら nil。
    static func variantURL(inMasterPlaylist lines: [String], relativeTo base: URL) -> URL? {
        guard !lines.contains(where: { $0.hasPrefix("#EXTINF") }) else { return nil }
        guard let streamInf = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }
        guard
            let uri = lines[(streamInf + 1)...].map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else { return nil }
        // 既に `%7C` などで符号化されている部分を二重に符号化しないよう、スペースだけを補正する。
        let escaped = uri.replacingOccurrences(of: " ", with: "%20")
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }
}
