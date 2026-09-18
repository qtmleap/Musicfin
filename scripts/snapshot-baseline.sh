#!/usr/bin/env bash
# 現在版を次回比較用のprevious世代へ原子的に保存する。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
shot_root="$repo_root/docs/screenshots"
current="$shot_root/current"
label=""

while [ $# -gt 0 ]; do
    case "$1" in
    --label)
        label="$2"
        shift 2
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done

python3 - "$current" <<'PY'
import hashlib, json, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
for key, expected in (("language", "en"), ("locale", "en_US"), ("appearance", "dark")):
    if manifest.get(key) != expected:
        raise SystemExit(f"current manifest: {key} must be {expected}")
shots = manifest.get("shots", [])
if len(shots) != 25:
    raise SystemExit(f"current manifest: expected 25 shots, found {len(shots)}")
expected_size = tuple(manifest.get("pixelSize", ()))
for shot in shots:
    path = root / shot["path"]
    if not path.is_file():
        raise SystemExit(f"missing current shot: {shot['screen']}")
    data = path.read_bytes()
    size = struct.unpack(">II", data[16:24]) if data[:8] == b"\x89PNG\r\n\x1a\n" else None
    if size != expected_size or shot.get("pixelSize") != list(expected_size):
        raise SystemExit(f"current shot has invalid dimensions: {shot['screen']}")
    if hashlib.sha256(data).hexdigest() != shot.get("sha256"):
        raise SystemExit(f"current shot has invalid hash: {shot['screen']}")
PY

staging="$(mktemp -d "$shot_root/.previous.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
cp -R "$current"/. "$staging"/
if [ -n "$label" ]; then
    python3 - "$staging/manifest.json" "$label" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = json.loads(path.read_text()); data["version"] = sys.argv[2]
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
fi
rm -rf -- "$shot_root/previous"
mv -- "$staging" "$shot_root/previous"
trap - EXIT
echo "previous世代を保存しました: $shot_root/previous"
