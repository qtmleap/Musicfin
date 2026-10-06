import Foundation

/// 指の移動と慣性だけを読み、操作帯の伸縮による位置補正を次の操作へ戻さない。
nonisolated struct LyricsControlsScroll {
    private(set) var isHidden = false
    var isDragging: Bool { lastTranslation != nil }

    private var lastTranslation: Double?
    private var lastOffset: Double?
    private var lastDirection = 0.0
    private var accumulation = 0.0

    /// 32 / 16 pt は Musicfin の決定値。戻す方を小さくし、操作へ戻る意図を小さな引きで拾う。
    private static let hideThreshold = 32.0
    private static let showThreshold = 16.0

    mutating func drag(to translation: Double, isAtTop: Bool = false) -> Bool? {
        guard translation.isFinite else { return nil }
        defer { lastTranslation = translation }
        guard let previous = lastTranslation else {
            accumulation = 0
            lastDirection = 0
            return nil
        }
        let delta = previous - translation
        guard delta != 0 else { return nil }
        lastDirection = delta
        if isAtTop, delta < 0 {
            accumulation = 0
            return setHidden(false)
        }
        return consume(delta)
    }

    mutating func endDragging() {
        lastTranslation = nil
        // 閾値へ届く直前に離しても、続く慣性で残りの移動量を数えられるよう積算は残す。
    }

    mutating func observeOffset(
        _ offset: Double, isDecelerating: Bool, layoutChanged: Bool = false, allowTopShortcut: Bool = false
    ) -> Bool? {
        guard offset.isFinite else { return nil }
        let delta = offset - (lastOffset ?? offset)
        lastOffset = offset
        guard !layoutChanged else { return nil }
        if allowTopShortcut, lastDirection < 0, isDragging || isDecelerating {
            accumulation = 0
            return setHidden(false)
        }
        // 位置補正は器の更新と別の通知でも届く。指の間は translation が所有し、慣性は
        // 最後の実指と同じ向きだけ数えることで、補正の逆向き変位から帯が再び動く循環を断つ。
        guard !isDragging, isDecelerating, delta * lastDirection > 0 else { return nil }
        return consume(delta)
    }

    mutating func stop() {
        lastTranslation = nil
        lastDirection = 0
        accumulation = 0
    }

    private mutating func consume(_ delta: Double) -> Bool? {
        if accumulation * delta < 0 { accumulation = 0 }
        accumulation += delta
        if accumulation >= Self.hideThreshold {
            accumulation = 0
            return setHidden(true)
        }
        if accumulation <= -Self.showThreshold {
            accumulation = 0
            return setHidden(false)
        }
        return nil
    }

    private mutating func setHidden(_ hidden: Bool) -> Bool? {
        guard isHidden != hidden else { return nil }
        isHidden = hidden
        return hidden
    }
}
