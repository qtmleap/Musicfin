#!/usr/bin/env bash
# 主要画面を UI テストで撮影し、docs/screenshots/<appearance>/<screen>.png と
# docs/screenshots/manifest.json（index.html が読む）を生成する。
#
#   ./scripts/capture-screens.sh                    # light と dark
#   ./scripts/capture-screens.sh --appearance dark
#
# --appearance は複数回指定できる。保存先のルートは MUSICFIN_SHOT_ROOT で上書きできる。
set -euo pipefail

cd "$(dirname "$0")/.."

device_name="iPhone 17 Pro"
destination="platform=iOS Simulator,name=$device_name"
shot_root="${MUSICFIN_SHOT_ROOT:-docs/screenshots}"
appearances=()

while [ $# -gt 0 ]; do
    case "$1" in
    --appearance)
        appearances+=("$2")
        shift 2
        ;;
    -h | --help)
        sed -n '2,8p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done
[ ${#appearances[@]} -eq 0 ] && appearances=(light dark)

for appearance in "${appearances[@]}"; do
    case "$appearance" in
    light | dark) ;;
    *)
        echo "unknown appearance: $appearance (light / dark)" >&2
        exit 2
        ;;
    esac
done

# destination と同じ名前のシミュレータを探し、起動していなければ起動する（外観切替に udid が要る）。
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
    echo "==> boot simulator $udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b
fi

status=0
for appearance in "${appearances[@]}"; do
    xcrun simctl ui "$udid" appearance "$appearance"
    shot_dir="$shot_root/$appearance"
    mkdir -p "$shot_dir"
    shot_dir="$(cd "$shot_dir" && pwd)"

    for test_method in testCaptureLoginScreens testCaptureAppScreens; do
        echo "==> capture: $appearance / $test_method -> $shot_dir"
        # 出力は要点だけに絞るが、テストの失敗は最後にまとめて exit code で返す。
        # xcodebuild は TEST_RUNNER_ を前置した環境変数だけをテストランナーへ渡す。
        if ! TEST_RUNNER_MUSICFIN_SHOT_DIR="$shot_dir" \
            xcodebuild test \
            -project Musicfin.xcodeproj \
            -scheme Musicfin \
            -only-testing:"MusicfinUITests/CaptureScreensUITests/$test_method" \
            -destination "$destination" \
            -derivedDataPath .build \
            2>&1 | grep -E --line-buffered "error:|failed|Test Case|\*\* TEST"; then
            echo "!! $appearance / $test_method: テストが失敗した（撮れた分は残っている）" >&2
            status=1
        fi
    done
done

echo "==> write $shot_root/manifest.json"
python3 - "$shot_root" "$device_name" <<'PY'
import datetime, json, pathlib, sys

root = pathlib.Path(sys.argv[1])
shots = []
for png in sorted(root.glob("*/*.png")):
    appearance = png.parent.name
    if appearance not in ("light", "dark"):
        continue
    shots.append({
        "appearance": appearance,
        "screen": png.stem,
        "path": f"{appearance}/{png.name}",
    })
shots.sort(key=lambda s: s["path"])
manifest = {
    "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "device": sys.argv[2],
    "shots": shots,
}
(root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(f"{len(shots)} shots")
PY

echo
echo "==> generated"
find "$shot_root" -name '*.png' -path '*/light/*' -o -name '*.png' -path '*/dark/*' | sort
exit "$status"
