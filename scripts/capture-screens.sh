#!/usr/bin/env bash
# 主要画面を英語・ダークモードで撮影し、current世代のmanifestを生成する。
#
#   ./scripts/capture-screens.sh
#   ./scripts/capture-screens.sh --version 0.1.0-r5
set -euo pipefail

cd "$(dirname "$0")/.."

device_name="iPhone 17 Pro"
destination="platform=iOS Simulator,name=$device_name"
shot_root="${MUSICFIN_SHOT_ROOT:-docs/screenshots/current}"
version=""

while [ $# -gt 0 ]; do
    case "$1" in
    --version)
        version="$2"
        shift 2
        ;;
    -h | --help)
        sed -n '2,5p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done

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
for test_method in testCaptureLoginScreens testCaptureAppScreens; do
    echo "==> capture: $version / en_US / dark / $test_method -> $shot_dir"
    if ! TEST_RUNNER_MUSICFIN_SHOT_DIR="$shot_dir" \
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

printf '\n==> generated\n'
find "$shot_root" -maxdepth 1 -name '*.png' -newer "$stamp" | sort
stale="$(find "$shot_root" -maxdepth 1 -name '*.png' ! -newer "$stamp" | sort)"
if [ -n "$stale" ]; then
    printf '\n!! 今回更新されなかった（前回のまま）:\n%s\n' "$stale" >&2
    status=1
fi
exit "$status"
