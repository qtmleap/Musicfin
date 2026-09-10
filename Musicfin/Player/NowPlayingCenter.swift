import MediaPlayer
import UIKit

/// ロック画面・コントロールセンター・AirPods のリモコン操作との橋渡し。
@MainActor
final class NowPlayingCenter {
    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
    }

    private let commands: Commands
    private var client: JellyfinClient?
    private var artworkTask: Task<Void, Never>?
    /// 同じ曲でアートワークを取り直さないための目印。
    private var artworkItemID: String?

    init(commands: Commands) {
        self.commands = commands
        registerCommands()
    }

    func updateClient(_ client: JellyfinClient) {
        self.client = client
    }

    // MARK: - リモートコマンド

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.commands.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.commands.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.commands.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.commands.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.commands.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.commands.seek(event.positionTime) }
            return .success
        }

        // 音楽アプリではスキップ（早送り）よりトラック送りを優先する。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand]
        {
            command.isEnabled = true
        }
    }

    // MARK: - Now Playing 情報

    func update(item: MediaItem?, isPlaying: Bool, position: TimeInterval, duration: TimeInterval) {
        guard let item else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayName,
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let artist = item.displayArtist { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let track = item.indexNumber { info[MPMediaItemPropertyAlbumTrackNumber] = track }
        if let disc = item.parentIndexNumber { info[MPMediaItemPropertyDiscNumber] = disc }

        // 既存のアートワークは引き継ぎ、曲が変わったときだけ取り直す。
        if artworkItemID == item.id,
           let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
        {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        if artworkItemID != item.id {
            artworkItemID = item.id
            loadArtwork(for: item)
        }
    }

    /// 経過時間だけを差し替える軽量な更新。0.2 秒ごとに呼ばれるため辞書を作り直さない。
    func updateElapsed(_ position: TimeInterval, isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkTask?.cancel()
        artworkItemID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(for item: MediaItem) {
        artworkTask?.cancel()
        guard let client, let url = client.artworkURL(for: item, maxSize: 600) else { return }

        artworkTask = Task { [weak self] in
            guard let image = await ArtworkLoader.shared.image(for: url) else { return }
            guard !Task.isCancelled, self?.artworkItemID == item.id else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
