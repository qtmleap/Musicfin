import AVFoundation
import Network
import Observation
import os

/// キュー管理・再生制御・Jellyfin への再生報告をまとめた再生エンジン。
@MainActor
@Observable
final class PlaybackEngine {
    enum RepeatMode: CaseIterable {
        case off, all, one

        var systemImage: String {
            switch self {
            case .off, .all: "repeat"
            case .one: "repeat.1"
            }
        }

        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    // MARK: - 公開状態

    private(set) var queue: [MediaItem] = []
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off

    var currentItem: MediaItem? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// Jellyfin のメタデータ由来の尺。HLS では AVPlayer 側が不定値を返すためこちらを正とする。
    var duration: TimeInterval {
        if let metadataDuration = currentItem?.duration, metadataDuration > 0 { return metadataDuration }
        let playerDuration = player.currentItem?.duration.seconds ?? 0
        return playerDuration.isFinite ? playerDuration : 0
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var hasNext: Bool { currentIndex + 1 < queue.count || repeatMode == .all }

    /// 「次に再生」リストとして表示するための残りのキュー。
    var upcoming: ArraySlice<MediaItem> {
        guard currentIndex + 1 < queue.count else { return [] }
        return queue[(currentIndex + 1)...]
    }

    // MARK: - 内部状態

    private let player = AVQueuePlayer()
    private let audioSession = AudioSessionManager()
    private let logger = Logger(subsystem: "jp.qleap.musicfin", category: "PlaybackEngine")

    private var client: JellyfinClient?
    private var settings: PlaybackSettings?
    private var nowPlaying: NowPlayingCenter?
    private var reporter: PlaybackReporter?

    /// 経路がモバイル回線かどうか。音質の選択にだけ使うので、変化しても再生中の曲は差し替えない。
    private var isOnCellular = false
    private let pathMonitor = NWPathMonitor()

    /// シャッフル解除時に元の並びへ戻すための控え。
    private var unshuffledQueue: [MediaItem] = []
    /// AVPlayerItem から Jellyfin のアイテム ID を引くための対応表。
    private var trackIDByPlayerItem: [ObjectIdentifier: String] = [:]
    private let cleanup = CleanupBox()
    private var statusObservation: NSKeyValueObservation?

    /// ストリーム URL の解決は非同期なので、解決中に曲が切り替わった古い結果を捨てるための世代番号。
    private var loadGeneration = 0
    private var lookaheadTask: Task<Void, Never>?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        setUpObservers()
        audioSession.onShouldPause = { [weak self] in self?.pause() }
        audioSession.onShouldResume = { [weak self] in self?.play() }
        startPathMonitor()
    }

    /// 音質設定を差し替える。次に作る AVPlayerItem から反映される。
    func configure(settings: PlaybackSettings) {
        self.settings = settings
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in self?.isOnCellular = cellular }
        }
        pathMonitor.start(queue: DispatchQueue(label: "jp.qleap.musicfin.pathMonitor"))
    }

    /// 現在の経路に応じた音質。設定が未注入なら高音質で再生する。
    private var streamQuality: StreamQuality {
        guard let settings else { return .high }
        return isOnCellular ? settings.cellularQuality : settings.wifiQuality
    }

    /// ログイン状態が変わったときに呼ぶ。未ログインなら再生を止める。
    func configure(client: JellyfinClient?) {
        self.client = client
        guard let client, client.isAuthenticated else {
            stop()
            nowPlaying = nil
            reporter = nil
            return
        }
        reporter = PlaybackReporter(client: client)
        if nowPlaying == nil {
            nowPlaying = NowPlayingCenter(
                commands: .init(
                    play: { [weak self] in self?.play() },
                    pause: { [weak self] in self?.pause() },
                    toggle: { [weak self] in self?.toggle() },
                    next: { [weak self] in self?.playNext() },
                    previous: { [weak self] in self?.playPrevious() },
                    seek: { [weak self] time in self?.seek(to: time) }
                ))
        }
        nowPlaying?.updateClient(client)
    }

    // MARK: - 再生開始

    /// キューを差し替えて指定位置から再生する。通常の入口は毎回元順から始め、シャッフル入口だけ明示する。
    func play(items: [MediaItem], startingAt index: Int = 0, shuffled: Bool = false) {
        guard
            let order = PlaybackQueueOrder.make(
                items: items,
                startingAt: index,
                shuffled: shuffled,
                shuffle: { $0.shuffled() }
            )
        else { return }
        audioSession.activate()

        reportStopIfNeeded()
        unshuffledQueue = order.original
        queue = order.queue
        currentIndex = order.currentIndex
        isShuffled = order.isShuffled
        loadCurrentTrack(autoPlay: true)
    }

    /// 現在のキューの末尾に追加する。
    func appendToQueue(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        queue.append(contentsOf: items)
        unshuffledQueue.append(contentsOf: items)
        refillLookahead()
    }

    /// 現在の曲の直後に差し込む。
    func playNext(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        let insertionPoint = min(currentIndex + 1, queue.count)
        queue.insert(contentsOf: items, at: insertionPoint)
        unshuffledQueue = queue
        rebuildLookahead()
    }

    // MARK: - トランスポート操作

    func play() {
        guard currentItem != nil else { return }
        audioSession.activate()
        player.play()
        isPlaying = true
        nowPlaying?.update(item: currentItem, isPlaying: true, position: currentTime, duration: duration)
        reporter?.start(itemID: currentItem?.id, position: currentTime)
    }

    func pause() {
        player.pause()
        isPlaying = false
        nowPlaying?.update(item: currentItem, isPlaying: false, position: currentTime, duration: duration)
        reporter?.progress(itemID: currentItem?.id, position: currentTime, isPaused: true)
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        reportStopIfNeeded()
        invalidatePendingLoads()
        player.pause()
        player.removeAllItems()
        trackIDByPlayerItem.removeAll()
        queue = []
        unshuffledQueue = []
        currentIndex = 0
        currentTime = 0
        isPlaying = false
        nowPlaying?.clear()
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            return
        }
        loadCurrentTrack(autoPlay: true)
    }

    /// 3 秒以上再生していれば曲の先頭へ、それ未満なら前の曲へ（Apple Music と同じ挙動）。
    func playPrevious() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        loadCurrentTrack(autoPlay: true)
    }

    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrentTrack(autoPlay: true)
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), max(duration, 0))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        nowPlaying?.update(item: currentItem, isPlaying: isPlaying, position: clamped, duration: duration)
        reporter?.progress(itemID: currentItem?.id, position: clamped, isPaused: !isPlaying)
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        // リピート 1 曲では先読みを止め、曲末で頭出しに切り替える。
        rebuildLookahead()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            applyShuffle(keepingCurrent: true)
        } else {
            let playingID = currentItem?.id
            queue = unshuffledQueue
            currentIndex = playingID.flatMap { id in queue.firstIndex { $0.id == id } } ?? 0
        }
        rebuildLookahead()
    }

    // MARK: - キュー構築

    private func applyShuffle(keepingCurrent: Bool) {
        guard !queue.isEmpty else { return }
        let playing = keepingCurrent ? currentItem : nil
        var shuffled = queue.shuffled()
        if let playing, let position = shuffled.firstIndex(where: { $0.id == playing.id }) {
            shuffled.swapAt(0, position)
        }
        queue = shuffled
        currentIndex = 0
    }

    /// マスタープレイリストの補正のためサーバーへ 1 往復するので非同期。対応表への登録は積むときに行う。
    private func makePlayerItem(for item: MediaItem) async -> AVPlayerItem? {
        guard let client else {
            logger.error("ストリーム URL を作れませんでした: \(item.id, privacy: .public)")
            return nil
        }
        let url: URL
        do {
            url = try await client.resolvedAudioStreamURL(itemID: item.id, quality: streamQuality)
        } catch {
            logger.error("ストリーム URL を作れませんでした: \(item.id, privacy: .public)")
            return nil
        }
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url))
        // 曲間で途切れないよう十分にバッファする。
        playerItem.preferredForwardBufferDuration = 10
        return playerItem
    }

    private func enqueue(_ playerItem: AVPlayerItem, for item: MediaItem, after: AVPlayerItem?) {
        trackIDByPlayerItem[ObjectIdentifier(playerItem)] = item.id
        player.insert(playerItem, after: after)
    }

    /// 解決中の URL があっても、その結果をキューへ積ませない。
    private func invalidatePendingLoads() {
        loadGeneration += 1
        lookaheadTask?.cancel()
        lookaheadTask = nil
    }

    private func loadCurrentTrack(autoPlay: Bool) {
        reportStopIfNeeded()
        invalidatePendingLoads()
        player.removeAllItems()
        trackIDByPlayerItem.removeAll()
        currentTime = 0

        guard let item = currentItem else { return }
        // URL の解決を待つ間も UI には選んだ曲を出しておく。
        isBuffering = true
        nowPlaying?.update(item: item, isPlaying: autoPlay, position: 0, duration: duration)

        let generation = loadGeneration
        Task { [weak self] in
            guard let self else { return }
            let playerItem = await makePlayerItem(for: item)
            // 解決中に別の曲へ切り替わっていたら、この結果は捨てる。
            guard generation == loadGeneration else { return }
            guard let playerItem else {
                isBuffering = false
                return
            }
            enqueue(playerItem, for: item, after: nil)
            observeStatus(of: playerItem)
            refillLookahead()
            if autoPlay { play() }
        }
    }

    /// 先読み用に次の 1 曲だけを AVQueuePlayer に積む。これがギャップレス再生の肝。
    private func refillLookahead() {
        guard repeatMode != .one else { return }
        guard player.items().count < 2 else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]

        lookaheadTask?.cancel()
        let generation = loadGeneration
        lookaheadTask = Task { [weak self] in
            guard let self else { return }
            let playerItem = await makePlayerItem(for: next)
            // 解決中に曲が進んだ・キューが変わった・別の先読みが積まれた場合は捨てる。
            guard !Task.isCancelled, generation == loadGeneration, player.items().count < 2,
                queue.indices.contains(currentIndex + 1), queue[currentIndex + 1].id == next.id,
                let playerItem
            else { return }
            enqueue(playerItem, for: next, after: player.items().last)
        }
    }

    /// 先読み分だけを積み直す（キュー編集・リピート変更時）。現在再生中の曲は触らない。
    private func rebuildLookahead() {
        lookaheadTask?.cancel()
        let playing = player.currentItem
        for queued in player.items() where queued !== playing {
            trackIDByPlayerItem.removeValue(forKey: ObjectIdentifier(queued))
            player.remove(queued)
        }
        refillLookahead()
    }

    // MARK: - 監視

    private func setUpObservers() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.handleTimeUpdate(seconds) }
        }
        cleanup.add { [player] in player.removeTimeObserver(observer) }

        // Notification から取り出せるのは非 Sendable な AVPlayerItem なので、
        // 同一性の判定に使う ObjectIdentifier だけを境界の外へ渡す。
        cleanup.observe(AVPlayerItem.didPlayToEndTimeNotification) { notification in
            let identifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { [weak self] in self?.handleItemEnded(identifier) }
        }
    }

    private func handleTimeUpdate(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        nowPlaying?.updateElapsed(seconds, isPlaying: isPlaying)
        reporter?.progressIfNeeded(itemID: currentItem?.id, position: seconds, isPaused: !isPlaying)
    }

    private func handleItemEnded(_ endedItem: ObjectIdentifier?) {
        guard let endedItem, trackIDByPlayerItem[endedItem] != nil else { return }
        reportStopIfNeeded(position: duration)

        if repeatMode == .one {
            player.seek(to: .zero)
            player.play()
            reporter?.start(itemID: currentItem?.id, position: 0)
            return
        }

        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            // AVQueuePlayer は先読み分へ自動で進んでいるので、論理位置だけ合わせて先読みを補充する。
            currentIndex = nextIndex
            currentTime = 0
            refillLookahead()
            nowPlaying?.update(item: currentItem, isPlaying: true, position: 0, duration: duration)
            reporter?.start(itemID: currentItem?.id, position: 0)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadCurrentTrack(autoPlay: true)
        } else {
            isPlaying = false
            nowPlaying?.update(item: currentItem, isPlaying: false, position: duration, duration: duration)
        }
    }

    private func observeStatus(of playerItem: AVPlayerItem) {
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let message = observed.error?.localizedDescription ?? String(localized: "不明なエラー")
            Task { @MainActor in self?.handlePlaybackFailure(message) }
        }
    }

    private func handlePlaybackFailure(_ message: String) {
        logger.error("再生に失敗: \(message, privacy: .public)")
        isPlaying = false
    }

    private func reportStopIfNeeded(position: TimeInterval? = nil) {
        reporter?.stop(itemID: currentItem?.id, position: position ?? currentTime)
    }

}
