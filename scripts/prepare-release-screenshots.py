#!/usr/bin/env python3
"""公式デモの撮影対象を解決し、提出用画像の寸法と完全性を確認する。"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import urllib.parse
import urllib.request

from PIL import Image

SERVER = "https://demo.jellyfin.org/stable"
SCREENS = ["01-home", "02-albums", "03-album-detail", "04-now-playing", "05-queue", "06-search"]


def resolve(output):
    authorization = (
        'MediaBrowser Client="Musicfin Release Capture", Device="Simulator", '
        'DeviceId="musicfin-release-inventory", Version="0.1.0"'
    )

    def request(path, data=None, token=None):
        headers = {"Authorization": authorization, "Content-Type": "application/json"}
        if token:
            headers["Authorization"] += f', Token="{token}"'
        body = json.dumps(data).encode() if data is not None else None
        with urllib.request.urlopen(urllib.request.Request(SERVER + path, body, headers), timeout=30) as response:
            return json.load(response)

    auth = request("/Users/AuthenticateByName", {"Username": "demo", "Pw": ""})
    query = urllib.parse.urlencode({
        "UserId": auth["User"]["Id"], "Recursive": "true",
        "IncludeItemTypes": "MusicAlbum,Audio", "Fields": "Album", "Limit": "1000",
    })
    items = request("/Items?" + query, token=auth["AccessToken"])["Items"]
    albums = [item for item in items if item["Type"] == "MusicAlbum" and item["Name"] == "Nemesis"]
    if len(albums) != 1 or not albums[0].get("ImageTags", {}).get("Primary"):
        raise ValueError("Official demo must contain one Nemesis album with artwork")
    album = albums[0]
    tracks = [item for item in items if item["Type"] == "Audio" and item["Name"] == "Jellyfin"
              and item.get("AlbumId") == album["Id"]]
    if len(tracks) != 1:
        raise ValueError("Official demo must contain one Jellyfin track on Nemesis")
    fixture = {"server": SERVER, "album_id": album["Id"], "album_title": album["Name"],
               "track_id": tracks[0]["Id"], "track_title": tracks[0]["Name"], "search_query": "i"}
    Path(output).write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    print("Resolved official demo: Nemesis / Jellyfin")


def validate(root, locales, devices, fixture_path, sha, version, screens=None):
    screens = screens or SCREENS
    root = Path(root)
    fixture = json.loads(Path(fixture_path).read_text())
    source_hash = hashlib.sha256()
    for source in sorted(Path("Musicfin").rglob("*")):
        if source.is_file():
            source_hash.update(str(source).encode() + b"\0" + source.read_bytes())
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--", "Musicfin"]).strip())
    manifest = {"server": SERVER, "fixture": fixture, "version": version, "sha": sha,
                "source_worktree_dirty": dirty, "source_tree_sha256": source_hash.hexdigest(),
                "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "images": []}
    for locale in locales:
        for device in devices:
            prefix, size = ("iPhone-6.9", (1320, 2868)) if device == "iPhone" else ("iPad-13", (2048, 2732))
            for screen in screens:
                path = root / locale / f"{prefix}-{screen}.png"
                with Image.open(path) as image:
                    if image.format != "PNG" or image.size != size:
                        raise ValueError(f"Invalid native screenshot dimensions: {path} / {image.size}")
                    if "A" in image.getbands() and image.getchannel("A").getextrema() != (255, 255):
                        raise ValueError(f"Screenshot contains transparency: {path}")
                    # 提出先がアルファを許さないため、完全不透明な画素だけ RGB に格納し直す。
                    if image.mode != "RGB":
                        converted = image.convert("RGB")
                        converted.save(path, icc_profile=image.info.get("icc_profile"))
                manifest["images"].append({"file": str(path.relative_to(root)), "locale": locale,
                    "device": device, "width": size[0], "height": size[1],
                    "source_sha": sha, "version": version, "captured_at": manifest["captured_at"],
                    "source_worktree_dirty": dirty, "source_tree_sha256": source_hash.hexdigest(),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    expected = len(locales) * len(devices) * len(screens)
    if len(list(root.glob("*/*.png"))) != expected:
        raise ValueError("Screenshot set contains unexpected or missing images")
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Validated {expected} opaque native screenshots")


def publish(root, output):
    root, output = Path(root), Path(output).absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".musicfin-release-publish-", dir=output.parent))
    backup = stage.with_name(stage.name + "-previous")
    incoming = json.loads((root / "manifest.json").read_text())
    replaced = {item["file"] for item in incoming["images"]}
    try:
        existing = {"images": []}
        if output.exists():
            shutil.copytree(output, stage, dirs_exist_ok=True)
            if (output / "manifest.json").exists():
                existing = json.loads((output / "manifest.json").read_text())
            known = {item["file"] for item in existing["images"]}
            actual = {str(path.relative_to(output)) for path in output.glob("*/*.png")}
            if actual != known:
                raise ValueError("Existing screenshot set has no complete manifest; publish to a separate output directory")
        retained = [item for item in existing["images"] if item["file"] not in replaced]
        for item in retained:
            if hashlib.sha256((stage / item["file"]).read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError("Existing screenshot checksum differs from its manifest")
        for item in existing["images"]:
            if item["file"] in replaced:
                (stage / item["file"]).unlink()
        for item in incoming["images"]:
            destination = stage / item["file"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / item["file"], destination)
        incoming["images"] = sorted(retained + incoming["images"], key=lambda item: item["file"])
        (stage / "manifest.json").write_text(json.dumps(incoming, ensure_ascii=False, indent=2) + "\n")

        def interrupted(signum, _frame):
            raise InterruptedError(f"Publication interrupted by signal {signum}")

        previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            if output.exists():
                os.replace(output, backup)
            os.replace(stage, output)
        except BaseException:
            if backup.exists() and not output.exists():
                os.replace(backup, output)
            raise
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if backup.exists():
            shutil.rmtree(backup)
        print(f"Published complete generation: {output}")
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    inventory = subparsers.add_parser("resolve")
    inventory.add_argument("output")
    check = subparsers.add_parser("validate")
    check.add_argument("root")
    check.add_argument("--locales", nargs="+", required=True)
    check.add_argument("--devices", nargs="+", required=True)
    check.add_argument("--fixture", required=True)
    check.add_argument("--sha", required=True)
    check.add_argument("--version", required=True)
    check.add_argument("--screens", nargs="+", choices=SCREENS)
    publication = subparsers.add_parser("publish")
    publication.add_argument("root")
    publication.add_argument("output")
    args = parser.parse_args()
    if args.command == "resolve":
        resolve(args.output)
    elif args.command == "validate":
        validate(args.root, args.locales, args.devices, args.fixture, args.sha, args.version, args.screens)
    else:
        publish(args.root, args.output)
