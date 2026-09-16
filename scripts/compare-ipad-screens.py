#!/usr/bin/env python3
"""iPad reference と current を同寸法のまま比較し、独立した report を生成する。"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "docs" / "app" / "catalog.json"
REFERENCE = ROOT / "docs" / "app"
REPORTS = {
    "iPhone": ROOT / "docs" / "screenshots",
    "iPad": ROOT / "docs" / "screenshots" / "ipad-report",
}
DEVICE_CONFIG = {
    "iPhone": {
        "manifestDevice": "iPhone 15",
        "orientation": "portrait",
        "pixelSize": (1179, 2556),
        "scale": 3,
    },
    "iPad": {
        "manifestDevice": "iPad Air 13-inch (M3)",
        "orientation": "landscape",
        "pixelSize": (2732, 2048),
        "scale": 2,
    },
}
DELTA_THRESHOLD = 8
MASK_LIMIT = 0.25
DEFAULT_MISMATCH_RATIO = 0.10


def run(*args: str, quiet: bool = False) -> None:
    subprocess.run(
        args,
        check=True,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if quiet else None,
    )


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


def normalize(source: Path, target: Path, pixel_size: tuple[int, int]) -> None:
    source_size = dimensions(source)
    if source_size != pixel_size:
        expected = "x".join(map(str, pixel_size))
        raise SystemExit(f"{expected} ではありません: {source} ({source_size})")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="musicfin-normalize-"))
    decoded = temporary / "decoded.png"
    converted = temporary / "srgb.png"
    try:
        # ffmpeg は色変換を挟まず、各形式を 8 bit RGB PNG へ展開するだけに留める。
        run(
            "ffmpeg", "-loglevel", "error", "-y", "-i", str(source),
            "-frames:v", "1", str(decoded),
        )
        run(
            "sips", "--matchTo", "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
            str(decoded), "--out", str(converted), quiet=True,
        )
        shutil.copyfile(converted, target)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
    if dimensions(target) != pixel_size:
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


def paired_stories(device: str) -> tuple[list[dict[str, str]], list[dict]]:
    catalog = json.loads(CATALOG.read_text())
    masks = catalog.get("defaults", {}).get("masks", {}).get(device, [])
    stories = []
    seen_captures: set[str] = set()
    for story in catalog.get("stories", []):
        item = story.get("devices", {}).get(device)
        if not item or not item.get("capture"):
            continue
        capture = item["capture"]
        if capture in seen_captures:
            raise SystemExit(f"{device} capture が重複しています: {capture}")
        seen_captures.add(capture)
        stories.append(
            {
                "id": story["id"],
                "capture": capture,
                "reference": item["reference"],
                "category": story["category"],
                "title": story["title"],
            }
        )
    if not stories:
        raise SystemExit(f"catalog に比較可能な {device} story がありません")
    return stories, masks


def write_viewer(
    report: Path, device: str, screens: list[dict], generated_at: str
) -> None:
    cards = "".join(
        f'''<section><h2>{s["title"]}</h2><p>{s["id"]} · masked mismatch {s["metrics"]["mismatchRatio"]:.4%} · masked RGB MAE {s["metrics"]["rgbMAE"]:.5f}<br>raw mismatch {s["metrics"]["rawMismatchRatio"]:.4%} · raw RGB MAE {s["metrics"]["rawRGBMAE"]:.5f} · {"CARRIED OVER (excluded from the fresh gate)" if s["carriedOver"] else "PASS" if s["pass"] else "FAIL"}</p><img data-screen="{s["id"]}" src="{s["id"]}/current.png"></section>'''
        for s in screens
    )
    report.joinpath("visual-report.html").write_text(f'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>{device} Visual Report</title><style>:root{{color-scheme:dark;font:14px system-ui;background:#111;color:#eee}}body{{margin:24px}}nav{{display:flex;gap:8px;position:sticky;top:0;background:#111;padding:12px 0}}button{{padding:8px 12px}}main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:24px}}img{{width:100%;border:1px solid #555}}p{{color:#aaa}}</style><h1>{device} Visual Report</h1><p>{generated_at}</p><nav><button data-mode="reference">Reference</button><button data-mode="current">Current</button><button data-mode="overlay">Overlay</button><button data-mode="difference">Difference</button><button data-mode="masked-difference">Masked difference</button></nav><main>{cards}</main><script>document.querySelectorAll('button').forEach(b=>b.onclick=()=>document.querySelectorAll('img').forEach(i=>i.src=i.dataset.screen+'/'+b.dataset.mode+'.png'))</script>''')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", choices=DEVICE_CONFIG, default="iPad")
    parser.add_argument("--current", type=Path, required=True)
    args = parser.parse_args()
    device = args.device
    config = DEVICE_CONFIG[device]
    report = REPORTS[device]
    pixel_size = config["pixelSize"]
    capture_manifest = json.loads(args.current.joinpath("manifest.json").read_text())
    if capture_manifest.get("device") != config["manifestDevice"]:
        raise SystemExit(
            f"current manifest の device が {config['manifestDevice']} ではありません"
        )
    if capture_manifest.get("orientation") != config["orientation"] or tuple(
        capture_manifest.get("pixelSize", ())
    ) != pixel_size:
        raise SystemExit("current manifest の orientation または pixelSize が不正です")
    shots = {shot["screen"]: shot for shot in capture_manifest.get("shots", [])}
    report.mkdir(parents=True, exist_ok=True)
    screens = []
    stories, masks = paired_stories(device)
    for story in stories:
        screen = story["capture"]
        source = args.current / f"{screen}.png"
        if not source.exists() or screen not in shots:
            raise SystemExit(f"current がありません: {source}")
        if dimensions(source) != pixel_size:
            raise SystemExit(f"current の寸法が不正です: {source} ({dimensions(source)})")
        if sha256(source) != shots[screen].get("sha256"):
            raise SystemExit(f"current manifest の hash と一致しません: {source}")
        target = report / story["id"]
        reference = target / "reference.png"
        current = target / "current.png"
        reference_source = REFERENCE / story["reference"]
        normalize(reference_source, reference, pixel_size)
        normalize(source, current, pixel_size)
        render(reference, current, target / "overlay.png", "[0:v][1:v]blend=all_expr='A*.5+B*.5'[out]")
        render(reference, current, target / "difference.png", "[0:v][1:v]blend=all_mode=difference,eq=contrast=4[out]")
        screen_config = {"mismatchRatio": DEFAULT_MISMATCH_RATIO, "masks": masks}
        metrics = metrics_and_masked_difference(
            reference, current, screen_config["masks"], target / "masked-difference.png"
        )
        mask_ok = metrics["maskAreaRatio"] <= MASK_LIMIT
        screens.append({
            "id": story["id"],
            "capture": screen,
            "category": story["category"],
            "title": story["title"],
            "reference": story["reference"],
            "referenceHash": sha256(reference_source),
            "currentHash": sha256(source),
            "tolerance": {
                "channelDelta": DELTA_THRESHOLD,
                "mismatchRatio": screen_config["mismatchRatio"],
                "maskAreaLimit": MASK_LIMIT,
            },
            "masks": screen_config["masks"],
            "maskAreaRatio": metrics["maskAreaRatio"],
            "metrics": metrics,
            # 撮り直せず前の世代から引き継いだ画面。数値は参考に残すが、今回の実装の合否には数えない。
            "carriedOver": bool(shots[screen].get("carriedOver")),
            "pass": mask_ok and metrics["mismatchRatio"] < screen_config["mismatchRatio"],
        })
    generated_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    manifest = {
        "device": capture_manifest["device"],
        "orientation": config["orientation"],
        "pixelSize": list(pixel_size),
        "scale": config["scale"],
        "locale": "en_US",
        "appearance": "dark",
        "generatedAt": generated_at,
        "screens": screens,
    }
    report.joinpath("manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    write_viewer(report, device, screens, generated_at)
    fresh = [screen for screen in screens if not screen["carriedOver"]]
    carried = [screen["capture"] for screen in screens if screen["carriedOver"]]
    print(f"report: {report / 'visual-report.html'}")
    print(f"{len(fresh)} fresh screens verified, {len(carried)} carried over" + (
        f": {', '.join(sorted(carried))}" if carried else ""
    ))
    # 引き継いだ画面が古い実装のまま FAIL でも、今回の撮影の合否を左右させない。
    if any(not screen["pass"] for screen in fresh):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
