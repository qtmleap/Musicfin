import Foundation
import Observation

/// Instant Mix に取得位置がないため、別の種から得た曲を重複なく継ぎ足す。
@MainActor @Observable
final class RadioMixCatalog {
    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var isComplete = false
    private(set) var needsManualContinuation = false
    private(set) var errorMessage: String?
    private let seeds = MediaPageCollection()
    private var pendingSeed: MediaItem?
    private var seedIndex = 0
    private var usedSeeds = Set<String>()
    private var generation = 0

    func reset() {
        generation += 1
        seeds.reset()
        pendingSeed = nil
        seedIndex = 0
        usedSeeds = []
        items = []
        isLoading = false
        isComplete = false
        needsManualContinuation = false
        errorMessage = nil
    }

    func loadNext(
        preferredSeed: MediaItem?,
        fetchSeeds: (Int) async throws -> QueryResult<MediaItem>,
        fetchMix: (String) async throws -> [MediaItem]
    ) async {
        guard !isLoading, !isComplete, !Task.isCancelled else { return }
        let token = generation
        isLoading = true
        errorMessage = nil
        needsManualContinuation = false
        defer { if generation == token { isLoading = false } }
        do {
            // 同じ曲しか返らないサーバーへ、見えている末尾から際限なく問い合わせない。
            for _ in 0..<3 {
                var seed: MediaItem?
                if let pendingSeed {
                    seed = pendingSeed
                } else if let preferredSeed, !usedSeeds.contains(preferredSeed.id) {
                    seed = preferredSeed
                } else {
                    if seedIndex >= seeds.items.count, !seeds.isComplete {
                        await seeds.loadNext(fetch: fetchSeeds)
                        guard generation == token else { return }
                        if let error = seeds.errorMessage {
                            errorMessage = error
                            return
                        }
                    }
                    while seedIndex < seeds.items.count {
                        let candidate = seeds.items[seedIndex]
                        seedIndex += 1
                        if !usedSeeds.contains(candidate.id) {
                            seed = candidate
                            break
                        }
                    }
                }
                guard let seed else {
                    isComplete = seeds.isComplete && seedIndex >= seeds.items.count
                    needsManualContinuation = !isComplete
                    return
                }
                pendingSeed = seed
                let batch = try await fetchMix(seed.id)
                try Task.checkCancellation()
                guard generation == token else { return }
                pendingSeed = nil
                usedSeeds.insert(seed.id)
                var known = Set(items.map(\.id))
                let unique = batch.filter { $0.type == .audio && known.insert($0.id).inserted }
                items.append(contentsOf: unique)
                if !unique.isEmpty { return }
            }
            needsManualContinuation = true
        } catch {
            if generation == token, !(error is CancellationError), !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}
