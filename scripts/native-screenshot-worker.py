#!/usr/bin/env python3
"""UI test の atomic request を native Simulator screenshot と atomic ack に変換する。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import subprocess
import time
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_size(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != PNG_SIGNATURE:
        raise ValueError("output is not PNG")
    return struct.unpack(">II", data[16:24])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    args = parser.parse_args()
    args.bridge.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)

    while True:
        requests = sorted(args.bridge.glob("*.request"))
        if not requests:
            time.sleep(0.025)
            continue
        for request in requests:
            screen = request.stem
            temporary = args.output / f".{screen}.native.tmp.png"
            output = args.output / f"{screen}.png"
            ack_temporary = args.bridge / f".{screen}.ack.tmp"
            ack = args.bridge / f"{screen}.ack"
            try:
                subprocess.run(
                    [
                        "/usr/bin/xcrun", "simctl", "io", args.udid, "screenshot",
                        "--type=png", str(temporary),
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    timeout=15,
                )
                data = temporary.read_bytes()
                size = png_size(data)
                if size == (args.height, args.width):
                    # iPad の framebuffer は scene が landscape でも物理 portrait 配列で返るため、
                    # native pixels を host 側で向きだけ焼き込み、比較器へ自然寸法で渡す。
                    subprocess.run(
                        ["/usr/bin/sips", "--rotate", "-90", str(temporary)],
                        check=True,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        timeout=15,
                    )
                    data = temporary.read_bytes()
                    size = png_size(data)
                if size != (args.width, args.height):
                    raise ValueError(
                        f"expected {args.width}x{args.height}, got {size[0]}x{size[1]}"
                    )
                os.replace(temporary, output)
                ack_temporary.write_text(
                    json.dumps({
                        "screen": screen,
                        "pixelSize": list(size),
                        "sha256": hashlib.sha256(data).hexdigest(),
                    }) + "\n"
                )
                os.replace(ack_temporary, ack)
            except Exception as error:
                (args.bridge / f"{screen}.error").write_text(str(error) + "\n")
            finally:
                request.unlink(missing_ok=True)
                temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
