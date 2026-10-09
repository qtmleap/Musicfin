import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("PlaybackQueueOrder: \(message)\n".utf8))
        exit(1)
    }
}

private func makeOrder(
    _ items: [Int],
    startingAt index: Int?,
    shuffled: Bool
) -> PlaybackQueueOrder<Int>? {
    PlaybackQueueOrder.make(
        items: items,
        startingAt: index,
        shuffled: shuffled,
        shuffle: { Array($0.reversed()) }
    )
}

let original = [10, 20, 30, 40]
let shuffled = makeOrder(original, startingAt: 2, shuffled: true)
expect(shuffled?.queue == [30, 40, 20, 10], "選んだ曲を先頭にして残りを注入順に並べる")
expect(shuffled?.original == original, "元順を保持する")
expect(shuffled?.currentIndex == 0, "shuffle時の開始位置を先頭にする")
expect(shuffled?.isShuffled == true, "shuffle状態を同時に確定する")
expect(shuffled?.queue.sorted() == original.sorted(), "重複や欠落を作らない")

let ordered = makeOrder(original, startingAt: 2, shuffled: false)
expect(ordered?.queue == original, "通常再生は元順を保つ")
expect(ordered?.currentIndex == 2, "通常再生は指定位置から始める")
expect(ordered?.isShuffled == false, "通常再生状態を同時に確定する")

// 位置の指定がない一括シャッフルは先頭曲を固定せず、全曲を並べ替え対象にする。
let bulk = makeOrder(original, startingAt: nil, shuffled: true)
expect(bulk?.queue == [40, 30, 20, 10], "既定のシャッフルは全曲を並べ替える")
expect(bulk?.queue.first != original.first, "既定のシャッフルは先頭曲を固定しない")
expect(bulk?.currentIndex == 0 && bulk?.isShuffled == true, "既定のシャッフルは先頭から始める")
expect(bulk?.original == original, "既定のシャッフルも元順を保持する")

let explicit = makeOrder(original, startingAt: 0, shuffled: true)
expect(explicit?.queue == [10, 40, 30, 20], "明示した位置は選んだ曲を先頭に固定する")

let plain = makeOrder(original, startingAt: nil, shuffled: false)
expect(plain?.queue == original && plain?.currentIndex == 0, "通常再生の既定は先頭から始める")

expect(makeOrder([], startingAt: nil, shuffled: true) == nil, "空配列は既定でも拒否する")
expect(makeOrder([], startingAt: 0, shuffled: true) == nil, "空配列を拒否する")
expect(makeOrder(original, startingAt: -1, shuffled: true) == nil, "負の位置を拒否する")
expect(makeOrder(original, startingAt: original.count, shuffled: true) == nil, "範囲外を拒否する")

print("PlaybackQueueOrder: atomic ordered and shuffled starts passed")
