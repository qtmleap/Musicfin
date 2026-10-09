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
    var repeatMode: RepeatMode = .off {
        didSet {
            // 終了通知直後の旧曲には、新しいリピート設定を当てて自動送りを止めない。
            if let actual = player.currentItem, trackIDByPlayerItem[ObjectIdentifier(actual)] == nil { return }
            player.actionAtItemEnd = repeatMode == .one ? .pause : .advance
        }
    }

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

    private let player: AVQueuePlayer
    /// 差し替えがなければ Jellyfin のストリーム URL から AVPlayerItem を作る。
    private let playerItemResolver: (@MainActor (MediaItem) async -> AVPlayerItem?)?
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
    /// 積んだ曲ごとの失敗監視。対応表から外すときに一緒に捨て、古い曲の失敗で今の曲を止めない。
    private var statusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// ストリーム URL の解決は非同期なので、解決中に曲が切り替わった古い結果を捨てるための世代番号。
    private var loadGeneration = 0
    private var lookaheadTask: Task<Void, Never>?
    private var currentItemObservation: NSKeyValueObservation?
    /// 終了通知の後に AVQueuePlayer が旧曲を外すまで、読み直しで新しい曲を積まない。
    private var reloadAfterAdvance = false
    private var rebuildAfterAdvance = false

    init(
        player: AVQueuePlayer = AVQueuePlayer(),
        playerItemResolver: (@MainActor (MediaItem) async -> AVPlayerItem?)? = nil
    ) {
        self.player = player
        self.playerItemResolver = playerItemResolver
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

    /// キューを差し替えて指定位置から再生する。位置を省くと、通常は元順の先頭から、シャッフルは全曲から始める。
    func play(items: [MediaItem], startingAt index: Int? = nil, shuffled: Bool = false) {
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
        forgetAllPlayerItems()
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
        // リピート 1 曲では曲末で次へ進ませず現在の AVPlayerItem を保ち、先読みも止める。
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
        if let playerItemResolver { return await playerItemResolver(item) }
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
        observeStatus(of: playerItem, trackID: item.id)
        player.insert(playerItem, after: after)
    }

    private func forgetPlayerItem(_ identifier: ObjectIdentifier) {
        trackIDByPlayerItem.removeValue(forKey: identifier)
        statusObservations.removeValue(forKey: identifier)
    }

    private func forgetAllPlayerItems() {
        trackIDByPlayerItem.removeAll()
        statusObservations.removeAll()
    }

    /// AVQueuePlayer が実際に再生している曲の ID。論理上の現在曲とずれている間を見分けるのに使う。
    private var actualCurrentTrackID: String? {
        player.currentItem.flatMap { trackIDByPlayerItem[ObjectIdentifier($0)] }
    }

    /// 解決中の URL があっても、その結果をキューへ積ませない。
    private func invalidatePendingLoads() {
        loadGeneration += 1
        reloadAfterAdvance = false
        rebuildAfterAdvance = false
        lookaheadTask?.cancel()
        lookaheadTask = nil
    }

    private func loadCurrentTrack(autoPlay: Bool) {
        reportStopIfNeeded()
        invalidatePendingLoads()
        player.removeAllItems()
        forgetAllPlayerItems()
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
            refillLookahead()
            if autoPlay { play() }
        }
    }

    /// 先読み用に次の 1 曲だけを AVQueuePlayer に積む。これがギャップレス再生の肝。
    /// 終了通知は AVQueuePlayer が次へ進む前に届くので、終了した曲は数にも積む位置にも含めない。
    private func refillLookahead(excludingEnded ended: ObjectIdentifier? = nil) {
        // 古い URL の解決結果が新しい状態へ積まれないよう、判定の前に必ず取り消す。
        lookaheadTask?.cancel()
        lookaheadTask = nil
        guard repeatMode != .one else { return }
        guard player.items().filter({ ObjectIdentifier($0) != ended }).count < 2 else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]

        let generation = loadGeneration
        lookaheadTask = Task { [weak self] in
            guard let self else { return }
            let playerItem = await makePlayerItem(for: next)
            // 解決中に曲が進んだ・キューが変わった・別の先読みが積まれた場合は捨てる。
            let remaining = player.items().filter { ObjectIdentifier($0) != ended }
            guard !Task.isCancelled, generation == loadGeneration, remaining.count < 2,
                queue.indices.contains(currentIndex + 1), queue[currentIndex + 1].id == next.id,
                remaining.last.flatMap({ trackIDByPlayerItem[ObjectIdentifier($0)] }) == queue[currentIndex].id,
                let playerItem
            else { return }
            enqueue(playerItem, for: next, after: remaining.last)
        }
    }

    /// 先読み分だけを積み直す（キュー編集・リピート変更時）。現在再生中の曲は触らない。
    private func rebuildLookahead() {
        lookaheadTask?.cancel()
        let playing = player.currentItem
        if let playing, trackIDByPlayerItem[ObjectIdentifier(playing)] == nil {
            rebuildAfterAdvance = true
            return
        }
        for queued in player.items() where queued !== playing {
            forgetPlayerItem(ObjectIdentifier(queued))
            player.remove(queued)
        }
        refillLookahead()
    }

    // MARK: - 監視

    private func setUpObservers() {
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if player.currentItem == nil {
                    if reloadAfterAdvance { loadCurrentTrack(autoPlay: true) }
                } else {
                    player.actionAtItemEnd = repeatMode == .one ? .pause : .advance
                    synchronizeActualTrack()
                    if rebuildAfterAdvance {
                        rebuildAfterAdvance = false
                        rebuildLookahead()
                    }
                }
            }
        }
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimeUpdate() }
        }
        cleanup.add { [player] in player.removeTimeObserver(observer) }

        // Notification から取り出せるのは非 Sendable な AVPlayerItem なので、
        // 同一性の判定に使う ObjectIdentifier だけを境界の外へ渡す。
        cleanup.observe(AVPlayerItem.didPlayToEndTimeNotification) { notification in
            let identifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { [weak self] in self?.handleItemEnded(identifier) }
        }
    }

    private func synchronizeActualTrack() {
        // AVQueuePlayer が失敗した先読みを飛ばしたときも、実際の音声に表示を合わせる。
        if let id = actualCurrentTrackID, id != currentItem?.id,
            let index = queue.indices.dropFirst(currentIndex).first(where: { queue[$0].id == id })
        {
            reportStopIfNeeded()
            currentIndex = index
            currentTime = 0
            nowPlaying?.update(item: currentItem, isPlaying: isPlaying, position: 0, duration: duration)
            reporter?.start(itemID: currentItem?.id, position: 0)
            refillLookahead()
        }
    }

    private func handleTimeUpdate() {
        synchronizeActualTrack()
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        // 論理上は次の曲へ進んだのに AVQueuePlayer がまだ前の曲を指している間の時刻は、新しい曲の位置にしない。
        guard let currentID = currentItem?.id, actualCurrentTrackID == currentID else { return }
        currentTime = seconds
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        nowPlaying?.updateElapsed(seconds, isPlaying: isPlaying)
        reporter?.progressIfNeeded(itemID: currentItem?.id, position: seconds, isPaused: !isPlaying)
    }

    private func handleItemEnded(_ endedItem: ObjectIdentifier?) {
        guard let endedItem, trackIDByPlayerItem[endedItem] == currentItem?.id else { return }
        reportStopIfNeeded(position: duration)

        if repeatMode == .one {
            // actionAtItemEnd が .pause なので同じ曲が残っている。頭へ戻して続ける。
            currentTime = 0
            player.seek(to: .zero)
            player.play()
            nowPlaying?.update(item: currentItem, isPlaying: true, position: 0, duration: duration)
            reporter?.start(itemID: currentItem?.id, position: 0)
            return
        }

        // 同じ曲の終了通知を二度処理して曲を飛ばさないよう、ここで一度だけ消費する。
        forgetPlayerItem(endedItem)

        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            let remaining = player.items().filter { ObjectIdentifier($0) != endedItem }
            let queuedIDs = remaining.map { trackIDByPlayerItem[ObjectIdentifier($0)] }
            let advance =
                remaining.first?.status == .failed
                ? PlaybackAdvance.reload
                : PlaybackAdvance.decide(expectedNext: queue[nextIndex].id, queuedIDs: queuedIDs)
            currentIndex = nextIndex
            currentTime = 0
            switch advance {
            case .keepQueued:
                // AVQueuePlayer は先読み分へ自動で進むので、論理位置だけ合わせて先読みを補充する。
                refillLookahead(excludingEnded: endedItem)
                nowPlaying?.update(item: currentItem, isPlaying: true, position: 0, duration: duration)
                reporter?.start(itemID: currentItem?.id, position: 0)
            case .reload:
                // 先読みが間に合っていない・食い違っているときは、期待する曲を読み直す。
                reloadCurrentAfterAdvance(ended: endedItem)
            }
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            reloadCurrentAfterAdvance(ended: endedItem)
        } else {
            isPlaying = false
            nowPlaying?.update(item: currentItem, isPlaying: false, position: duration, duration: duration)
        }
    }

    private func reloadCurrentAfterAdvance(ended: ObjectIdentifier) {
        invalidatePendingLoads()
        // 旧曲の自動切り替えが済んでいれば、その場で正しい曲に差し替えられる。
        guard player.currentItem.map(ObjectIdentifier.init) == ended else {
            loadCurrentTrack(autoPlay: true)
            return
        }
        for queued in player.items() where ObjectIdentifier(queued) != ended {
            forgetPlayerItem(ObjectIdentifier(queued))
            player.remove(queued)
        }
        reloadAfterAdvance = true
        isBuffering = true
        currentTime = 0
        nowPlaying?.update(item: currentItem, isPlaying: true, position: 0, duration: duration)
        if player.currentItem == nil { loadCurrentTrack(autoPlay: true) }
    }

    private func observeStatus(of playerItem: AVPlayerItem, trackID: String) {
        let identifier = ObjectIdentifier(playerItem)
        statusObservations[identifier] = playerItem.observe(\.status, options: [.initial, .new]) {
            [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let message = observed.error?.localizedDescription ?? String(localized: "不明なエラー")
            Task { @MainActor in self?.handlePlaybackFailure(message, of: identifier, trackID: trackID) }
        }
    }

    private func handlePlaybackFailure(_ message: String, of identifier: ObjectIdentifier, trackID: String) {
        // 対応表から外れた曲の失敗は古い通知なので、今の再生を止めない。
        guard trackIDByPlayerItem[identifier] == trackID else { return }
        logger.error("再生に失敗: \(message, privacy: .public)")
        if player.currentItem.map(ObjectIdentifier.init) == identifier, trackID == currentItem?.id {
            player.pause()
            isPlaying = false
            nowPlaying?.update(item: currentItem, isPlaying: false, position: currentTime, duration: duration)
        }
    }

    private func reportStopIfNeeded(position: TimeInterval? = nil) {
        reporter?.stop(itemID: currentItem?.id, position: position ?? currentTime)
    }

}
