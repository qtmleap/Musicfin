import AVFoundation
import os

/// バックグラウンド再生・電話などによる中断・イヤホン抜き差しへの対応をまとめる。
@MainActor
final class AudioSessionManager {
    /// 中断が終わり、再生を再開してよいときに呼ばれる。
    var onShouldResume: (() -> Void)?
    /// イヤホンが外されたなど、直ちに一時停止すべきときに呼ばれる。
    var onShouldPause: (() -> Void)?

    private let logger = Logger(subsystem: "jp.qleap.musicfin", category: "AudioSession")
    private let cleanup = CleanupBox()
    private var didRegisterObservers = false

    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback にすることでサイレントスイッチを無視し、バックグラウンドでも鳴り続ける。
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            logger.error("オーディオセッションの有効化に失敗: \(error.localizedDescription, privacy: .public)")
        }
        registerObservers()
    }

    private func registerObservers() {
        guard !didRegisterObservers else { return }
        didRegisterObservers = true

        // Notification 自体は Sendable ではないため、必要な値だけを取り出してから
        // メインアクターの処理に渡す。
        cleanup.observe(AVAudioSession.interruptionNotification) { notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated { [weak self] in
                self?.handleInterruption(type: type, optionsRaw: optionsRaw)
            }
        }

        cleanup.observe(AVAudioSession.routeChangeNotification) { notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { [weak self] in
                self?.handleRouteChange(reason: reason)
            }
        }
    }

    /// 電話や他アプリの音声による中断。終了時に `.shouldResume` が付いていれば再開する。
    private func handleInterruption(type: AVAudioSession.InterruptionType?, optionsRaw: UInt) {
        switch type {
        case .began:
            onShouldPause?()
        case .ended:
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                onShouldResume?()
            }
        default:
            break
        }
    }

    /// イヤホンやスピーカーの切り替え。取り外し時は Apple 純正アプリと同様に一時停止する。
    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        if reason == .oldDeviceUnavailable { onShouldPause?() }
    }
}
