#!/usr/bin/env bash
# 実機の Apple Music 参照画面をローカルへ保存し、比較ビュー用 manifest を更新する。
# 個人情報を含み得るため、出力先は .gitignore 済みの reference/ に固定する。
#
#   ./scripts/capture-apple-music-reference.sh home
#   ./scripts/capture-apple-music-reference.sh account --device <UDID>
set -euo pipefail

cd "$(dirname "$0")/.."

reference_root="docs/screenshots/reference"
device_udid=""
screen=""

usage() {
    sed -n '2,6p' "$0"
    printf '\n画面 ID:\n  home new radio library search-idle search-typing search playlists playlist albums album\n  artists artist songs miniplayer nowplaying lyrics queue account account-settings\n'
}

while [ $# -gt 0 ]; do
    case "$1" in
    --device)
        [ $# -ge 2 ] || { echo "--device requires a UDID" >&2; exit 2; }
        device_udid="$2"
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    *)
        [ -z "$screen" ] || { echo "only one screen ID may be specified" >&2; exit 2; }
        screen="$1"
        shift
        ;;
    esac
done

[ -n "$screen" ] || { usage >&2; exit 2; }
case "$screen" in
home | new | radio | library | search-idle | search-typing | search | playlists | playlist | albums | album | artists | artist | songs | miniplayer | nowplaying | lyrics | queue | account | account-settings) ;;
*)
    echo "unknown screen ID: $screen" >&2
    usage >&2
    exit 2
    ;;
esac

connected_devices=()
while IFS= read -r connected_device; do
    [ -n "$connected_device" ] && connected_devices+=("$connected_device")
done < <(idevice_id -l)
if [ -z "$device_udid" ]; then
    if [ "${#connected_devices[@]}" -ne 1 ]; then
        echo "connect exactly one iPhone, or pass --device <UDID>" >&2
        exit 1
    fi
    device_udid="${connected_devices[0]}"
elif ! printf '%s\n' "${connected_devices[@]}" | grep -Fxq "$device_udid"; then
    echo "device is not connected over USB: $device_udid" >&2
    exit 1
fi

command -v uv >/dev/null || { echo "uv is required" >&2; exit 1; }
uv run pymobiledevice3 version >/dev/null

# 遷移中のフレームを誤って残さないよう、撮影は利用者の Enter 確認後だけ行う。
device_name="$(ideviceinfo -u "$device_udid" -k DeviceName)"
product_type="$(ideviceinfo -u "$device_udid" -k ProductType)"
os_version="$(ideviceinfo -u "$device_udid" -k ProductVersion)"
printf 'Apple Music の「%s」が %s に表示され、通知や一時 UI が消えていることを確認してください。\n' "$screen" "$device_name"
read -r -p 'Enter で撮影、Ctrl-C で中止: '

mkdir -p "$reference_root"
target="$reference_root/$screen.png"
if [ -e "$target" ]; then
    # 既存の比較根拠を失わないよう、同名画像は時刻付きで退避してから更新する。
    backup="$reference_root/$screen.$(date +%Y%m%d-%H%M%S).png"
    cp -p "$target" "$backup"
    echo "==> backup: $backup"
fi

temporary="$reference_root/.$screen.capture.png"
trap 'rm -f "$temporary"' EXIT
PYMOBILEDEVICE3_UDID="$device_udid" uv run pymobiledevice3 developer dvt screenshot "$temporary"

# 拡張子と実データの不一致を比較ビューへ持ち込まない。
if ! file "$temporary" | grep -q 'PNG image data'; then
    echo "captured file is not PNG" >&2
    exit 1
fi
mv "$temporary" "$target"
trap - EXIT

python3 - "$reference_root" "$screen" "$device_name" "$product_type" "$os_version" <<'PY'
import datetime
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
screen = sys.argv[2]
manifest_path = root / "manifest.json"
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")

try:
    manifest = json.loads(manifest_path.read_text())
except (FileNotFoundError, json.JSONDecodeError):
    manifest = {}

entries = manifest.get("screens", [])
normalized = []
for entry in entries:
    if isinstance(entry, str):
        normalized.append({"id": entry, "status": "captured"})
    elif isinstance(entry, dict) and isinstance(entry.get("id"), str):
        normalized.append(entry)

record = {
    "id": screen,
    "status": "captured",
    "path": f"{screen}.png",
    "capturedAt": now,
    "device": f"{sys.argv[3]} ({sys.argv[4]})",
    "os": f"iOS {sys.argv[5]}",
    "source": "Apple Music 実機",
}
by_id = {entry["id"]: entry for entry in normalized}
by_id[screen] = record
order = [
    "home", "new", "radio", "library", "search-idle", "search-typing", "search",
    "playlists", "playlist", "albums", "album", "artists", "artist",
    "songs", "miniplayer", "nowplaying", "lyrics", "queue",
    "account", "account-settings",
]
extra = sorted(set(by_id) - set(order))
manifest = {
    "generatedAt": now,
    "note": "Apple Music の実機比較資料。個人情報を含み得るため再配布しない",
    "screens": [by_id[item] for item in [*order, *extra] if item in by_id],
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
PY

echo "==> captured: $target"
file "$target"
