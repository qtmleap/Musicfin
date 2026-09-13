import Foundation

/// ストリーミングの音質。サーバーへ渡すコンテナとビットレート上限の組み合わせを表す。
nonisolated enum StreamQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 原音のまま。FLAC / ALAC を変換せずに再生する。
    case lossless
    /// AAC 256 kbps。
    case high
    /// AAC 128 kbps。
    case saver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lossless: String(localized: "ロスレス")
        case .high: String(localized: "高音質")
        case .saver: String(localized: "データ節約")
        }
    }

    var detail: String {
        switch self {
        case .lossless: String(localized: "原音のまま（FLAC / ALAC）")
        case .high: "AAC 256 kbps"
        case .saver: "AAC 128 kbps"
        }
    }
}
