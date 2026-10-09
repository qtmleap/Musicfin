import Foundation

/// 再生開始時のキューと元順を一度に確定し、シャッフル状態との食い違いを作らない。
nonisolated struct PlaybackQueueOrder<Item> {
    let queue: [Item]
    let original: [Item]
    let currentIndex: Int
    let isShuffled: Bool

    static func make(
        items: [Item],
        startingAt index: Int?,
        shuffled: Bool,
        shuffle: ([Item]) -> [Item]
    ) -> Self? {
        guard !items.isEmpty else { return nil }
        // 位置の指定がないシャッフルは全曲が対象。先頭曲を固定すると毎回同じ曲から始まってしまう。
        if index == nil, shuffled {
            return Self(queue: shuffle(items), original: items, currentIndex: 0, isShuffled: true)
        }
        let index = index ?? 0
        guard items.indices.contains(index) else { return nil }
        guard shuffled else {
            return Self(queue: items, original: items, currentIndex: index, isShuffled: false)
        }

        let startingItem = items[index]
        var remaining = items
        remaining.remove(at: index)
        return Self(
            queue: [startingItem] + shuffle(remaining),
            original: items,
            currentIndex: 0,
            isShuffled: true
        )
    }
}
