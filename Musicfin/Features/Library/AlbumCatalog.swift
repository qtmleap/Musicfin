import Foundation
import Observation

/// ジャンルを途中のページだけで確定しないよう、一覧の取得完了を保持する。
@MainActor @Observable
final class AlbumCatalog {
    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var isComplete = false
    private(set) var errorMessage: String?
    private var nextIndex = 0

    var genres: [String] {
        guard isComplete else { return [] }
        return Set(
            items.flatMap { $0.genres ?? [] }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func albums(in genre: String) -> [MediaItem] {
        guard isComplete else { return [] }
        return items.filter {
            ($0.genres ?? []).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == genre }
        }
    }

    func loadNext(fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        await requestPage(reset: false, fetch: fetch)
    }

    func refresh(fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        while isLoading {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        await requestPage(reset: true, fetch: fetch)
    }

    private func requestPage(reset: Bool, fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        guard !isLoading, reset || !isComplete, !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await fetch(reset ? 0 : nextIndex)
            try Task.checkCancellation()
            // 更新に失敗したときは、直前まで見えていた一覧を残す。
            if reset {
                items = []
                nextIndex = 0
            }
            var known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { known.insert($0.id).inserted })
            // 重複を除いた表示件数ではなく、サーバーから受け取った件数で次の位置を決める。
            nextIndex += page.items.count
            isComplete = nextIndex >= page.totalRecordCount || page.items.isEmpty
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func loadAll(fetch: (Int) async throws -> QueryResult<MediaItem>) async {
        while !isComplete, !Task.isCancelled {
            if isLoading {
                // 別タブの取得完了を待ち、同じページを二重に要求しない。
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                continue
            }
            await loadNext(fetch: fetch)
            if errorMessage != nil { return }
        }
    }
}
