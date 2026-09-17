#!/usr/bin/env bash
# 主要画面を英語・ダークモードで staging へ撮影し、全 gate 通過後だけ current を置き換える。
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

device_name="iPhone 15"
ipad=0
default_shot_root="docs/screenshots/current"
shot_root="${MUSICFIN_SHOT_ROOT:-$default_shot_root}"
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
        device_name="iPad Air 13-inch (M3)"
        default_shot_root="docs/screenshots/ipad-report/current"
        if [ "${MUSICFIN_SHOT_ROOT+x}" != x ]; then
            shot_root="$default_shot_root"
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

if [ -z "$version" ]; then
    version="$(grep -m1 'MARKETING_VERSION = ' Musicfin.xcodeproj/project.pbxproj | cut -d= -f2 | tr -d ' ;')"
fi

# worktree や別セッションも同じ Simulator service を使うため、端末操作より前に host 全体を排他する。
lock="${TMPDIR:-/tmp}/musicfin-screenshot-capture.lock"
if ! mkdir "$lock" 2>/dev/null; then
    echo "another screenshot capture is already running: $lock" >&2
    exit 1
fi
cleanup_lock() { rm -rf -- "$lock"; }
trap cleanup_lock EXIT

# iOS 26 専用アプリなので、同名の古い Simulator が boot 済みでも選ばない。
udid="$(
    xcrun simctl list devices available -j |
        python3 -c '
import json, sys
name = sys.argv[1]
raw = json.load(sys.stdin)["devices"]
candidates = [
    d for runtime, devices in raw.items()
    if "iOS-26-" in runtime
    for d in devices if d["name"] == name
]
candidates.sort(key=lambda d: d["state"] != "Booted")
print(candidates[0]["udid"] if candidates else "")
' "$device_name"
)"
if [ -z "$udid" ]; then
    echo "iOS 26 simulator not found: $device_name" >&2
    exit 1
fi
destination="platform=iOS Simulator,id=$udid"
if ! xcrun simctl list devices booted | grep -q "$udid"; then
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b
fi
xcrun simctl ui "$udid" appearance dark

parent="$(dirname "$shot_root")"
mkdir -p "$parent"
parent="$(cd "$parent" && pwd)"
staging="$(mktemp -d "$parent/.capture.XXXXXX")"
shot_dir="$staging"
bridge="$(mktemp -d "$parent/.capture-bridge.XXXXXX")"
worker_pid=""
cleanup() {
    if [ -n "$worker_pid" ]; then
        kill "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
    fi
    rm -rf -- "$staging" "$bridge" "$lock"
}
trap cleanup EXIT
if [ "$ipad" -eq 1 ]; then
    capture_width=2732
    capture_height=2048
else
    capture_width=1179
    capture_height=2556
fi
python3 scripts/native-screenshot-worker.py \
    --bridge "$bridge" --output "$shot_dir" --udid "$udid" \
    --width "$capture_width" --height "$capture_height" &
worker_pid=$!
# 期限切れの Keychain token が残るとログイン済み表示のまま全 API が空になるため、撮影は必ず新規認証から始める。
xcrun simctl uninstall "$udid" jp.qleap.musicfin 2>/dev/null || true
status=0
test_methods=(testCaptureLoginScreens testCaptureAppScreens)
required_methods=("${test_methods[@]}")
if [ "$ipad" -eq 1 ]; then
    # 対象外の player 導線が単独で落ちても、sidebar と検索・一覧の比較セットまで更新できなくなる
    # のは行き過ぎなので、必須は配置回帰だけにする。同じ名前を前段も撮るため最後に回し、
    # 必須セットは常に最新の 1 回で揃った世代が残るようにする。
    test_methods=(testCaptureAppScreens testCaptureIPadPlayer testCaptureIPadLayoutRegression)
    required_methods=(testCaptureIPadLayoutRegression)
fi
for test_method in "${test_methods[@]}"; do
    echo "==> capture: $version / en_US / dark / ${content_size:-default} / $test_method -> staging"
    if ! TEST_RUNNER_MUSICFIN_SHOT_DIR="$shot_dir" \
        TEST_RUNNER_MUSICFIN_CAPTURE_BRIDGE_DIR="$bridge" \
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
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 1800 \
        -maximum-test-execution-time-allowance 1800 \
        2>&1 | grep -E --line-buffered "error:|failed|Test Case|\*\* TEST"; then
        if [[ " ${required_methods[*]} " == *" $test_method "* ]]; then
            echo "!! $test_method: 必須のテストが失敗した。current は更新しない" >&2
            status=1
        else
            echo "-- $test_method: 失敗したが必須ではない。撮れた分だけ使う" >&2
        fi
    fi
done
if [ "$status" -ne 0 ]; then
    exit "$status"
fi
kill "$worker_pid" 2>/dev/null || true
wait "$worker_pid" 2>/dev/null || true
worker_pid=""

python3 - "$staging" "$device_name" "$version" "$ipad" "$shot_root" <<'PY'
import datetime, hashlib, json, pathlib, shutil, struct, sys
root = pathlib.Path(sys.argv[1])
device, version, ipad = sys.argv[2], sys.argv[3], sys.argv[4] == "1"
previous = pathlib.Path(sys.argv[5])
# 期待集合は撮影の流れが実際に撮る名前と一致していなければならない。iPad は sidebar から
# 一覧を直接出すので Library 入口・ジャンル・プレイリスト・お気に入りの 5 枚を通らず、
# それらを共通側に置くと gate が永久に missing を返して current が更新されなくなる。
base = {
    "home", "artists", "artist", "songs", "albums", "album", "account",
    "search-idle", "search", "miniplayer", "nowplaying",
    "lyrics-loading", "lyrics", "queue",
}
expected = base | ({"playing", "search-artist", "search-artist-bottom", "search-album-detail"} if ipad else {
    "library", "playlists", "playlist", "genres", "favorites",
    "login-server", "login-credentials", "login-quickconnect",
    "search-push", "search-pop", "search-typing",
})
# iPad は配置回帰だけを必須にする（上の required_methods と対の関係）。欠けた任意の画面は
# 直前の世代から引き継いで、current が常に全画面そろった 1 つのディレクトリであるようにする。
required = expected & {
    "home", "artists", "songs", "albums", "search-idle", "search"
} if ipad else set(expected)
files = {p.stem: p for p in root.glob("*.png")}
missing, extra = sorted(required - files.keys()), sorted(files.keys() - expected)
if missing or extra:
    raise SystemExit(f"capture set mismatch; missing={missing}, extra={extra}")
carried = set()
for screen in sorted(expected - required - files.keys()):
    source = previous / f"{screen}.png"
    if not source.exists():
        print(f"!! 任意の画面を撮れず、引き継ぎ元も無い: {screen}", file=sys.stderr)
        continue
    destination = root / f"{screen}.png"
    shutil.copy2(source, destination)
    files[screen] = destination
    carried.add(screen)
if carried:
    print(f"carried over from the previous generation: {', '.join(sorted(carried))}")
pixel_size = (2732, 2048) if ipad else (1179, 2556)
shots = []
for screen in sorted(files):
    path = files[screen]
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"PNG ではありません: {path}")
    size = struct.unpack(">II", data[16:24])
    if size != pixel_size:
        raise SystemExit(f"{pixel_size[0]}x{pixel_size[1]} ではありません: {path} ({size[0]}x{size[1]})")
    shot = {
        "screen": screen, "path": path.name, "pixelSize": list(size),
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    # 引き継いだ画面は今回の撮影ではないので、世代を取り違えないよう manifest に明示する。
    if screen in carried:
        shot["carriedOver"] = True
    shots.append(shot)
manifest = {
    "version": version, "language": "en", "locale": "en_US", "appearance": "dark",
    "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "device": device, "orientation": "landscape" if ipad else "portrait",
    "pixelSize": list(pixel_size), "scale": 2 if ipad else 3, "shots": shots,
}
(root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
fresh = len(shots) - len(carried)
print(
    f"{fresh} fresh shots passed semantic/name, dimension, and hash gates"
    + (f" ({len(carried)} carried over)" if carried else "")
)
PY

# current は全 method と全 gate が通った完全な世代だけを指す。
backup="${shot_root}.old.$$"
if [ -e "$shot_root" ]; then
    mv -- "$shot_root" "$backup"
fi
if mv -- "$staging" "$shot_root"; then
    rm -rf -- "$backup"
else
    [ ! -e "$backup" ] || mv -- "$backup" "$shot_root"
    exit 1
fi
rm -rf -- "$bridge"

# 差し替えた世代を mock-diff のワークスペースに焼き直す。差分の計算と閾値の判断は
# ビューアの仕事なので、ここは参照と実装を並べ直すだけで終了コードには持ち込まない。
if [ "$shot_root" = "$default_shot_root" ]; then
    if [ "$ipad" -eq 1 ]; then
        mock_diff_device=iPad
    else
        mock_diff_device=iPhone
    fi
    printf '\n==> mock-diff: %s\n' "$mock_diff_device"
    python3 scripts/build-mock-diff-workspace.py --device "$mock_diff_device" ||
        echo "-- ワークスペースを組み直せなかった" >&2
else
    echo "-- 既定以外の出力先なので mock-diff の更新を飛ばした: $shot_root" >&2
fi

printf '\n==> generated\n'
find "$shot_root" -maxdepth 1 -name '*.png' | sort
rm -rf -- "$lock"
trap - EXIT
