import Foundation
import Observation

/// 表示上の重複除去で取得位置がずれないよう、サーバーの件数を別に保持する。
@MainActor @Observable
final class MediaPageCollection {
    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var isComplete = false
    private(set) var hasLoaded = false
    private(set) var revision = 0
    private(set) var needsManualContinuation = false
    private var duplicatePages = 0
    private(set) var errorMessage: String?
    private var nextIndex = 0
    private var generation = 0
    private var failedRefresh = false

    func reset() {
        generation += 1
        revision += 1
        duplicatePages = 0
        needsManualContinuation = false
        items = []
        nextIndex = 0
        isLoading = false
        isComplete = false
        hasLoaded = false
        errorMessage = nil
        failedRefresh = false
    }

    func loadNext(fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        guard !isLoading else { return }
        if errorMessage != nil, failedRefresh {
            await refresh(fetch: fetch)
        } else if !isComplete {
            await request(refresh: false, fetch: fetch)
        }
    }

    func refresh(fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        guard !Task.isCancelled else { return }
        generation += 1
        await request(refresh: true, fetch: fetch)
    }

    private func request(refresh: Bool, fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        guard !Task.isCancelled else { return }
        let token = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let page = try await fetch(refresh ? 0 : nextIndex)
            try Task.checkCancellation()
            // アカウント変更や更新前の応答を、新しい一覧へ混ぜない。
            guard token == generation else { return }
            if refresh {
                items = []
                nextIndex = 0
                duplicatePages = 0
            }
            var known = Set(items.map(\.id))
            let unique = page.items.filter { known.insert($0.id).inserted }
            items.append(contentsOf: unique)
            duplicatePages = unique.isEmpty && !page.items.isEmpty ? duplicatePages + 1 : 0
            needsManualContinuation = duplicatePages >= 3
            revision += 1
            nextIndex += page.items.count
            isComplete = nextIndex >= page.totalRecordCount || page.items.isEmpty
            hasLoaded = true
            failedRefresh = false
        } catch {
            guard token == generation, !(error is CancellationError), !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            failedRefresh = refresh
        }
    }

    func updateFavorite(_ value: Bool, itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        var data = items[index].userData ?? UserItemData()
        data.isFavorite = value
        items[index].userData = data
    }
}
