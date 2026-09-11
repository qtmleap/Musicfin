import Foundation
import UIKit

/// アートワークのメモリ＋ディスクキャッシュ。同じ URL への同時リクエストは 1 本にまとめる。
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    /// 進行中のダウンロード。重複リクエストはこれを await して結果を共有する。
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "musicfin-artwork"
        )
        return URLSession(configuration: config)
    }()

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            var request = URLRequest(url: url)
            // まずディスクキャッシュを見て、無ければネットワークへ。
            request.cachePolicy = .returnCacheDataDontLoad
            if let cached = try? await session.data(for: request), let image = UIImage(data: cached.0) {
                return image
            }
            request.cachePolicy = .useProtocolCachePolicy
            guard let (data, _) = try? await session.data(for: request) else { return nil }
            return UIImage(data: data)
        }

        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.estimatedBytes)
        }
        return image
    }
}
nonisolated

    extension UIImage
{
    fileprivate var estimatedBytes: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
