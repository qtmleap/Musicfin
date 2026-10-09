import AVFoundation
import Foundation

// iOS の音声経路・ロック画面・通信だけを置き換え、キュー制御と AVFoundation は本番を使う。
@MainActor final class AudioSessionManager {
    var onShouldPause: (() -> Void)?
    var onShouldResume: (() -> Void)?
    func activate() {}
}
nonisolated final class JellyfinClient: Sendable {
    let isAuthenticated = true
    func resolvedAudioStreamURL(itemID: String, quality: StreamQuality) async throws -> URL {
        preconditionFailure("Fixture unexpectedly requested the network")
    }
}
@MainActor final class PlaybackReporter {
    init(client: JellyfinClient) {}
    func start(itemID: String?, position: TimeInterval) {}
    func stop(itemID: String?, position: TimeInterval) {}
    func progress(itemID: String?, position: TimeInterval, isPaused: Bool) {}
    func progressIfNeeded(itemID: String?, position: TimeInterval, isPaused: Bool) {}
}
@MainActor final class NowPlayingCenter {
    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
    }
    static var publishedItemID: String?
    static var onUpdate: ((MediaItem?) -> Void)?
    init(commands: Commands) {}
    func updateClient(_ client: JellyfinClient) {}
    func update(item: MediaItem?, isPlaying: Bool, position: TimeInterval, duration: TimeInterval) {
        Self.publishedItemID = item?.id
        Self.onUpdate?(item)
    }
    func updateElapsed(_ position: TimeInterval, isPlaying: Bool) {}
    func clear() { Self.publishedItemID = nil }
}
