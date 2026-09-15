#!/usr/bin/env python3
"""iPad reference と current を同寸法のまま比較し、独立した report を生成する。"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "docs" / "app" / "iPad"
REPORT = ROOT / "docs" / "screenshots" / "ipad-report"
PIXEL_SIZE = (2732, 2048)
DELTA_THRESHOLD = 8
MASK_LIMIT = 0.25
SCREEN_CONFIG = {
    "search-artist": {
        "mismatchRatio": 0.18,
        "masks": [
            {"kind": "dynamicArtwork", "rect": [0.23, 0.16, 0.70, 0.51]},
            {"kind": "dynamicText", "rect": [0.23, 0.07, 0.42, 0.14]},
        ],
    },
    "playing": {
        "mismatchRatio": 0.12,
        "masks": [
            {"kind": "dynamicArtwork", "rect": [0.32, 0.12, 0.68, 0.60]},
            {"kind": "dynamicText", "rect": [0.34, 0.61, 0.66, 0.68]},
            {"kind": "playbackProgress", "rect": [0.31, 0.69, 0.69, 0.75]},
        ],
    },
    "account": {
        "mismatchRatio": 0.10,
        "masks": [{"kind": "accountDynamicContent", "rect": [0.32, 0.18, 0.68, 0.39]}],
    },
    "search-artist-bottom": {
        "mismatchRatio": 0.18,
        "masks": [
            {"kind": "dynamicArtwork", "rect": [0.23, 0.08, 0.98, 0.25]},
            {"kind": "dynamicText", "rect": [0.23, 0.25, 0.98, 0.32]},
        ],
    },
    "search-album-detail": {
        "mismatchRatio": 0.16,
        "masks": [
            {"kind": "dynamicArtwork", "rect": [0.24, 0.10, 0.43, 0.36]},
            {"kind": "dynamicText", "rect": [0.44, 0.12, 0.78, 0.34]},
        ],
    },
}


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def dimensions(path: Path) -> tuple[int, int]:
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        check=True,
        text=True,
        capture_output=True,
    ).stdout
    values = [int(line.split(":", 1)[1]) for line in result.splitlines() if "pixel" in line]
    return values[0], values[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(source: Path, target: Path) -> None:
    if dimensions(source) != PIXEL_SIZE:
        raise SystemExit(f"2732x2048 ではありません: {source} ({dimensions(source)})")
    target.parent.mkdir(parents=True, exist_ok=True)
    run(
        "ffmpeg", "-loglevel", "error", "-y", "-i", str(source),
        "-vf", "colorspace=all=bt709:iall=bt709:fast=1,format=rgb24",
        "-frames:v", "1", str(target),
    )
    if dimensions(target) != PIXEL_SIZE:
        raise SystemExit(f"正規化で寸法が変わりました: {target}")


def render(reference: Path, current: Path, target: Path, filter_graph: str) -> None:
    run(
        "ffmpeg", "-loglevel", "error", "-y", "-i", str(reference), "-i", str(current),
        "-filter_complex", filter_graph, "-map", "[out]", "-frames:v", "1", str(target),
    )


def metrics_and_masked_difference(
    reference: Path, current: Path, masks: list[dict], target: Path
) -> dict[str, float]:
    script = f"""
import cv2, json, numpy as np
r=cv2.imread({str(reference)!r}, cv2.IMREAD_COLOR).astype(np.int16)
c=cv2.imread({str(current)!r}, cv2.IMREAD_COLOR).astype(np.int16)
h,w=r.shape[:2]
valid=np.ones((h,w),dtype=bool)
for item in {masks!r}:
 x0,y0,x1,y1=item['rect']
 valid[round(y0*h):round(y1*h),round(x0*w):round(x1*w)]=False
d=np.abs(r-c)
raw=np.any(d>{DELTA_THRESHOLD},axis=2)
visual=np.minimum(d*4,255).astype(np.uint8)
visual[~valid]=0
cv2.imwrite({str(target)!r},visual)
print(json.dumps({{
 'rawMismatchRatio':float(raw.mean()),
 'rawRGBMAE':float(d.mean()/255),
 'mismatchRatio':float(raw[valid].mean()),
 'rgbMAE':float(d[valid].mean()/255),
 'maskAreaRatio':float((~valid).mean()),
}}))
"""
    output = subprocess.run(["python3", "-c", script], check=True, text=True, capture_output=True).stdout
    return json.loads(output)


def write_viewer(screens: list[dict], generated_at: str) -> None:
    cards = "".join(
        f'''<section><h2>{s["id"]}</h2><p>mismatch {s["metrics"]["mismatchRatio"]:.4%} · RGB MAE {s["metrics"]["rgbMAE"]:.5f} · {"PASS" if s["pass"] else "FAIL"}</p><img data-screen="{s["id"]}" src="{s["id"]}/current.png"></section>'''
        for s in screens
    )
    REPORT.joinpath("visual-report.html").write_text(f'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>iPad Visual Report</title><style>:root{{color-scheme:dark;font:14px system-ui;background:#111;color:#eee}}body{{margin:24px}}nav{{display:flex;gap:8px;position:sticky;top:0;background:#111;padding:12px 0}}button{{padding:8px 12px}}main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:24px}}img{{width:100%;border:1px solid #555}}p{{color:#aaa}}</style><h1>iPad Visual Report</h1><p>{generated_at}</p><nav><button data-mode="reference">Reference</button><button data-mode="current">Current</button><button data-mode="overlay">Overlay</button><button data-mode="difference">Difference</button><button data-mode="masked-difference">Masked difference</button></nav><main>{cards}</main><script>document.querySelectorAll('button').forEach(b=>b.onclick=()=>document.querySelectorAll('img').forEach(i=>i.src=i.dataset.screen+'/'+b.dataset.mode+'.png'))</script>''')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", type=Path, required=True)
    args = parser.parse_args()
    mapping = {
        "search-artist": "artist-detail-togenashi-top-search-context.png",
        "playing": "now-playing-not-playing.png",
        "account": "music-account-sheet.png",
        "search-artist-bottom": "artist-detail-togenashi-bottom-search-context.png",
        "search-album-detail": "album-detail-ill-live-with-my-heart-on-my-sleeve-search-context.png",
    }
    REPORT.mkdir(parents=True, exist_ok=True)
    screens = []
    for screen, filename in mapping.items():
        source = args.current / f"{screen}.png"
        if not source.exists():
            raise SystemExit(f"current がありません: {source}")
        target = REPORT / screen
        reference = target / "reference.png"
        current = target / "current.png"
        normalize(REFERENCE / filename, reference)
        normalize(source, current)
        render(reference, current, target / "overlay.png", "[0:v][1:v]blend=all_expr='A*.5+B*.5'[out]")
        render(reference, current, target / "difference.png", "[0:v][1:v]blend=all_mode=difference,eq=contrast=4[out]")
        config = SCREEN_CONFIG[screen]
        metrics = metrics_and_masked_difference(
            reference, current, config["masks"], target / "masked-difference.png"
        )
        mask_ok = metrics["maskAreaRatio"] <= MASK_LIMIT
        screens.append({
            "id": screen,
            "referenceHash": sha256(REFERENCE / filename),
            "currentHash": sha256(source),
            "tolerance": {
                "channelDelta": DELTA_THRESHOLD,
                "mismatchRatio": config["mismatchRatio"],
                "maskAreaLimit": MASK_LIMIT,
            },
            "masks": config["masks"],
            "maskAreaRatio": metrics["maskAreaRatio"],
            "metrics": metrics,
            "pass": mask_ok and metrics["mismatchRatio"] <= config["mismatchRatio"],
        })
    generated_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    manifest = {
        "device": "iPad Pro (12.9-inch) (6th generation)", "orientation": "landscape",
        "pixelSize": list(PIXEL_SIZE), "scale": 2, "locale": "en_US", "appearance": "dark",
        "generatedAt": generated_at, "screens": screens,
    }
    REPORT.joinpath("manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    write_viewer(screens, generated_at)
    print(f"report: {REPORT / 'visual-report.html'}")
    if any(not screen["pass"] for screen in screens):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
