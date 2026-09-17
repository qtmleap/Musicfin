import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("PlaybackQueueOrder: \(message)\n".utf8))
        exit(1)
    }
}

private func makeOrder(
    _ items: [Int],
    startingAt index: Int,
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

expect(makeOrder([], startingAt: 0, shuffled: true) == nil, "空配列を拒否する")
expect(makeOrder(original, startingAt: -1, shuffled: true) == nil, "負の位置を拒否する")
expect(makeOrder(original, startingAt: original.count, shuffled: true) == nil, "範囲外を拒否する")

print("PlaybackQueueOrder: atomic ordered and shuffled starts passed")
