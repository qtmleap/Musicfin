import CoreGraphics

/// 横長フルプレイヤーの左右の割り付け。本文の開始位置を描画側と下スワイプの判定側で別々に計算すると、
/// 片方だけ動かしたときに閉じられる範囲が静かにずれるので、式はここに 1 つだけ置く。
nonisolated struct PlayerWideColumnGeometry {
    let margin: CGFloat
    let columnWidth: CGFloat
    /// 歌詞・キューの本文が始まる x。これより左が再生列の側。
    let detailLeading: CGFloat

    init(width: CGFloat) {
        margin = max(32, width * 0.049)
        columnWidth = min(536, (width - margin * 3) * 0.46)
        detailLeading = margin + columnWidth + 42
    }
}

/// iPad のフルプレイヤーで、下スワイプが閉じる操作として始められる場所。
nonisolated enum PlayerDismissRegion {
    /// 上端の帯。狭い幅の歌詞・キューはここだけが閉じる領域になる。
    static let headerHeight: CGFloat = 44
    static let wideBreakpoint: CGFloat = 900

    /// - Parameters:
    ///   - start: 指を置いた位置（ルートの座標空間）。
    ///   - detailIsVisible: 歌詞またはキューを出しているか。
    ///   - excluded: シークバーと音量の実測矩形。ここから始まった操作は閉じない。
    static func allows(start: CGPoint, size: CGSize, detailIsVisible: Bool, excluded: [CGRect]) -> Bool {
        guard !excluded.contains(where: { $0.contains(start) }) else { return false }
        // アートワーク状態は本文が無いので、縦に送るスクロールと競合せず、どこからでも閉じられる。
        guard detailIsVisible else { return true }
        // 狭い幅には左の再生列が無く、本文が全幅を占める。歌詞・キューの縦スクロールの
        // 下向きと区別できないので、上端の帯だけにとどめる。
        guard size.width >= wideBreakpoint else { return start.y < headerHeight }
        return start.x < PlayerWideColumnGeometry(width: size.width).detailLeading
    }
}
