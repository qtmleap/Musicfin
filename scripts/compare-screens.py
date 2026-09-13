#!/usr/bin/env python3
"""Musicfin・変更前・Apple Music参照の比較画像と指標を生成する。"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import math
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHOTS = ROOT / "docs" / "screenshots"
CANVAS = (1206, 2622)


def run(*args: str, capture: bool = False) -> str:
    result = subprocess.run(args, check=True, text=True, capture_output=capture)
    return result.stderr if capture else ""


def normalize(source: Path, target: Path) -> tuple[int, int]:
    probe = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "json", str(source),
        ],
        check=True,
        text=True,
        capture_output=True,
    )
    stream = json.loads(probe.stdout)["streams"][0]
    target.parent.mkdir(parents=True, exist_ok=True)
    run(
        "ffmpeg", "-loglevel", "error", "-y", "-i", str(source),
        "-vf",
        f"scale={CANVAS[0]}:{CANVAS[1]}:force_original_aspect_ratio=decrease,"
        f"pad={CANVAS[0]}:{CANVAS[1]}:(ow-iw)/2:(oh-ih)/2:black,format=rgb24",
        "-frames:v", "1", str(target),
    )
    return int(stream["width"]), int(stream["height"])


def render_pair(left: Path, right: Path, target: Path, mode: str) -> None:
    filters = {
        "side": "[0:v][1:v]hstack=inputs=2[out]",
        "overlay": "[0:v][1:v]blend=all_expr='A*0.5+B*0.5'[out]",
        "difference": "[0:v][1:v]blend=all_mode=difference,eq=contrast=2.4:brightness=0.04[out]",
    }
    run(
        "ffmpeg", "-loglevel", "error", "-y", "-i", str(left), "-i", str(right),
        "-filter_complex", filters[mode], "-map", "[out]", "-frames:v", "1", str(target),
    )


def metric(left: Path, right: Path) -> dict[str, float | None]:
    command = [
        "ffmpeg", "-hide_banner", "-i", str(left), "-i", str(right),
        "-lavfi", "[0:v][1:v]ssim;[0:v][1:v]psnr", "-f", "null", "-",
    ]
    output = subprocess.run(command, text=True, capture_output=True).stderr
    ssim_match = re.search(r"SSIM.*All:([0-9.eE+-]+)", output)
    psnr_match = re.search(r"PSNR.*average:([0-9.eE+\-]+|inf)", output)
    psnr = None
    if psnr_match:
        value = psnr_match.group(1)
        psnr = None if value == "inf" else float(value)
    return {"ssim": float(ssim_match.group(1)) if ssim_match else None, "psnr": psnr}


def delta(current: float | None, before: float | None) -> float | None:
    if current is None or before is None or not math.isfinite(current) or not math.isfinite(before):
        return None
    return current - before


def write_report(root: Path, generated_at: str, screens: list[dict]) -> None:
    manifest = {"generatedAt": generated_at, "canvas": list(CANVAS), "screens": screens}
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    cards = []
    for screen in screens:
        metrics = screen["metrics"]
        ssim = metrics["currentReference"]["ssim"]
        change = metrics.get("ssimDelta")
        change_text = "基準なし" if change is None else f"{change:+.4f}"
        change_class = "neutral" if change is None else "good" if change > 0 else "bad"
        screen_id = html.escape(screen["id"])
        cards.append(f"""
<section>
  <div class="heading"><h2>{screen_id}</h2><span>SSIM {ssim:.4f}</span><span class="{change_class}">Δ {change_text}</span></div>
  <a href="{screen_id}/side-by-side.png"><img src="{screen_id}/side-by-side.png?v={generated_at}" alt="{screen_id} side by side"></a>
  <div class="links"><a href="{screen_id}/overlay.png">Overlay</a><a href="{screen_id}/difference.png">Difference</a></div>
</section>""")
    document = f"""<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Screenshot Diff</title><style>
:root{{color-scheme:light dark;font-family:system-ui,sans-serif;background:#09090b;color:#fafafa}}body{{margin:0;padding:24px;max-width:1500px;margin-inline:auto}}header{{border-bottom:1px solid #3f3f46;padding-bottom:18px;margin-bottom:24px}}h1,h2,p{{margin:0}}p{{color:#a1a1aa}}main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));gap:28px}}section{{border-top:1px solid #3f3f46;padding-top:14px}}.heading,.links{{display:flex;align-items:center;gap:12px;margin-bottom:10px}}.heading h2{{margin-right:auto}}span,.links a{{font:12px ui-monospace,monospace;color:#a1a1aa}}.good{{color:#4ade80}}.bad{{color:#fb7185}}img{{display:block;width:100%;border:1px solid #3f3f46;border-radius:6px}}.links{{margin-top:10px}}a{{color:#fafafa}}
</style></head><body><header><h1>Screenshot Diff</h1><p>左: Musicfin / 右: Apple Music · {html.escape(generated_at)}</p></header><main>{''.join(cards)}</main></body></html>"""
    (root / "index.html").write_text(document)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("screens", nargs="*")
    args = parser.parse_args()
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise SystemExit("ffmpeg と ffprobe が必要です")

    current_root = SHOTS / "current"
    baseline_root = SHOTS / "previous"
    reference_root = SHOTS / "reference"
    output_root = SHOTS / "comparison"
    output_root.mkdir(parents=True, exist_ok=True)
    available = sorted(p.stem for p in current_root.glob("*.png") if (reference_root / p.name).exists())
    selected = args.screens or available
    unknown = [screen for screen in selected if screen not in available]
    if unknown:
        raise SystemExit(f"比較画像が揃っていません: {', '.join(unknown)}")

    reports = []
    for screen in selected:
        target = output_root / screen
        target.mkdir(parents=True, exist_ok=True)
        current_size = normalize(current_root / f"{screen}.png", target / "current.png")
        reference_size = normalize(reference_root / f"{screen}.png", target / "reference.png")
        render_pair(target / "current.png", target / "reference.png", target / "side-by-side.png", "side")
        render_pair(target / "current.png", target / "reference.png", target / "overlay.png", "overlay")
        render_pair(target / "current.png", target / "reference.png", target / "difference.png", "difference")
        current_metric = metric(target / "current.png", target / "reference.png")
        before_metric = None
        baseline = baseline_root / f"{screen}.png"
        if baseline.exists():
            normalize(baseline, target / "before.png")
            render_pair(target / "before.png", target / "reference.png", target / "before-difference.png", "difference")
            before_metric = metric(target / "before.png", target / "reference.png")
        reports.append({
            "id": screen,
            "sourceSize": {"current": list(current_size), "reference": list(reference_size)},
            "metrics": {
                "currentReference": current_metric,
                "beforeReference": before_metric,
                "ssimDelta": delta(current_metric["ssim"], before_metric["ssim"] if before_metric else None),
                "psnrDelta": delta(current_metric["psnr"], before_metric["psnr"] if before_metric else None),
            },
        })
        print(f"{screen}: SSIM {current_metric['ssim']:.4f}")

    generated_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    write_report(output_root, generated_at, reports)
    print(f"report: {output_root / 'index.html'}")


if __name__ == "__main__":
    main()
