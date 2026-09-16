#!/usr/bin/env bash
# 主要画面を英語・ダークモードで撮影し、current世代のmanifestを生成する。
#
#   ./scripts/capture-screens.sh
#   ./scripts/capture-screens.sh --version 0.1.0-r5
#   ./scripts/capture-screens.sh --ipad
#   MUSICFIN_CONTENT_SIZE=UICTContentSizeCategoryAccessibilityXXXL \
#     MUSICFIN_SHOT_ROOT=/tmp/shots-ax ./scripts/capture-screens.sh
#   MUSICFIN_SERVER_URL=https://jellyfin.example.com \
#     MUSICFIN_USERNAME=demo MUSICFIN_PASSWORD=secret ./scripts/capture-screens.sh
set -euo pipefail

cd "$(dirname "$0")/.."

device_name="iPhone 17 Pro"
ipad=0
shot_root="${MUSICFIN_SHOT_ROOT:-docs/screenshots/current}"
# 文字サイズ。未指定なら空のまま渡し、テスト側は起動引数を足さない（既定の撮影は今までどおり）。
content_size="${MUSICFIN_CONTENT_SIZE:-}"
server_url="${MUSICFIN_SERVER_URL:-https://jellyfin.tkgstrator.work}"
username="${MUSICFIN_USERNAME:-demo}"
password="${MUSICFIN_PASSWORD:-}"
version=""

while [ $# -gt 0 ]; do
    case "$1" in
    --ipad)
        ipad=1
        device_name="Musicfin iPad Pro 12.9 6th"
        if [ "${MUSICFIN_SHOT_ROOT+x}" != x ]; then
            shot_root="docs/screenshots/ipad-report/current"
        fi
        shift
        ;;
    --version)
        version="$2"
        shift 2
        ;;
    -h | --help)
        sed -n '2,7p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done

destination="platform=iOS Simulator,name=$device_name"
if [ -z "$version" ]; then
    version="$(grep -m1 'MARKETING_VERSION = ' Musicfin.xcodeproj/project.pbxproj | cut -d= -f2 | tr -d ' ;')"
fi

udid="$(
    xcrun simctl list devices available -j |
        python3 -c '
import json, sys
name = sys.argv[1]
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in ds if d["name"] == name]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")
' "$device_name"
)"
if [ -z "$udid" ]; then
    echo "simulator not found: $device_name" >&2
    exit 1
fi
if ! xcrun simctl list devices booted | grep -q "$udid"; then
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b
fi
xcrun simctl ui "$udid" appearance dark

mkdir -p "$shot_root"
shot_dir="$(cd "$shot_root" && pwd)"
status=0
# 撮影が1枚も走らなくても前回のPNGが残るので、更新の有無は時刻で見分ける。
stamp="$(mktemp)"
trap 'rm -f "$stamp"' EXIT
test_methods=(testCaptureLoginScreens testCaptureAppScreens)
if [ "$ipad" -eq 1 ]; then
    test_methods=(testCaptureAppScreens testCaptureIPadPlayer)
fi
for test_method in "${test_methods[@]}"; do
    echo "==> capture: $version / en_US / dark / ${content_size:-default} / $test_method -> $shot_dir"
    if ! TEST_RUNNER_MUSICFIN_SHOT_DIR="$shot_dir" \
        TEST_RUNNER_MUSICFIN_CONTENT_SIZE="$content_size" \
        TEST_RUNNER_MUSICFIN_IPAD_CAPTURE="$ipad" \
        TEST_RUNNER_MUSICFIN_SERVER_URL="$server_url" \
        TEST_RUNNER_MUSICFIN_USERNAME="$username" \
        TEST_RUNNER_MUSICFIN_PASSWORD="$password" \
        TEST_RUNNER_AppleLanguages="(en)" \
        TEST_RUNNER_AppleLocale="en_US" \
        xcodebuild test \
        -project Musicfin.xcodeproj \
        -scheme Musicfin \
        -only-testing:"MusicfinUITests/CaptureScreensUITests/$test_method" \
        -destination "$destination" \
        -derivedDataPath .build \
        2>&1 | grep -E --line-buffered "error:|failed|Test Case|\*\* TEST"; then
        echo "!! $test_method: テストが失敗した（撮れた分は残っている）" >&2
        status=1
    fi
done

python3 - "$shot_root" "$device_name" "$version" <<'PY'
import datetime, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
shots = [{"screen": p.stem, "path": p.name} for p in sorted(root.glob("*.png"))]
manifest = {
    "version": sys.argv[3],
    "language": "en",
    "locale": "en_US",
    "appearance": "dark",
    "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "device": sys.argv[2],
    "shots": shots,
}
(root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(f"{len(shots)} shots")
PY

# 撮影直後にカタログを再生成し、追加されたcurrentを再読込だけで比較できるようにする。
python3 scripts/generate-screenshot-catalog.py

if [ "$ipad" -eq 1 ]; then
    python3 - "$shot_root" <<'PY'
import pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
for path in root.glob("*.png"):
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"PNG ではありません: {path}")
    size = struct.unpack(">II", data[16:24])
    if size != (2732, 2048):
        raise SystemExit(f"2732x2048 ではありません: {path} ({size[0]}x{size[1]})")
PY
fi

printf '\n==> generated\n'
find "$shot_root" -maxdepth 1 -name '*.png' -newer "$stamp" | sort
stale="$(find "$shot_root" -maxdepth 1 -name '*.png' ! -newer "$stamp" | sort)"
if [ -n "$stale" ]; then
    printf '\n!! 今回更新されなかった（前回のまま）:\n%s\n' "$stale" >&2
    status=1
fi
exit "$status"
