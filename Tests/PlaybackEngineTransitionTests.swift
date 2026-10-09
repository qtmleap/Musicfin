import AVFoundation
import Foundation

@main
struct PlaybackEngineTransitionTests {
    @MainActor static func wait(_ predicate: () -> Bool, timeout: TimeInterval = 6) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            precondition(Date() < deadline, "Playback transition timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func verifySequence(
        base: URL, delayed: Bool, duplicate: Bool = false, wrongLookahead: Bool = false, failedLookahead: Bool = false
    ) async throws {
        FileHandle.standardError.write(
            Data(
                "CASE delayed=\(delayed) duplicate=\(duplicate) wrong=\(wrongLookahead) failed=\(failedLookahead)\n"
                    .utf8))
        let player = AVQueuePlayer()
        player.volume = 0
        var identity: [ObjectIdentifier: String] = [:]
        var requests: [String: Int] = [:]
        let engine = PlaybackEngine(
            player: player,
            playerItemResolver: { item in
                requests[item.id, default: 0] += 1
                if delayed && item.id == "B" && requests[item.id] == 1 {
                    // URL 解決が取消をすぐ処理しない場合も、古い先読みを積ませない。
                    await Task.detached { try? await Task.sleep(for: .milliseconds(1500)) }.value
                }
                let file = failedLookahead && item.id == "B" && requests[item.id] == 1 ? "missing.wav" : "track.wav"
                let result = AVPlayerItem(url: base.appendingPathComponent(file))
                identity[ObjectIdentifier(result)] = item.id
                return result
            })
        defer { engine.stop() }
        engine.configure(client: JellyfinClient())
        let ids = duplicate ? ["A", "A", "B"] : ["A", "B", "C"]
        engine.play(items: ids.map { MediaItem(id: $0, name: $0, runTimeTicks: 10_000_000) })
        var injectedWrong = false
        var heard: [String] = []
        var previous: AVPlayerItem?
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if wrongLookahead, !injectedWrong, player.items().count == 2 {
                player.remove(player.items()[1])
                let rogue = AVPlayerItem(url: base.appendingPathComponent("track.wav"))
                identity[ObjectIdentifier(rogue)] = "ROGUE"
                player.insert(rogue, after: player.currentItem)
                injectedWrong = true
            }
            if let actual = player.currentItem {
                let key = ObjectIdentifier(actual)
                if actual.currentTime().seconds > 0.05, actual !== previous, let id = identity[key] {
                    heard.append(id)
                    previous = actual
                }
                if actual.currentTime().seconds > 0.25, let id = identity[key] {
                    precondition(
                        engine.currentItem?.id == id,
                        "Audio \(id) vs logical \(engine.currentItem?.id ?? "nil") index \(engine.currentIndex), failed=\(failedLookahead) t=\(actual.currentTime().seconds)"
                    )
                    precondition(NowPlayingCenter.publishedItemID == id, "Now Playing metadata differs from audio")
                }
            }
            if heard.count == 3 && player.currentItem == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!wrongLookahead || injectedWrong)
        let expected = failedLookahead && requests["B"] == 1 ? ["A", "C"] : ids
        precondition(heard == expected, "Skipped or repeated a track: \(heard)")
        precondition(engine.currentIndex == 2)
        precondition(!engine.isPlaying)
        print(
            "PlaybackEngine: \(delayed ? "delayed" : "ready") lookahead, duplicate=\(duplicate), wrongLookahead=\(wrongLookahead), audio and metadata matched \(heard)"
        )
    }

    @MainActor static func verifyRepeatAndStaleEnd(base: URL) async throws {
        let player = AVQueuePlayer()
        player.volume = 0
        let engine = PlaybackEngine(
            player: player,
            playerItemResolver: { _ in
                AVPlayerItem(url: base.appendingPathComponent("track.wav"))
            })
        defer { engine.stop() }
        engine.configure(client: JellyfinClient())
        engine.repeatMode = .one
        engine.play(items: [MediaItem(id: "A", runTimeTicks: 10_000_000)])
        try await wait { player.currentItem != nil && player.currentTime().seconds > 0.1 }
        let first = player.currentItem!
        try await Task.sleep(for: .milliseconds(2300))
        precondition(player.currentItem === first && engine.currentIndex == 0 && engine.isPlaying)
        engine.repeatMode = .off
        engine.play(items: [MediaItem(id: "B", runTimeTicks: 10_000_000)])
        try await wait { player.currentItem != nil && player.currentItem !== first }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first)
        precondition(engine.currentItem?.id == "B" && engine.currentIndex == 0)
        engine.stop()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first)
        precondition(engine.currentItem == nil && NowPlayingCenter.publishedItemID == nil)
        print("PlaybackEngine: repeat-one retained audio, stale end after replacement/stop ignored")
    }

    @MainActor static func verifyEndWindowAndWrap(base: URL, repeatOne: Bool = false, wrap: Bool = false) async throws {
        let player = AVQueuePlayer()
        player.volume = 0
        var identity: [ObjectIdentifier: String] = [:]
        var edited = false
        let engine = PlaybackEngine(
            player: player,
            playerItemResolver: { item in
                let result = AVPlayerItem(url: base.appendingPathComponent("track.wav"))
                identity[ObjectIdentifier(result)] = item.id
                return result
            })
        defer {
            NowPlayingCenter.onUpdate = nil
            engine.stop()
        }
        engine.configure(client: JellyfinClient())
        if wrap { engine.repeatMode = .all }
        NowPlayingCenter.onUpdate = { item in
            guard !wrap, !edited, item?.id == "B", let actual = player.currentItem,
                identity[ObjectIdentifier(actual)] == "A"
            else { return }
            edited = true
            if repeatOne {
                engine.cycleRepeatMode()
                engine.cycleRepeatMode()
            } else {
                engine.playNext([MediaItem(id: "D", runTimeTicks: 10_000_000)])
            }
        }
        let ids = wrap ? ["A", "B"] : ["A", "B", "C"]
        engine.play(items: ids.map { MediaItem(id: $0, runTimeTicks: 10_000_000) })
        var heard: [String] = []
        var previous: AVPlayerItem?
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            if let actual = player.currentItem, actual.currentTime().seconds > 0.05,
                let id = identity[ObjectIdentifier(actual)]
            {
                precondition(engine.currentItem?.id == id && NowPlayingCenter.publishedItemID == id)
                if actual !== previous {
                    heard.append(id)
                    previous = actual
                }
            }
            if wrap && heard.count == 3 { break }
            if !wrap && !repeatOne && heard.count == 4 && player.currentItem == nil { break }
            if repeatOne && heard == ["A", "B"] && Date() > deadline.addingTimeInterval(-3) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if wrap {
            precondition(heard == ["A", "B", "A"] && engine.currentIndex == 0)
        } else if repeatOne {
            precondition(edited && heard == ["A", "B"] && engine.currentIndex == 1 && engine.isPlaying)
        } else {
            precondition(edited && heard == ["A", "B", "D", "C"])
        }
        print("PlaybackEngine: end-window editing/repeat=\(repeatOne), wrap=\(wrap) matched \(heard)")
    }

    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        try await verifySequence(base: base, delayed: false)
        try await verifySequence(base: base, delayed: true)
        try await verifySequence(base: base, delayed: false, duplicate: true)
        try await verifySequence(base: base, delayed: false, wrongLookahead: true)
        try await verifySequence(base: base, delayed: false, failedLookahead: true)
        try await verifyRepeatAndStaleEnd(base: base)
        try await verifyEndWindowAndWrap(base: base)
        try await verifyEndWindowAndWrap(base: base, repeatOne: true)
        try await verifyEndWindowAndWrap(base: base, wrap: true)
    }
}
