import Foundation
import Observation

/// 再生に関するユーザー設定。アプリ全体で 1 つだけ存在し、変更は次に再生する曲から反映される。
@MainActor
@Observable
final class PlaybackSettings {
    private enum Defaults {
        static let wifiQuality = "playback.quality.wifi"
        static let cellularQuality = "playback.quality.cellular"
    }

    var wifiQuality: StreamQuality {
        didSet { UserDefaults.standard.set(wifiQuality.rawValue, forKey: Defaults.wifiQuality) }
    }

    var cellularQuality: StreamQuality {
        didSet { UserDefaults.standard.set(cellularQuality.rawValue, forKey: Defaults.cellularQuality) }
    }

    init() {
        // モバイル回線は通信量を抑える側に倒し、Wi-Fi は聴き劣りしない圧縮を既定にする。
        wifiQuality = Self.stored(Defaults.wifiQuality) ?? .high
        cellularQuality = Self.stored(Defaults.cellularQuality) ?? .saver
    }

    private static func stored(_ key: String) -> StreamQuality? {
        UserDefaults.standard.string(forKey: key).flatMap(StreamQuality.init(rawValue:))
    }
}
