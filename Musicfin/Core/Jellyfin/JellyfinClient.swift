import Foundation
import os

nonisolated enum JellyfinError: LocalizedError, Sendable {
    case invalidServerURL
    case unauthorized
    case http(status: Int, body: String?)
    case decoding(underlying: String)
    case transport(underlying: String)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "サーバーの URL が正しくありません。"
        case .unauthorized:
            "認証に失敗しました。再度ログインしてください。"
        case .http(let status, let body):
            "サーバーがエラーを返しました (HTTP \(status))。\(body.map { "\n\($0)" } ?? "")"
        case .decoding(let underlying):
            "サーバーの応答を解釈できませんでした。\n\(underlying)"
        case .transport(let underlying):
            "サーバーに接続できませんでした。\n\(underlying)"
        case .missingCredentials:
            "サーバーへのログインが必要です。"
        }
    }
}

/// Jellyfin サーバーへの HTTP アクセスを担う値型。
/// 不変なので Sendable であり、アクター境界を自由に越えられる。
nonisolated struct JellyfinClient: Sendable, Equatable {
    let serverURL: URL
    let deviceID: String
    var accessToken: String?
    var userID: String?

    static let clientName = "Musicfin"
    static let clientVersion = "0.1.0"

    private static let logger = Logger(subsystem: "am.nasawake.Musicfin", category: "JellyfinClient")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    init(serverURL: URL, deviceID: String, accessToken: String? = nil, userID: String? = nil) {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.userID = userID
    }

    var isAuthenticated: Bool { accessToken != nil && userID != nil }

    // MARK: - ヘッダー

    /// Jellyfin 10.8 以降で推奨される Authorization ヘッダーを組み立てる。
    var authorizationHeader: String {
        var parts = [
            #"Client="\#(Self.clientName)""#,
            #"Device="\#(Self.deviceName)""#,
            #"DeviceId="\#(deviceID)""#,
            #"Version="\#(Self.clientVersion)""#,
        ]
        if let accessToken { parts.append(#"Token="\#(accessToken)""#) }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    private static var deviceName: String {
        #if targetEnvironment(simulator)
        "iOS Simulator"
        #else
        "iPhone"
        #endif
    }

    // MARK: - URL 組み立て

    func url(_ path: String, query: [String: String?] = [:]) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        return components.url
    }

    // MARK: - リクエスト送信

    @concurrent
    func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [String: String?] = [:],
        as _: Response.Type = Response.self
    ) async throws -> Response {
        try await send(makeRequest(path, method: "GET", query: query))
    }

    @concurrent
    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        query: [String: String?] = [:],
        as _: Response.Type = Response.self
    ) async throws -> Response {
        var request = try makeRequest(path, method: "POST", query: query)
        request.httpBody = try JellyfinCoding.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    /// レスポンス本文を必要としない POST（再生状況の報告など）。
    @concurrent
    func post(_ path: String, body: some Encodable & Sendable, query: [String: String?] = [:]) async throws {
        var request = try makeRequest(path, method: "POST", query: query)
        request.httpBody = try JellyfinCoding.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await sendRaw(request)
    }

    /// 本文もレスポンスも持たない POST（お気に入り登録など）。
    @concurrent
    func post(_ path: String, query: [String: String?] = [:]) async throws {
        _ = try await sendRaw(makeRequest(path, method: "POST", query: query))
    }

    @concurrent
    func delete(_ path: String, query: [String: String?] = [:]) async throws {
        _ = try await sendRaw(makeRequest(path, method: "DELETE", query: query))
    }

    // MARK: - 内部実装

    private func makeRequest(_ path: String, method: String, query: [String: String?]) throws -> URLRequest {
        guard let url = url(path, query: query) else { throw JellyfinError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
        let data = try await sendRaw(request)
        do {
            return try JellyfinCoding.decoder.decode(Response.self, from: data)
        } catch {
            Self.logger.error(
                "デコード失敗 \(request.url?.path ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            throw JellyfinError.decoding(underlying: String(describing: error))
        }
    }

    @discardableResult
    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw JellyfinError.transport(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport(underlying: "HTTP 応答ではありません。")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw JellyfinError.unauthorized
        default:
            let body = String(data: data.prefix(500), encoding: .utf8)
            throw JellyfinError.http(status: http.statusCode, body: body?.isEmpty == true ? nil : body)
        }
    }
}
