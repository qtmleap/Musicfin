#!/usr/bin/env bash
# 公式デモ専用の端末で撮影し、全画像の検証が通った世代だけを提出用に保存する。
set -euo pipefail
cd "$(dirname "$0")/.."

locales=(ja en-US)
devices=(iPhone iPad)
output="${MUSICFIN_RELEASE_OUTPUT:-fastlane/screenshots}"
home_only=0
screens=(01-home 02-albums 03-album-detail 04-now-playing 05-queue 06-search)
while [ $# -gt 0 ]; do
    case "$1" in
    --locale)
        case "$2" in ja|en-US) locales=("$2") ;; *) echo 'locale must be ja or en-US' >&2; exit 2 ;; esac
        shift 2 ;;
    --device)
        case "$2" in iPhone|iPad) devices=("$2") ;; *) echo 'device must be iPhone or iPad' >&2; exit 2 ;; esac
        shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --home-only) home_only=1; screens=(01-home); shift ;;
    --help) echo 'capture-release-screens.sh [--locale ja|en-US] [--device iPhone|iPad] [--home-only] [--output DIR]'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

build_developer="${MUSICFIN_BUILD_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}"
sim_developer="${MUSICFIN_SIMCTL_DEVELOPER_DIR:-$build_developer}"
export DEVELOPER_DIR="$build_developer"
export MUSICFIN_SIMCTL_DEVELOPER_DIR="$sim_developer"
python="${MUSICFIN_PYTHON:-/usr/bin/python3}"
"$python" -c 'import PIL'
lock="${TMPDIR:-/tmp}/musicfin-screenshot-capture.lock"
if ! mkdir "$lock" 2>/dev/null; then
    echo "another screenshot capture is running: $lock" >&2
    exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/musicfin-release.XXXXXX")"
worker_pid=""
simulator=""
cleanup() {
    if [ -n "$worker_pid" ]; then kill "$worker_pid" 2>/dev/null || true; wait "$worker_pid" 2>/dev/null || true; fi
    if [ -n "$simulator" ]; then xcrun simctl shutdown "$simulator" 2>/dev/null || true; xcrun simctl delete "$simulator" 2>/dev/null || true; fi
    rm -rf -- "$lock"
    # 失敗の証拠と成功時の原画像を残し、既存の撮影セットを巻き込んで消さない。
    echo "Capture logs and staging: $work"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/publish"
cat > "$work/bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = simctl ]; then
    exec env DEVELOPER_DIR="$MUSICFIN_SIMCTL_DEVELOPER_DIR" /usr/bin/xcrun "$@"
fi
exec /usr/bin/xcrun "$@"
SH
chmod +x "$work/bin/xcrun"
export PATH="$work/bin:$PATH"
"$python" scripts/prepare-release-screenshots.py resolve "$work/fixture.json"
album_id="$("$python" -c 'import json,sys;print(json.load(open(sys.argv[1]))["album_id"])' "$work/fixture.json")"
track_id="$("$python" -c 'import json,sys;print(json.load(open(sys.argv[1]))["track_id"])' "$work/fixture.json")"
runtime="${MUSICFIN_RELEASE_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-0}"

for locale in "${locales[@]}"; do
    mkdir -p "$work/publish/$locale"
    for device in "${devices[@]}"; do
        if [ "$device" = iPhone ]; then
            type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
            width=1320; height=2868; ipad=0; prefix=iPhone-6.9
        else
            type=com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M3
            width=2048; height=2732; ipad=1; prefix=iPad-13
        fi
        simulator="$(xcrun simctl create "Musicfin Release $device $locale" "$type" "$runtime")"
        xcrun simctl boot "$simulator"
        xcrun simctl bootstatus "$simulator" -b > "$work/$locale-$device-boot.log" 2>&1
        xcrun simctl ui "$simulator" appearance dark
        xcrun simctl status_bar "$simulator" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState discharging --batteryLevel 100
        shots="$work/$locale-$device/shots"
        bridge="$work/$locale-$device/bridge"
        mkdir -p "$shots" "$bridge"
        scripts/native-screenshot-worker.sh --bridge "$bridge" --output "$shots" --udid "$simulator" --width "$width" --height "$height" > "$work/$locale-$device-worker.log" 2>&1 &
        worker_pid=$!
        echo "Capturing $locale / $device from official Jellyfin demo"
        TEST_RUNNER_MUSICFIN_SHOT_DIR="$shots" \
        TEST_RUNNER_MUSICFIN_CAPTURE_BRIDGE_DIR="$bridge" \
        TEST_RUNNER_MUSICFIN_RELEASE_LOCALE="$locale" \
        TEST_RUNNER_MUSICFIN_RELEASE_HOME_ONLY="$home_only" \
        TEST_RUNNER_MUSICFIN_RELEASE_ALBUM_ID="$album_id" \
        TEST_RUNNER_MUSICFIN_RELEASE_TRACK_ID="$track_id" \
        TEST_RUNNER_MUSICFIN_RELEASE_SEARCH_QUERY='i' \
        TEST_RUNNER_MUSICFIN_SERVER_URL='https://demo.jellyfin.org/stable' \
        TEST_RUNNER_MUSICFIN_USERNAME=demo TEST_RUNNER_MUSICFIN_PASSWORD='' \
        TEST_RUNNER_MUSICFIN_IPAD_CAPTURE="$ipad" \
        xcodebuild test -project Musicfin.xcodeproj -scheme Musicfin \
            -only-testing:MusicfinUITests/CaptureScreensUITests/testCaptureReleaseScreens \
            -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath .build \
            -parallel-testing-enabled NO -test-timeouts-enabled YES \
            -default-test-execution-time-allowance 1800 -maximum-test-execution-time-allowance 1800 \
            -resultBundlePath "$work/$locale-$device.xcresult" > "$work/$locale-$device-test.log" 2>&1
        kill "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
        worker_pid=""
        for screen in "${screens[@]}"; do
            cp "$shots/$screen.png" "$work/publish/$locale/$prefix-$screen.png"
        done
        xcrun simctl shutdown "$simulator"
        xcrun simctl delete "$simulator"
        simulator=""
    done
done
version="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' Musicfin.xcodeproj/project.pbxproj | head -n 1)"
"$python" scripts/prepare-release-screenshots.py validate "$work/publish" --locales "${locales[@]}" --devices "${devices[@]}" --screens "${screens[@]}" --fixture "$work/fixture.json" --sha "$(git rev-parse HEAD)" --version "$version"
"$python" scripts/prepare-release-screenshots.py publish "$work/publish" "$output"
"$python" scripts/build-mock-diff-workspace.py --device iPhone
"$python" scripts/build-mock-diff-workspace.py --device iPad
echo "Release screenshots: $output"
