import Foundation

/// 曲末で AVQueuePlayer が実際に進む先と、論理キューの次の曲が一致するかの判定。
nonisolated enum PlaybackAdvance: Equatable {
    /// 先読み済みの曲が期待どおりなので、そのまま任せる。
    case keepQueued
    /// 先読みが空か食い違っているので、期待する曲を読み直す。
    case reload

    /// `queuedIDs` は終了した曲を除いた、AVQueuePlayer に積まれている曲の並び。
    static func decide(expectedNext: String, queuedIDs: [String?]) -> Self {
        guard let first = queuedIDs.first, first == expectedNext else { return .reload }
        return .keepQueued
    }
}
