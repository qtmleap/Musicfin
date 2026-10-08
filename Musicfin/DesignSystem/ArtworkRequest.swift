import CryptoKit
import Foundation

/// 表示と先読みで同じ画像寸法を使い、細かなセル幅の違いを別ダウンロードにしない。
nonisolated struct ArtworkRequest: Hashable, Sendable {
    let url: URL
    let authorization: String?
    private let authorizationScope: String

    init(url: URL, authorization: String? = nil) {
        self.url = Self.canonicalURL(url)
        self.authorization = authorization
        authorizationScope = authorization.map { Self.digest("authorized:" + $0) } ?? "anonymous"
    }

    /// 認証が切り替わったときに古い画像も共有要求も渡さず、保存名には資格情報を残さない。
    var storageKey: String { Self.digest(authorizationScope + "\n" + url.absoluteString) }

    /// 解像度だけの切り替えでは表示中の画像を保ち、別作品や新しいタグでは古い絵を消す。
    var sourceKey: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return Self.digest(authorizationScope + "\n" + url.absoluteString)
        }
        components.queryItems = components.queryItems?.filter { $0.name != "maxWidth" && $0.name != "maxHeight" }
        return Self.digest(authorizationScope + "\n" + (components.string ?? url.absoluteString))
    }

    var urlRequest: URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            var query = components.queryItems
        else { return url }
        for index in query.indices where query[index].name == "maxWidth" || query[index].name == "maxHeight" {
            guard let text = query[index].value, let pixels = Int(text), pixels > 0 else { continue }
            // JellyfinClient が渡す値は既に画素数。行・一覧・大画像の 3 段へ切り上げる。
            let bucket = [288, 960, 1800].first { $0 >= pixels } ?? pixels
            query[index].value = String(bucket)
        }
        components.queryItems = query.sorted { $0.name < $1.name }
        return components.url ?? url
    }
}

nonisolated enum ArtworkFailure: Error, Equatable, Sendable {
    case http(Int)
    case transport(Int)
    case invalidImage

    var isRetryable: Bool {
        switch self {
        case .http(let status): status == 408 || status == 429 || (500..<600).contains(status)
        case .transport(let code):
            [
                URLError.timedOut.rawValue, URLError.notConnectedToInternet.rawValue,
                URLError.networkConnectionLost.rawValue, URLError.cannotConnectToHost.rawValue,
                URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue,
            ].contains(code)
        case .invalidImage: false
        }
    }
}
