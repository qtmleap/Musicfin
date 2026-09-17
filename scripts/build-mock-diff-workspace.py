#!/usr/bin/env python3
"""docs/app のストーリーカタログから mock-diff ワークスペースを組み直す。

    ./scripts/build-mock-diff-workspace.py            # 両端末
    ./scripts/build-mock-diff-workspace.py --device iPad

参照 (Apple Music の実機撮影) は docs/app/ の webp、実装は撮影スクリプトが出した
docs/screenshots/**/current/ の PNG。どちらも docs/mock-diff/ に PNG で書き出す。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "docs" / "app" / "catalog.json"
REFERENCES = ROOT / "docs" / "app"
WORKSPACE = ROOT / "docs" / "mock-diff"

# 候補は Apple Music の 1 つだけなので、version の名前も 1 つで固定できる。
VERSION = "apple-music"

# mock-diff は type: png のソースで viewport を読まない (comparator.ts の captureSource は
# readFile するだけ) ので、ここの数値は人が構成を読むための注記でしかない。viewport は
# 端末を立てたときの寸法で書く決まりで、landscape は表示側が幅と高さを入れ替える。
DEVICES = {
    "iPhone": {
        "pixel_size": (1179, 2556),
        "viewport": (393, 852),
        "scale": 3,
        "orientations": None,
        "captures": ROOT / "docs" / "screenshots" / "current",
    },
    "iPad": {
        "pixel_size": (2732, 2048),
        "viewport": (1024, 1366),
        "scale": 2,
        "orientations": ["landscape"],
        "captures": ROOT / "docs" / "screenshots" / "ipad-report" / "current",
    },
}

# mock-diff にマスク機能が無いので、ステータスバーは渡す前に両側へ焼き込む。時計と
# 電池は撮るたびに変わるが UI の差ではないため、消さないと毎回そこだけが差分に出る。
MASK_COLOR = (0, 0, 0)
# マスクが画面の広い範囲を覆う事故を検出するための安全弁。旧 compare-ipad-screens.py の
# MASK_LIMIT と同じ値で、超えたら警告するだけにして生成は止めない。
MASK_AREA_LIMIT = 0.25


def burn(source: Path, target: Path, masks: list[dict], pixel_size: tuple[int, int]) -> None:
    """マスクを焼き込んだ PNG を書き出す。寸法が違うものは呼び出し側で弾く。"""
    with Image.open(source) as image:
        canvas = image.convert("RGB")
    width, height = canvas.size
    if (width, height) != pixel_size:
        raise ValueError(f"{pixel_size[0]}x{pixel_size[1]} ではない: {width}x{height}")
    draw = ImageDraw.Draw(canvas)
    for mask in masks:
        x0, y0, x1, y1 = mask["rect"]
        draw.rectangle(
            (round(x0 * width), round(y0 * height), round(x1 * width), round(y1 * height)),
            fill=MASK_COLOR,
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(target, format="PNG")


def mask_area_ratio(masks: list[dict]) -> float:
    """重なりを無視した概算。安全弁の用途には十分で、過小評価はしない。"""
    return sum((x1 - x0) * (y1 - y0) for x0, y0, x1, y1 in (mask["rect"] for mask in masks))


def quote(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_config(screens: list[dict]) -> str:
    lines = [
        "# docs/app/catalog.json から scripts/build-mock-diff-workspace.py が生成する。",
        "# 直接編集しても次の撮影で上書きされる。",
        "#",
        "# 候補は Apple Music の実機撮影 1 つだけなので、選定フェーズは実質的に済んでいて、",
        "# 使うのは「選ばれた設計と実装を突き合わせる」3 番目のフェーズだけ。",
        "# ステータスバーは両側とも生成時に黒で塗り潰してある。",
        "screens:",
    ]
    for screen in screens:
        lines.append(f"  - id: {screen['id']}")
        lines.append(f"    name: {quote(screen['name'])}")
        lines.append(f"    category: {quote(screen['category'])}")
        lines.append("    devices:")
        for device in screen["devices"]:
            spec = DEVICES[device["id"]]
            lines.append(f"      - id: {device['id']}")
            lines.append(f"        name: {device['id']}")
            lines.append("        viewport:")
            lines.append(f"          width: {spec['viewport'][0]}")
            lines.append(f"          height: {spec['viewport'][1]}")
            lines.append(f"          deviceScaleFactor: {spec['scale']}")
            if spec["orientations"]:
                lines.append(f"        orientations: [{', '.join(spec['orientations'])}]")
            lines.append("        versions:")
            lines.append(f"          {VERSION}:")
            lines.append("            type: png")
            lines.append(f"            path: {device['design']}")
            if device.get("actual"):
                lines.append("        actual:")
                lines.append("          type: png")
                lines.append(f"          path: {device['actual']}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_adopted(screens: list[dict]) -> str:
    lines = [
        "# 候補が 1 つしかないので、選定は生成時に確定させる。ビューアで選び直すと",
        "# ビューアがこのファイルを書き戻す。",
        "adopted:",
    ]
    lines.extend(f"  {screen['id']}: {VERSION}" for screen in screens)
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--device",
        action="append",
        choices=sorted(DEVICES),
        help="実装側を撮り直す端末。省略すると両方。",
    )
    args = parser.parse_args()
    refresh = set(args.device or DEVICES)

    catalog = json.loads(CATALOG.read_text())
    masks = catalog["defaults"]["masks"]
    for device, entries in masks.items():
        ratio = mask_area_ratio(entries)
        if ratio > MASK_AREA_LIMIT:
            print(
                f"!! {device}: マスクが画面の {ratio:.0%} を覆っている "
                f"(上限 {MASK_AREA_LIMIT:.0%})。catalog.json の rect を確認すること",
                file=sys.stderr,
            )

    screens: list[dict] = []
    problems = 0
    for story in catalog["stories"]:
        devices = []
        for device in sorted(story["devices"]):
            spec = DEVICES[device]
            entry = story["devices"][device]
            design = Path("designs") / device / f"{story['id']}.png"
            actual = Path("actual") / device / f"{story['id']}.png"

            try:
                burn(
                    REFERENCES / entry["reference"],
                    WORKSPACE / design,
                    masks[device],
                    spec["pixel_size"],
                )
            except (OSError, ValueError) as error:
                print(f"!! {story['id']} / {device} の参照を使えない: {error}", file=sys.stderr)
                problems += 1
                continue

            capture = entry.get("capture")
            if capture and device in refresh:
                source = spec["captures"] / f"{capture}.png"
                if not source.exists():
                    print(f"-- {story['id']} / {device}: 撮影が無い ({source})", file=sys.stderr)
                else:
                    try:
                        burn(source, WORKSPACE / actual, masks[device], spec["pixel_size"])
                    except (OSError, ValueError) as error:
                        print(
                            f"!! {story['id']} / {device} の実装を使えない: {error}",
                            file=sys.stderr,
                        )
                        problems += 1

            devices.append(
                {
                    "id": device,
                    "design": design.as_posix(),
                    # capture が無い story は参照だけを並べる。撮り直していない端末でも
                    # 前の世代が残っていれば拾うので、構成は常に在るものを指す。
                    "actual": actual.as_posix() if (WORKSPACE / actual).exists() else None,
                }
            )
        if devices:
            screens.append(
                {
                    "id": story["id"],
                    "name": story["title"],
                    "category": story["category"],
                    "devices": devices,
                }
            )

    WORKSPACE.mkdir(parents=True, exist_ok=True)
    (WORKSPACE / "mock-diff.yaml").write_text(render_config(screens))
    adopted = WORKSPACE / "mock-diff.adopted.yaml"
    # ビューアが書き戻す側なので、一度作られていれば選定を踏み潰さない。
    if not adopted.exists():
        adopted.write_text(render_adopted(screens))

    built = sum(1 for screen in screens for device in screen["devices"] if device["actual"])
    targets = sum(len(screen["devices"]) for screen in screens)
    print(f"{len(screens)} screens / {targets} targets, {built} of them with an implementation")
    if problems:
        raise SystemExit(f"{problems} 件を書き出せなかった")


if __name__ == "__main__":
    main()
