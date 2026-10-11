#!/usr/bin/env python3
"""補間式だけでなく、Simulator が描画した画像の寸法と同一性を検証する。"""
import argparse
import json
from pathlib import Path


def check(directory: Path) -> dict:
    returns = 0
    cancellations = 0
    samples = 0
    for path in sorted(directory.glob("album-overlay-*.jsonl")):
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        samples += len(rows)
        if not rows:
            continue
        images = {row["heroImage"] for row in rows}
        assert len(images) == 1, f"{path.name}: hero image was replaced"
        assert all(row["image"] == row["heroImage"] for row in rows), path.name
        restoring = [index for index, row in enumerate(rows) if row["phase"] == "restoring"]
        if restoring:
            cancellations += 1
            first, last = restoring[0], restoring[-1]
            assert last + 1 < len(rows) and rows[last + 1]["phase"] == "presented", path.name
            target_width = rows[last + 1]["frame"][2]
            width = rows[first]["frame"][2]
            for row in rows[first:last + 1]:
                assert width - 0.6 <= row["frame"][2] <= target_width + 0.6, path.name
                width = row["frame"][2]
        closing = [row for row in rows if row["phase"] in ("closing", "removed") and row["source"]]
        if not closing:
            continue
        returns += 1
        released = closing[0]["released"]
        target = closing[0]["source"]
        assert released and target, path.name
        previous_width = released[2]
        start_center = (released[0] + released[2] / 2, released[1] + released[3] / 2)
        target_center = (target[0] + target[2] / 2, target[1] + target[3] / 2)
        dx, dy = target_center[0] - start_center[0], target_center[1] - start_center[1]
        length = max(1, (dx * dx + dy * dy) ** 0.5)
        for row in closing:
            frame = row["frame"]
            assert frame[2] <= previous_width + 0.6, f"{path.name}: enlarged after release"
            assert frame[2] >= target[2] - 0.6, f"{path.name}: shrank past source"
            assert row["fallback"] == "none", f"{path.name}: return became fallback"
            cx, cy = frame[0] + frame[2] / 2, frame[1] + frame[3] / 2
            distance = abs((cx - start_center[0]) * dy - (cy - start_center[1]) * dx) / length
            assert distance <= 1, f"{path.name}: discontinuous center trajectory ({distance})"
            previous_width = frame[2]
        assert closing[-1]["phase"] == "removed", f"{path.name}: return never completed"
        assert all(abs(a - b) <= 0.6 for a, b in zip(closing[-1]["frame"], target)), path.name
    assert returns >= 1, "no completed artwork return: fallback alone cannot pass"
    assert cancellations >= 1, "no native cancelled drag sampled"
    return {"returns": returns, "cancellations": cancellations, "samples": samples}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("shot_directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.shot_directory)))
