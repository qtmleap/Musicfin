import Foundation
import UIKit

/// 表示する画像だけを復号してメモリへ置き、画面外の先読みは圧縮データのままディスクへ残す。
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<Result<UIImage, ArtworkFailure>, Never>] = [:]

    /// 既存の URL だけの呼び出しは匿名の範囲で保持し、表示側の認証を引き継がない。
    func image(for url: URL) async -> UIImage? {
        try? await image(for: ArtworkRequest(url: url)).get()
    }

    func image(for request: ArtworkRequest) async -> Result<UIImage, ArtworkFailure> {
        let key = request.storageKey
        if let image = cache.object(forKey: key as NSString) { return .success(image) }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<Result<UIImage, ArtworkFailure>, Never> {
            switch await ArtworkDataStore.shared.data(for: request) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let bytes):
                guard let decoded = ArtworkImageDecoder.decode(bytes) else { return .failure(.invalidImage) }
                // 表示時の遅延復号を避け、メインスレッドには描ける画像を渡す。
                return .success(UIImage(cgImage: decoded))
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if case .success(let image) = result {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return result
    }
}
