#!/usr/bin/env python3
"""参照と実装を「枠線の位置」だけで比べる。

mock-diff ビューアの数字は生のピクセル差なので、Jellyfin と Apple Music で
ライブラリの中身が違う以上アートワークだけで何十 % も動いてしまい、肝心の
レイアウトのズレが埋もれる。

骨格を画素として重ねる比べ方も、行数やカード枚数そのものが違えば大きく外れる。
そこで画素ではなく「線の座標」を見る。Sobel で軸ごとの輪郭を出し、行／列ごとの
占有率を取ると、区切り線・ナビバー・サイドバー境界・カード外形は軸長の過半を
占める鋭い山になり、ジャケット内部の線は 1 枚分の幅しか無いので届かない。
残った山の座標を参照と実装で突き合わせ、相手の見つからない線の割合を返す。

分母を参照側の線に取るのは、実装の方が行数が多い分には枠がズレた訳ではない一方、
参照にある線が実装に無ければ配置か寸法が違うため。

PIL しか無い環境で回すため、方向つきの収縮・膨張はシフトと min/max 合成の
倍々ループで組んである。行／列の合計は BOX 縮小が箱平均であることを使う。
"""

import argparse
import json
import pathlib
import sys

from PIL import Image, ImageChops, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parents[1] / "docs" / "mock-diff"

# Sobel。PIL の Kernel は負値を切り捨てるので、符号を反転した対を取って絶対値にする。
SOBEL_Y = (-1, -2, -1, 0, 0, 0, 1, 2, 1)
SOBEL_X = (-1, 0, 1, -2, 0, 2, -1, 0, 1)

# device px を pt に戻して読むための倍率。撮影側の viewport と揃っている。
SCALE = {"iPhone": 3, "iPad": 2}


def shift(im: Image.Image, dx: int, dy: int) -> Image.Image:
    """ゼロ埋めの平行移動。ImageChops.offset と違い端を巻き込まない。"""
    out = Image.new("L", im.size, 0)
    out.paste(im, (dx, dy))
    return out


def _axis_delta(axis: str, d: int) -> tuple:
    return (d, 0) if axis == "h" else (0, d)


def _sweep(im: Image.Image, length: int, axis: str, sign: int, combine) -> Image.Image:
    """長さ length の線分を構造要素にした収縮／膨張。倍々で O(log length) 回に畳む。"""
    out = im
    done = 1
    while done < length:
        d = min(done, length - done)
        out = combine(out, shift(out, *_axis_delta(axis, sign * d)))
        done += d
    return out


def opening(im: Image.Image, length: int, axis: str) -> Image.Image:
    """軸方向に length 以上続く画素だけを残す。"""
    eroded = _sweep(im, length, axis, -1, ImageChops.darker)
    return _sweep(eroded, length, axis, 1, ImageChops.lighter)


def directional_edges(gray: Image.Image, kernel, threshold: int) -> Image.Image:
    positive = gray.filter(ImageFilter.Kernel((3, 3), kernel, scale=1, offset=0))
    negative = gray.filter(ImageFilter.Kernel((3, 3), tuple(-k for k in kernel), scale=1, offset=0))
    magnitude = ImageChops.lighter(positive, negative)
    return magnitude.point(lambda v: 255 if v >= threshold else 0)


def edge_maps(path: pathlib.Path, threshold: int, run: int) -> tuple:
    """横線だけ／縦線だけを残した二値画像の対を返す。横線は縦方向の勾配から出る。"""
    gray = Image.open(path).convert("L")
    horizontal = opening(directional_edges(gray, SOBEL_Y, threshold), run, "h")
    vertical = opening(directional_edges(gray, SOBEL_X, threshold), run, "v")
    return horizontal, vertical


def profile(im: Image.Image, axis: str) -> list:
    """行ごと（h）／列ごと（v）の画素数。BOX 縮小は箱平均なので 1 px 幅に潰せば合計になる。"""
    width, height = im.size
    if axis == "h":
        band = im.resize((1, height), Image.BOX)
        return [band.getpixel((0, y)) * width / 255.0 for y in range(height)]
    band = im.resize((width, 1), Image.BOX)
    return [band.getpixel((x, 0)) * height / 255.0 for x in range(width)]


def peaks(prof: list, span: int, coverage: float, gap: int) -> list:
    """占有率が coverage を超える帯を 1 本の線とみなし、その中心座標を返す。"""
    need = span * coverage
    hot = [i for i, v in enumerate(prof) if v >= need]
    if not hot:
        return []
    found, start, previous = [], hot[0], hot[0]
    for i in hot[1:]:
        # 線の縁は数 px にじむうえ 1 px 途切れることもあるので、近いものは 1 本に束ねる。
        if i - previous > gap:
            found.append((start + previous) // 2)
            start = i
        previous = i
    found.append((start + previous) // 2)
    return found


def matched_count(ref: list, act: list, delta: int, tolerance: int) -> int:
    """実装を delta ずらしたとき、許容内の相手が見つかる参照線の本数。"""
    return sum(any(abs(a + delta - r) <= tolerance for a in act) for r in ref)


def best_shift(ref: list, act: list, span: int, tolerance: int) -> tuple:
    """本数が最も多く合う平行移動。線は高々数十本なので総当たりで足りる。"""
    if not ref or not act:
        return 0, 0
    # 同点なら動かさない方を採る。見かけ上合うだけの大きなシフトを選ばせない。
    return max(
        ((matched_count(ref, act, d, tolerance), -abs(d), d) for d in range(-span, span + 1)),
        key=lambda t: (t[0], t[1]),
    )[::2]


def compare(
    reference: pathlib.Path,
    actual: pathlib.Path,
    threshold: int,
    run: int,
    coverage: float,
    tolerance: int,
    gap: int,
    span: int,
    align: bool = True,
) -> tuple:
    ref_h, ref_v = edge_maps(reference, threshold, run)
    act_h, act_v = edge_maps(actual, threshold, run)
    if ref_h.size != act_h.size:
        raise SystemExit(f"サイズが違う: {reference} {ref_h.size} vs {actual} {act_h.size}")
    width, height = ref_h.size

    rows = (peaks(profile(ref_h, "h"), width, coverage, gap),
            peaks(profile(act_h, "h"), width, coverage, gap))
    columns = (peaks(profile(ref_v, "v"), height, coverage, gap),
               peaks(profile(act_v, "v"), height, coverage, gap))

    matched_y, dy = best_shift(*rows, span, tolerance) if align else (
        matched_count(*rows, 0, tolerance), 0)
    matched_x, dx = best_shift(*columns, span, tolerance) if align else (
        matched_count(*columns, 0, tolerance), 0)

    total = len(rows[0]) + len(columns[0])
    off = [r for r in rows[0] if not any(abs(a + dy - r) <= tolerance for a in rows[1])]
    detail = {
        "offsetX": dx,
        "offsetY": dy,
        "strayPercent": round(100.0 * (total - matched_y - matched_x) / total, 2) if total else 0.0,
        "rowsReference": len(rows[0]),
        "rowsActual": len(rows[1]),
        "rowsMatched": matched_y,
        "columnsReference": len(columns[0]),
        "columnsActual": len(columns[1]),
        "columnsMatched": matched_x,
        "strayRows": off,
    }
    return detail, (ref_h, ref_v, act_h, act_v), (rows, columns)


def overlay(maps, dx: int, dy: int) -> Image.Image:
    """合った線を暗いグレー、参照にしか無い線を赤、実装にしか無い線を青で重ねる。"""
    ref_h, ref_v, act_h, act_v = maps
    base = ImageChops.lighter(ref_h, ref_v).point(lambda v: v // 5)
    moved = ImageChops.lighter(shift(act_h, 0, dy), shift(act_v, dx, 0)).point(lambda v: v // 5)
    matched = ImageChops.darker(base, moved)
    return Image.merge("RGB", (ImageChops.subtract(base, moved).point(lambda v: v * 5),
                               matched.point(lambda v: v * 3),
                               ImageChops.subtract(moved, base).point(lambda v: v * 5)))


def discover() -> list:
    found = []
    for actual in sorted((ROOT / "actual").glob("*/*.png")):
        device, screen = actual.parent.name, actual.stem
        reference = ROOT / "designs" / device / actual.name
        if reference.exists():
            found.append((screen, device, reference, actual))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--threshold", type=int, default=48, help="Sobel の二値化しきい値")
    parser.add_argument("--run", type=int, default=32, help="線とみなす最短長 (device px)")
    parser.add_argument("--coverage", type=float, default=0.5, help="枠線とみなす軸方向の占有率")
    parser.add_argument("--tolerance", type=int, default=4, help="一致とみなすズレ幅 (device px)")
    parser.add_argument("--gap", type=int, default=6, help="この間隔までは 1 本の線に束ねる")
    parser.add_argument("--span", type=int, default=60, help="平行移動を探す幅 (device px)")
    parser.add_argument("--max-diff-percent", type=float, default=10.0)
    parser.add_argument("--screen", help="1 画面だけ測る")
    parser.add_argument("--overlay-dir", type=pathlib.Path, help="不一致の可視化を書き出す先")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--no-align",
        dest="align",
        action="store_false",
        help="平行移動の当てはめをせず、置かれたままの位置で測る",
    )
    args = parser.parse_args()

    targets = [t for t in discover() if args.screen in (None, t[0])]
    if not targets:
        print("対象が無い", file=sys.stderr)
        return 2
    if args.overlay_dir:
        args.overlay_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for screen, device, reference, actual in targets:
        detail, maps, _ = compare(
            reference, actual, args.threshold, args.run, args.coverage,
            args.tolerance, args.gap, args.span, align=args.align,
        )
        if args.overlay_dir:
            overlay(maps, detail["offsetX"], detail["offsetY"]).save(
                args.overlay_dir / f"{screen}-{device}.png"
            )
        scale = SCALE[device]
        results.append({
            "screen": screen,
            "device": device,
            "offsetXpt": round(detail["offsetX"] / scale, 2),
            "offsetYpt": round(detail["offsetY"] / scale, 2),
            "strayRowsPt": [round(y / scale, 1) for y in detail["strayRows"]],
            **detail,
        })

    # 線が 1 本ズレただけで 1/total だけ動く。その刻みが合否の線より粗い画面は、
    # 0.00% と出ても「合っている」ではなく「その精度では測れていない」でしかない。
    least = 100.0 / args.max_diff_percent if args.max_diff_percent > 0 else float("inf")
    for r in results:
        r["measurable"] = r["rowsReference"] + r["columnsReference"] >= least

    results.sort(key=lambda r: (r["measurable"], -r["strayPercent"]))
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0

    print(f"{'stray':>8}  {'rows':>9} {'cols':>9}  {'shift(pt)':>11}  screen (device)")
    for r in results:
        if not r["measurable"]:
            mark = "?? "
        else:
            mark = "ok " if r["strayPercent"] <= args.max_diff_percent else "NG "
        rows = f"{r['rowsMatched']}/{r['rowsReference']}"
        columns = f"{r['columnsMatched']}/{r['columnsReference']}"
        offset = f"{r['offsetXpt']:+.1f},{r['offsetYpt']:+.1f}"
        print(
            f"{mark}{r['strayPercent']:6.2f}%  {rows:>9} {columns:>9}  {offset:>11}"
            f"  {r['screen']} ({r['device']})"
        )
    passed = [r for r in results if r["measurable"] and r["strayPercent"] <= args.max_diff_percent]
    unmeasured = [r for r in results if not r["measurable"]]
    print(f"\n{len(passed)}/{len(results)} screens within {args.max_diff_percent}%"
          f" / {len(unmeasured)} 未測定")
    print("stray=相手の見つからない枠線の割合 / rows,cols=一致した本数/参照の本数"
          " / shift=実装をどれだけ動かすと合うか")
    print(f"??=参照線が {least:.0f} 本未満で、刻みが {args.max_diff_percent}% より粗く合否を出せない")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
