import Foundation
import os

/// Jellyfin に再生状況を伝える。他のクライアントとの再生位置の共有や再生回数の集計に使われる。
@MainActor
final class PlaybackReporter {
    private let client: JellyfinClient
    private let logger = Logger(subsystem: "jp.qleap.musicfin", category: "PlaybackReporter")

    /// サーバーが 1 回の再生を識別するための ID。曲が変わるたびに作り直す。
    private var playSessionID = UUID().uuidString
    private var reportingItemID: String?
    private var lastProgressReport: TimeInterval = 0

    /// 進捗報告の間隔。短くしすぎるとサーバーへのリクエストが無駄に増える。
    private let progressInterval: TimeInterval = 10

    init(client: JellyfinClient) {
        self.client = client
    }

    func start(itemID: String?, position: TimeInterval) {
        guard let itemID else { return }
        if reportingItemID != itemID {
            playSessionID = UUID().uuidString
            reportingItemID = itemID
        }
        lastProgressReport = position
        let body = makeBody(itemID: itemID, position: position, isPaused: false)
        send { try await $0.reportPlaybackStart(body) }
    }

    func progress(itemID: String?, position: TimeInterval, isPaused: Bool) {
        guard let itemID, reportingItemID == itemID else { return }
        lastProgressReport = position
        let body = makeBody(itemID: itemID, position: position, isPaused: isPaused)
        send { try await $0.reportPlaybackProgress(body) }
    }

    /// 定期的な進捗報告。前回から一定時間経っていなければ何もしない。
    func progressIfNeeded(itemID: String?, position: TimeInterval, isPaused: Bool) {
        guard abs(position - lastProgressReport) >= progressInterval else { return }
        progress(itemID: itemID, position: position, isPaused: isPaused)
    }

    func stop(itemID: String?, position: TimeInterval) {
        guard let itemID, reportingItemID == itemID else { return }
        reportingItemID = nil
        let body = PlaybackStoppedBody(
            itemId: itemID,
            playSessionId: playSessionID,
            positionTicks: position.ticks
        )
        send { try await $0.reportPlaybackStopped(body) }
    }

    private func makeBody(itemID: String, position: TimeInterval, isPaused: Bool) -> PlaybackProgressBody {
        PlaybackProgressBody(
            itemId: itemID,
            playSessionId: playSessionID,
            positionTicks: position.ticks,
            isPaused: isPaused
        )
    }

    /// 報告の失敗は再生を妨げないので、記録するだけで握りつぶす。
    private func send(_ operation: @escaping @Sendable (JellyfinClient) async throws -> Void) {
        let client = client
        Task.detached(priority: .utility) { [logger] in
            do {
                try await operation(client)
            } catch {
                logger.debug("再生状況の報告に失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
