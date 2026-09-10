import Foundation
import Observation
import os

/// サーバー接続とログイン状態を保持する。アプリ全体で 1 つだけ存在する。
@MainActor
@Observable
final class AuthStore {
    enum State: Equatable {
        case signedOut
        case connecting
        case signedIn(user: String)
    }

    private(set) var state: State = .signedOut
    private(set) var client: JellyfinClient?
    private(set) var serverName: String?
    var lastError: String?

    /// Quick Connect でユーザーに提示する 6 桁コード。
    private(set) var quickConnectCode: String?

    private let logger = Logger(subsystem: "am.nasawake.Musicfin", category: "AuthStore")
    private var quickConnectTask: Task<Void, Never>?

    private enum Defaults {
        static let serverURL = "server.url"
        static let userID = "auth.userId"
        static let userName = "auth.userName"
        static let deviceID = "device.id"
    }

    private enum KeychainKey {
        static let accessToken = "auth.accessToken"
    }

    /// サーバー側でセッションを識別する ID。初回起動時に生成して以後変えない。
    private static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: Defaults.deviceID) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Defaults.deviceID)
        return generated
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// 前回のログイン情報があれば復元する。アプリ起動時に呼ぶ。
    func restoreSession() {
        guard let urlString = UserDefaults.standard.string(forKey: Defaults.serverURL),
            let url = URL(string: urlString),
            let userID = UserDefaults.standard.string(forKey: Defaults.userID),
            let token = Keychain.get(KeychainKey.accessToken)
        else { return }

        client = JellyfinClient(serverURL: url, deviceID: Self.deviceID, accessToken: token, userID: userID)
        state = .signedIn(user: UserDefaults.standard.string(forKey: Defaults.userName) ?? "")
    }

    // MARK: - サーバー接続

    /// URL を正規化して疎通確認する。スキーム省略時は https を補う。
    @discardableResult
    func connect(to rawURL: String) async -> Bool {
        state = .connecting
        lastError = nil

        guard let url = Self.normalize(rawURL) else {
            lastError = JellyfinError.invalidServerURL.localizedDescription
            state = .signedOut
            return false
        }

        let probe = JellyfinClient(serverURL: url, deviceID: Self.deviceID)
        do {
            let info = try await probe.fetchPublicSystemInfo()
            serverName = info.serverName
            client = probe
            state = .signedOut
            UserDefaults.standard.set(url.absoluteString, forKey: Defaults.serverURL)
            logger.info("接続成功: \(info.serverName ?? "?", privacy: .public) v\(info.version ?? "?", privacy: .public)")
            return true
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
            return false
        }
    }

    /// `jellyfin.example.com` のような入力も受け付けられるようにする。
    static func normalize(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    // MARK: - ログイン

    func signIn(username: String, password: String) async {
        guard let client else {
            lastError = JellyfinError.invalidServerURL.localizedDescription
            return
        }
        state = .connecting
        lastError = nil
        do {
            let result = try await client.authenticate(username: username, password: password)
            try apply(result, serverURL: client.serverURL)
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
        }
    }

    // MARK: - Quick Connect

    /// Quick Connect を開始し、承認されるまで 2 秒間隔でポーリングする。
    func startQuickConnect() {
        guard let client else { return }
        quickConnectTask?.cancel()
        lastError = nil

        quickConnectTask = Task { [weak self] in
            do {
                let initiated = try await client.initiateQuickConnect()
                guard let secret = initiated.secret else { throw JellyfinError.unauthorized }
                self?.quickConnectCode = initiated.code

                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await client.pollQuickConnect(secret: secret)
                    guard status.authenticated == true else { continue }

                    let result = try await client.authenticateWithQuickConnect(secret: secret)
                    self?.quickConnectCode = nil
                    try self?.apply(result, serverURL: client.serverURL)
                    return
                }
            } catch is CancellationError {
                // ユーザーが画面を離れただけなので何もしない。
            } catch {
                self?.quickConnectCode = nil
                self?.lastError = error.localizedDescription
            }
        }
    }

    func cancelQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnectCode = nil
    }

    // MARK: - ログアウト

    func signOut() {
        cancelQuickConnect()
        Keychain.remove(KeychainKey.accessToken)
        UserDefaults.standard.removeObject(forKey: Defaults.userID)
        UserDefaults.standard.removeObject(forKey: Defaults.userName)
        client = client.map { JellyfinClient(serverURL: $0.serverURL, deviceID: $0.deviceID) }
        state = .signedOut
    }

    // MARK: - 内部

    private func apply(_ result: AuthenticationResult, serverURL: URL) throws {
        guard let token = result.accessToken, let user = result.user else {
            throw JellyfinError.unauthorized
        }
        client = JellyfinClient(serverURL: serverURL, deviceID: Self.deviceID, accessToken: token, userID: user.id)
        Keychain.set(token, for: KeychainKey.accessToken)
        UserDefaults.standard.set(user.id, forKey: Defaults.userID)
        UserDefaults.standard.set(user.name, forKey: Defaults.userName)
        UserDefaults.standard.set(serverURL.absoluteString, forKey: Defaults.serverURL)
        state = .signedIn(user: user.name ?? "")
    }
}
