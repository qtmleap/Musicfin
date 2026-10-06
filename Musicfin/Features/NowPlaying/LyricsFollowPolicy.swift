import Foundation

nonisolated enum LyricsFollowPolicy {
    static func canReacquire(
        activeIndex: Int?, visibleIndices: Set<Int>, introID: Int, isSynced: Bool, isUserScrolling: Bool
    ) -> Bool {
        isSynced && !isUserScrolling && visibleIndices.contains(activeIndex ?? introID)
    }

    static func blurMultiplier(
        index: Int, activeIndex: Int?, isSynced: Bool, isFollowing: Bool, reduceTransparency: Bool
    ) -> Double {
        guard isSynced, isFollowing, !reduceTransparency, index != activeIndex else { return 0 }
        // 上側を強く退かせる比率は実機の観察に合わせた暫定値で、Apple の実測値ではない。
        return activeIndex.map { index < $0 ? 1.5 : 1 } ?? 1
    }
}
