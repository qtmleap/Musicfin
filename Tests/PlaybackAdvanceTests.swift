import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("PlaybackAdvance: \(message)\n".utf8))
        exit(1)
    }
}

expect(PlaybackAdvance.decide(expectedNext: "B", queuedIDs: ["B"]) == .keepQueued, "期待どおりの先読みは維持する")
expect(PlaybackAdvance.decide(expectedNext: "B", queuedIDs: ["B", "C"]) == .keepQueued, "先頭が一致すれば後続は問わない")
expect(PlaybackAdvance.decide(expectedNext: "B", queuedIDs: []) == .reload, "先読みが空なら読み直す")
expect(PlaybackAdvance.decide(expectedNext: "B", queuedIDs: ["C"]) == .reload, "食い違う先読みは読み直す")
expect(PlaybackAdvance.decide(expectedNext: "B", queuedIDs: [nil]) == .reload, "対応表にない曲は信用しない")

print("PlaybackAdvance: queued next validation passed")
