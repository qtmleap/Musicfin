import CoreGraphics
import SwiftUI
import UIKit

/// アートワークから作った画面の配色（仕様 1.2 章）。
/// 数値だけを持つ値型にしてあるのは、走査を MainActor の外で回して結果だけを戻すため。
/// 型ごと `nonisolated` にするのは、既定が MainActor 隔離のこの設定では、
/// 走査を外へ出しても途中で呼ぶ変換や定数が MainActor に残って戻されてしまうため。
nonisolated struct ArtworkPalette: Equatable, Sendable {
    /// 明度の帯。詳細 2 画面は明るく、フルプレイヤー側は暗い。同じ色を使い回さない（仕様 1.2 章）。
    enum Band: Sendable {
        case detail
        case player
        /// フルプレイヤーの**曲が無いとき**だけの帯。参照は再生中と地の色も漸変の形も別で、
        /// 再生中の値を流用すると上半分が 10 % 明るくなる（仕様 6.2.1 章）。
        /// `emptyArtworkSide` と同じく「空状態専用の実測値」として分ける。
        case emptyPlayer

        /// 彩度の上限。取り出した色がこれより鮮やかでも、帯の側へ寄せる。
        /// フルプレイヤーは参照の左余白を上から下まで測ると 23.5%→28.8% と動いており、
        /// 単色で塗るこの模型では**その平均の 27%** が一番近い（仕様 1.2 章）。
        /// 以前の 22% は測った範囲の下端だけを見ていた値で、画面の大半で参照より鈍く見えていた。
        var maximumSaturation: Double {
            switch self {
            case .detail: 0.32
            case .player, .emptyPlayer: 0.27
            }
        }

        /// アートワークが取れないときの色相と彩度。**既定は無彩色**だが、フルプレイヤーの空状態は
        /// 参照が淡い寒色で、左余白を上から下まで測ると H **240°**・S **4.4〜6.5 %**（代表 6 %。
        /// 地は RGB 86/86/92）になる。純灰で塗ると色味が 6 足りない（仕様 6.2.1 章）。
        var neutralColor: (hue: Double, saturation: Double) {
            switch self {
            case .detail, .player: (0, 0)
            case .emptyPlayer: (240, 0.06)
            }
        }

        /// 帯の明度。詳細は実測 2 点（彩度 32%→明度 65%、彩度 11%→明度 74%）を通る直線、
        /// フルプレイヤーは固定（仕様 1.2 章）。**点が 2 つしか無いので、3 例目が外れたら式を直す。**
        /// 空状態は参照の平らな区間が 36.1 % なのでそこを基準にする（仕様 6.2.1 章）。
        func value(forSaturation saturation: Double) -> Double {
            switch self {
            case .detail: 0.78 - 0.4 * saturation
            case .player: 0.41
            case .emptyPlayer: 0.361
            }
        }

        /// 上端の倍率。基準色（倍率 1.0 の点）に対する比（仕様 1.2 章 手順 6）。
        /// 空状態が 1.0 なのは、参照が上端から画面の半分まで**明度を落とさない**ため（仕様 6.2.1 章）。
        var topScale: Double {
            switch self {
            case .detail: 0.94
            case .player: 0.99
            case .emptyPlayer: 1.0
            }
        }

        /// 下端の倍率。フルプレイヤーは詳細の 0.89 では足りず、参照全体との比較では 0.53 まで落ちる。
        var bottomScale: Double {
            switch self {
            case .detail: 0.89
            case .player: 0.53
            case .emptyPlayer: 0.58
            }
        }

        /// 両端の間に置く点。位置と、基準色に対する倍率の組。**数も位置も帯で違う。**
        /// `.detail` は最大付近が平坦で一点に決められないので、その範囲の中の 30% を 1 点だけ置く。
        /// `.player` は最大が 10% にあり、そこから下端まで直線では下りない。
        /// 0.10→1.0 と 1.0→0.53 を直線で結ぶと 30% が 0.896・60% が 0.739 になり、
        /// 実測の 0.93 / 0.845 から離れるので、途中の 2 点を省かない（仕様 1.2 章）。
        /// 空状態は **0.5 に折れ点が 1 つだけ**。参照は y 0..512 pt が 36.1 % で完全に平らで、
        /// そこから下端まで直線で 21 % へ落ちる。再生中の 3 点を流用すると上半分が明るくなる
        /// （仕様 6.2.1 章）。
        var innerStops: [(location: Double, scale: Double)] {
            switch self {
            case .detail: [(0.3, 1.0)]
            case .player: [(0.1, 1.0), (0.3, 0.93), (0.6, 0.845)]
            case .emptyPlayer: [(0.5, 1.0)]
            }
        }
    }

    /// 縦グラデーションの両端と基準色。途中の点は帯ごとに数が違うので、基準色から作る（仕様 1.2 章 手順 6）。
    var stops: Stops
    /// 前景を暗くするか。基準色の輝度だけで決まり、場所ごとには変えない（仕様 1.2 章 手順 7）。
    var prefersDarkForeground: Bool

    /// 文字と記号の色。明るいアートワークでは黒へ反転する。**白で固定しない。**
    var foreground: Color { prefersDarkForeground ? .black : .white }
    /// 3 ボタンの中央カプセルの文字色。地が `foreground` なので、その上に乗るのは背景側の色になる（仕様 7 章）。
    var background: Color { Color(stops.middle.uiColor) }
    /// 罫線は背景から**前景の側へ**各成分 30 動かした色。白の半透明を重ねない（仕様 1.2 章）。
    /// 一律に暗くすると、白い文字を載せる暗い地で罫線がほとんど見えなくなる。
    /// 前景と同じ向きへ動かせば、地が明暗どちら側へ振れても同じだけ浮く。
    var separator: Color {
        Color(stops.middle.shifted(by: prefersDarkForeground ? -30.0 / 255 : 30.0 / 255).uiColor)
    }
    /// 左右の円の地。`背景`へ`前景`を約 10% 重ねた面（仕様 7 章）。
    /// 半透明を重ねずに色を合成しておくのは、下のグラデーションの位置で円の濃さが変わらないようにするため。
    var circleFill: Color {
        Color(stops.middle.blended(toward: prefersDarkForeground ? 0 : 1, amount: 0.10).uiColor)
    }
    /// 選択中の歌詞・キューのボタンの記号。円の地が明るいので、その上に乗るのは背景そのものの色になる（仕様 4 章）。
    /// `background` と同じ式だが、`background` は中央カプセル用の名前なので、役割ごとに入口を分ける。
    var selectedModeForeground: Color { background }
    /// 選択中の円の地。背景の各成分へ 0.45 を**足した**色（仕様 4 章）。
    /// 白の半透明を重ねる形ではない。Apple 実測 (187,167,166) から重ねる白の量を逆算すると
    /// R .634 / G .564 / B .562 と 3 成分でそろわず、単一の不透明度では説明が付かない。
    /// 一律に足す形なら (184,168,167) になり、3 成分とも実測と 3 階調以内で一致する。
    var selectedModeFill: Color { Color(stops.middle.shifted(by: 0.45).uiColor) }
    /// 無効なダウンロードの記号。**Apple 実測は左の円と同じ濃さ（100%）**で、40% は
    /// 「Musicfin はダウンロードを持たないので無効を形で示す」というこちら側の決定（仕様 7 章）。
    var disabledForeground: Color { foreground.opacity(0.4) }

    /// アートワークが取れないときの色。定数を別に置かず、帯が持つ色相・彩度を帯の式へ入れて作る。
    /// 詳細は明度 78%（灰 199・前景は黒）、フルプレイヤーは 41%（灰 105・前景は白）になる。
    /// 78% 自体に根拠があるわけではなく、**帯の式の端がそこだから**であって、
    /// 帯を直せば既定色も一緒に動く。数値を別に書くと片方だけ古くなる（仕様 1.2 章 手順 5）。
    static func neutral(band: Band) -> Self {
        make(hue: band.neutralColor.hue, saturation: band.neutralColor.saturation, band: band)
    }
}

// MARK: - グラデーションの 3 点

nonisolated extension ArtworkPalette {
    /// sRGB の 0…1。`VectorArithmetic` にしてあるのは、曲が変わったときに RGB で補間するため。
    /// HSV の色相で補間すると関係のない色を一周する（仕様 1.2 章）。
    struct Components: Equatable, Sendable, VectorArithmetic {
        var red: Double = 0
        var green: Double = 0
        var blue: Double = 0

        var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }

        /// BT.601 の輝度。**sRGB の値をそのまま入れ、線形化しない**（仕様 1.2 章）。
        /// **前景を白と黒のどちらにするかだけ**を決める値で、下の `relativeLuminance` とは別物。
        /// WCAG の相対輝度で計算するとアルバムもプレイリストも同じ側へ落ち、実測の反転を再現できない。
        var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

        /// WCAG の相対輝度。**線形化してから重み付ける**。**文字との比を決めるのはこちら**で、
        /// 上の BT.601 とは係数も線形化の有無も違う。取り違えると白黒の判定が変わる。
        /// 緑 0.7152 と赤 0.2126 で重みが 3 倍以上違うので、HSV の V が同じでも比は色相で大きく変わる。
        var relativeLuminance: Double {
            func linear(_ component: Double) -> Double {
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// 3 成分へ同じ係数を掛ける。HSV の色相と彩度は比で決まるので変わらず、V だけが下がる。
        func scaled(by factor: Double) -> Self {
            Self(red: red * factor, green: green * factor, blue: blue * factor)
        }

        /// 相対輝度が `limit` を超えないところまで暗くする。
        /// 線形化の式に定数項があって係数を解析的に解けないので、単調性を使って 20 回で挟み込む。
        func capped(toRelativeLuminance limit: Double) -> Self {
            guard relativeLuminance > limit else { return self }
            var low = 0.0
            var high = 1.0
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if scaled(by: mid).relativeLuminance > limit { high = mid } else { low = mid }
            }
            return scaled(by: low)
        }

        /// 純白（`target` 1）か純黒（0）へ `amount` だけ寄せる。
        func blended(toward target: Double, amount: Double) -> Self {
            Self(
                red: red * (1 - amount) + target * amount,
                green: green * (1 - amount) + target * amount,
                blue: blue * (1 - amount) + target * amount
            )
        }

        /// 3 成分に同じ量を足す（負なら引く）。色相と彩度の関係を崩さないための形。
        func shifted(by amount: Double) -> Self {
            Self(
                red: min(max(red + amount, 0), 1),
                green: min(max(green + amount, 0), 1),
                blue: min(max(blue + amount, 0), 1)
            )
        }

        static var zero: Self { Self() }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(red: lhs.red + rhs.red, green: lhs.green + rhs.green, blue: lhs.blue + rhs.blue)
        }

        static func - (lhs: Self, rhs: Self) -> Self {
            Self(red: lhs.red - rhs.red, green: lhs.green - rhs.green, blue: lhs.blue - rhs.blue)
        }

        mutating func scale(by rhs: Double) {
            red *= rhs
            green *= rhs
            blue *= rhs
        }

        var magnitudeSquared: Double { red * red + green * green + blue * blue }
    }

    /// 上端・基準・下端の 3 点。前景の判定に使うのは `middle` の 1 つだけ（仕様 1.2 章 手順 7）。
    /// 曲送りの補間はこの 3 点で行い、途中の点は描くときに `middle` から作る。
    /// 途中の点を持たせると帯ごとに要素数が変わり、`VectorArithmetic` の足し引きが組めない。
    struct Stops: Equatable, Sendable, VectorArithmetic {
        var top: Components = .zero
        var middle: Components = .zero
        var bottom: Components = .zero

        static var zero: Self { Self() }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(top: lhs.top + rhs.top, middle: lhs.middle + rhs.middle, bottom: lhs.bottom + rhs.bottom)
        }

        static func - (lhs: Self, rhs: Self) -> Self {
            Self(top: lhs.top - rhs.top, middle: lhs.middle - rhs.middle, bottom: lhs.bottom - rhs.bottom)
        }

        mutating func scale(by rhs: Double) {
            top.scale(by: rhs)
            middle.scale(by: rhs)
            bottom.scale(by: rhs)
        }

        var magnitudeSquared: Double {
            top.magnitudeSquared + middle.magnitudeSquared + bottom.magnitudeSquared
        }
    }
}

// MARK: - 色の取り出し

nonisolated extension ArtworkPalette {
    /// 走査する一辺。原寸を全画素なめない（仕様 1.2 章 手順 1）。
    private static let sampleSide = 32
    /// 捨てる明度の上下。アルバムの最頻色が白になったのは上を捨てなかったため（仕様 1.2 章 手順 2）。
    private static let valueRange = 0.12...0.92
    /// 桶の数。30° ごと（仕様 1.2 章 手順 3）。**彩度を取る塊を選ぶために使い、
    /// 色相が円平均で決まらないときの控えにも使う。**
    private static let hueBucketCount = 12
    /// 円平均の合成長の下限。これを下回ったら色相を最頻桶から取り直す（仕様 1.2 章 手順 4）。
    /// 合成長は「向きがどれだけ 1 方向に集まっているか」で、補色が同量あると 0 に近づく。
    /// 実測では健全なジャケットが 0.43〜0.49、暖色と寒色がほぼ同量の
    /// 「Shangri-La Shower」が **0.016** で、間が広いので 0.10 に置く。
    private static let minimumResultantLength = 0.10

    /// アートワークから配色を作る。**呼び出し元の actor では走らせない。**
    /// `nonisolated` だけだと `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` の下で MainActor に残り、
    /// 32×32 とはいえ描画と走査で画面を止める。境界を越えるのは `Sendable` な `CGImage` と数値だけ。
    @concurrent nonisolated static func extract(from image: CGImage, band: Band) async -> Self {
        guard let pixels = downsample(image) else { return neutral(band: band) }

        // 彩度は桶ごとに `彩度 × 明度` の合計を取り、重みの最大の桶の平均を使う。
        // 色相だけは桶を使わない。**桶の境目が 0°/360° に来るため、赤〜ローズのように
        // 継ぎ目をまたぐ塊が桶 0 と桶 330 に割れ、わずかな差で勝者が反転して答えが 30° 跳ぶ。**
        // 代わりに画像全体を単位ベクトルの和として畳み、`atan2` で円平均を取る（継ぎ目が無い）。
        var weights = [Double](repeating: 0, count: hueBucketCount)
        var saturations = [Double](repeating: 0, count: hueBucketCount)
        var hues = [Double](repeating: 0, count: hueBucketCount)
        var counts = [Int](repeating: 0, count: hueBucketCount)
        var hueX = 0.0
        var hueY = 0.0

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            // 透明な画素は捨てる。ここで黒を合成すると、余白の多いジャケットが黒を代表色にしてしまう。
            guard alpha > 0.01 else { continue }
            // premultiplied を戻してから HSV へ。戻さないと半透明部が実際より暗く見える。
            let red = Double(pixels[offset]) / 255 / alpha
            let green = Double(pixels[offset + 1]) / 255 / alpha
            let blue = Double(pixels[offset + 2]) / 255 / alpha
            let hsv = hsv(red: min(red, 1), green: min(green, 1), blue: min(blue, 1))
            guard valueRange.contains(hsv.value) else { continue }

            let bucket = min(Int(hsv.hue / 360 * Double(hueBucketCount)), hueBucketCount - 1)
            let chroma = hsv.saturation * hsv.value
            weights[bucket] += chroma
            saturations[bucket] += hsv.saturation
            hues[bucket] += hsv.hue
            counts[bucket] += 1

            // 重みは彩度と明度の積。灰色の画素は長さ 0 のベクトルになり、色相を持たない画素が
            // 向きを引っ張らない。
            let radians = hsv.hue * .pi / 180
            hueX += cos(radians) * chroma
            hueY += sin(radians) * chroma
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), counts[best] > 0 else {
            // 全画素を捨てたとき。白黒だけのジャケットはここへ来るので、無彩色の既定色で塗る。
            return neutral(band: band)
        }

        let count = Double(counts[best])
        // 色が付いた画素が無ければ向きも決まらない。灰色だけのジャケットは無彩色の既定色で塗る。
        let totalChroma = weights.reduce(0, +)
        guard totalChroma > 0 else { return neutral(band: band) }

        // 円平均は向きが打ち消し合うと答えを失う。**補色が同量あるジャケットでは合成長が 0 に近づき、
        // 残った誤差の向きが色相を決めてしまう**（水色と肌色が同量の一例は 0.016 で、
        // 緑を返して地と合わなかった）。集まっていないと分かったときは、彩度を取るのに選んだ
        // 最頻桶の平均へ戻す。桶なら継ぎ目で割れる代わりに、少なくとも実在する塊の色になる。
        let resultantLength = (hueX * hueX + hueY * hueY).squareRoot() / totalChroma
        let hue =
            resultantLength < minimumResultantLength
            ? hues[best] / count
            : (atan2(hueY, hueX) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return make(hue: hue, saturation: saturations[best] / count, band: band)
    }

    /// 白い文字を載せる地の相対輝度の上限。Apple のアルバム詳細の実測 0.238 に合わせた（仕様 1.2 章）。
    private static let maximumRelativeLuminance = 0.24

    /// 白い文字を載せる地にだけ上限を掛ける。**帯の式そのものは直さず、後から抑えるだけ**。
    /// 黒い文字のときは地が明るいほど読めるので触らない（Apple 実測 0.443 で 9.86 対 1）。
    /// フルプレイヤーの暗い帯も実測 0.071〜0.096 でもともと 7 対 1 以上あるため、
    /// 上限に掛からないことを当てにせず、掛けない側へ明示的に分ける。
    private static func limited(_ base: Components, band: Band, prefersDarkForeground: Bool) -> Components {
        switch band {
        case .detail where !prefersDarkForeground:
            base.capped(toRelativeLuminance: maximumRelativeLuminance)
        case .detail, .player, .emptyPlayer:
            base
        }
    }

    /// 取り出した色相・彩度を帯へ正規化し、グラデーションと前景を決める（仕様 1.2 章 手順 5〜7）。
    private static func make(hue: Double, saturation: Double, band: Band) -> Self {
        let saturation = min(saturation, band.maximumSaturation)
        let value = band.value(forSaturation: saturation)
        let base = components(hue: hue, saturation: saturation, value: value)
        // 判定するのは基準色 1 つだけ。場所ごとに文字色を切り替えると、同じ画面で白黒が混ざる。
        // **暗くする前に決める。**暗くしても BT.601 は下がるだけなので、あとから白黒が覆ることはない。
        let prefersDarkForeground = base.luminance >= 0.6
        let middle = limited(base, band: band, prefersDarkForeground: prefersDarkForeground)
        return Self(
            stops: Stops(
                // 両端の比は帯から引く。詳細は実測のアルバム詳細 162→172→153、
                // フルプレイヤーは Apple 実測の 0.99→…→0.475 に合わせた比。横方向は一定でよい。
                // 上限で基準色を暗くした場合も、同じ比のまま 3 点そろって下がる。
                top: middle.scaled(by: band.topScale),
                middle: middle,
                bottom: middle.scaled(by: band.bottomScale)
            ),
            prefersDarkForeground: prefersDarkForeground
        )
    }

    /// `CGImage` を 32×32 の sRGB へ描き直して画素を取り出す。
    /// `ImageIO` で読み直さないのは、`ArtworkLoader` が `UIImage` しか持たず元データを返さないため。
    private nonisolated static func downsample(_ image: CGImage) -> [UInt8]? {
        let side = sampleSide
        let bytesPerRow = side * 4
        guard
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        // 切り抜かず全体を描く。正方形でないジャケットは縦横比が崩れるが、代表色は変わらない。
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * side)
        return Array(UnsafeBufferPointer(start: buffer, count: bytesPerRow * side))
    }

    private nonisolated static func hsv(red: Double, green: Double, blue: Double) -> (
        hue: Double, saturation: Double, value: Double
    ) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0, maximum > 0 else { return (0, 0, maximum) }

        let hue: Double
        switch maximum {
        case red: hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = 60 * ((blue - red) / delta + 2)
        default: hue = 60 * ((red - green) / delta + 4)
        }
        return (hue < 0 ? hue + 360 : hue, delta / maximum, maximum)
    }

    private nonisolated static func components(hue: Double, saturation: Double, value: Double) -> Components {
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = value * saturation
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = value - chroma
        let (red, green, blue): (Double, Double, Double) =
            switch Int(sector) {
            case 0: (chroma, secondary, 0)
            case 1: (secondary, chroma, 0)
            case 2: (0, chroma, secondary)
            case 3: (0, secondary, chroma)
            case 4: (secondary, 0, chroma)
            default: (chroma, 0, secondary)
            }
        return Components(red: red + base, green: green + base, blue: blue + base)
    }
}

// MARK: - 画面へ敷く

/// アートワーク由来の背景を全画面へ敷き、決まった配色を中身へ渡す（仕様 1.2 章）。
/// 詳細 2 画面とフルプレイヤーで帯だけが違うので、`band` を外から選ばせて 1 つの型で両方を賄う。
struct ArtworkBackdrop<Content: View>: View {
    let item: MediaItem?
    let band: ArtworkPalette.Band
    /// 画面に出している画像と同じ寸法を渡す。`ArtworkLoader` のキャッシュを共有して余計な取得を避ける。
    var artworkSize: CGFloat
    @ViewBuilder let content: (ArtworkPalette) -> Content

    @Environment(AuthStore.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette: ArtworkPalette

    init(
        item: MediaItem?,
        band: ArtworkPalette.Band,
        artworkSize: CGFloat,
        @ViewBuilder content: @escaping (ArtworkPalette) -> Content
    ) {
        self.item = item
        self.band = band
        self.artworkSize = artworkSize
        self.content = content
        // 結果が届くまでは無彩色の既定色で待つ。透明にすると下の黒が透けて、後から色が飛び込む。
        _palette = State(initialValue: .neutral(band: band))
    }

    var body: some View {
        content(palette)
            .modifier(ArtworkBackgroundModifier(stops: palette.stops, band: band))
            // 同じ作品のまま画面の状態だけが変わったときは取り出し直さない（仕様 1.2 章）。
            .task(id: item?.id) { await load() }
    }

    private func load() async {
        guard let item, let client = auth.client,
            let url = client.artworkURL(for: item, maxSize: Int(artworkSize)),
            let image = await ArtworkLoader.shared.image(for: url)?.cgImage
        else { return }

        let extracted = await ArtworkPalette.extract(from: image, band: band)
        // await の間に別の作品へ移っていることがあるので、突き合わせてから反映する（仕様 1.2 章）。
        guard !Task.isCancelled, item.id == self.item?.id else { return }
        // 前景が反転するときは背景も動かさず、両方まとめて差し替える。
        // 文字色だけ先に白へ返すと、まだ明るいままの背景の上に白い文字が 0.35 秒乗って読めなくなる。
        // 前景が変わらないとき（同系色の曲送りなど）だけ、背景を 0.35 秒かけて送る。
        let inverts = extracted.prefersDarkForeground != palette.prefersDarkForeground
        if reduceMotion || inverts {
            palette = extracted
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { palette.stops = extracted.stops }
        }
    }
}

/// 背景の 3 点を `animatableData` に載せる。`LinearGradient` は値を差し替えても補間されないので、
/// 補間を modifier 側に持たせて毎フレーム作り直す（仕様 1.2 章）。
/// safe area を無視するのは背景だけで、本文には及ぼさない。タブバーは塗らず、下の色を Liquid Glass に拾わせる。
private struct ArtworkBackgroundModifier: ViewModifier, Animatable {
    var stops: ArtworkPalette.Stops
    /// 停止点の数と位置は帯で違うので、形そのものを帯から引く（仕様 1.2 章）。
    /// 補間に載るのは `stops` の 3 点だけなので、`animatableData` には入れない。
    let band: ArtworkPalette.Band

    var animatableData: ArtworkPalette.Stops {
        get { stops }
        set { stops = newValue }
    }

    func body(content: Content) -> some View {
        content.background(
            LinearGradient(stops: gradientStops, startPoint: .top, endPoint: .bottom),
            ignoresSafeAreaEdges: .all
        )
    }

    /// 両端は補間済みの `top` / `bottom` をそのまま使い、途中の点だけ基準色から作る。
    /// こうすると曲送りの補間で 3 点が動いたとき、途中の点も同じ比のまま付いて動く。
    private var gradientStops: [Gradient.Stop] {
        [Gradient.Stop(color: Color(stops.top.uiColor), location: 0)]
            + band.innerStops.map { inner in
                Gradient.Stop(
                    color: Color(stops.middle.scaled(by: inner.scale).uiColor), location: inner.location
                )
            }
            + [Gradient.Stop(color: Color(stops.bottom.uiColor), location: 1)]
    }
}
