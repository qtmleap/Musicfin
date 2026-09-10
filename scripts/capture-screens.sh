#!/usr/bin/env bash
#
# シミュレータでアプリを動かし、主要画面のスクリーンショットを撮る。
#
# UI テスト (MusicfinUITests/ScreenshotTests.swift) が画面遷移と撮影を行い、
# このスクリプトは結果バンドルから PNG を取り出して並べ直す。
#
# 使い方:
#   ./scripts/capture-screens.sh                    out/screenshots へ出力
#   ./scripts/capture-screens.sh -o /tmp/astra      出力先を指定
#   ./scripts/capture-screens.sh -d 'iPad Pro 11-inch (M4)'
#
# 環境変数:
#   MUSICFIN_SERVER    接続先 (既定: https://demo.jellyfin.org/stable)
#   MUSICFIN_USER      ユーザー名 (既定: demo)
#   MUSICFIN_PASSWORD  パスワード (既定: 空)

set -euo pipefail

OUT="out/screenshots"
DEVICE="iPhone 17 Pro"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)    OUT="${2:?}"; shift 2 ;;
    -d|--device) DEVICE="${2:?}"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "不明な引数: $1" ;;
  esac
done

cd "$ROOT"
RESULT="$(mktemp -d)/result.xcresult"
mkdir -p "$OUT"

echo "撮影中: $DEVICE"
# テストの成否ではなく撮れた枚数で判断するため、失敗しても後続へ進む。
xcodebuild test \
  -project Musicfin.xcodeproj \
  -scheme Musicfin \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath .build \
  -resultBundlePath "$RESULT" \
  MUSICFIN_SERVER="${MUSICFIN_SERVER:-}" \
  MUSICFIN_USER="${MUSICFIN_USER:-}" \
  MUSICFIN_PASSWORD="${MUSICFIN_PASSWORD:-}" \
  > /tmp/musicfin-capture.log 2>&1 || echo "  (テストは失敗しましたが、撮れた分を取り出します)"

STAGE="$(mktemp -d)"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$STAGE" >/dev/null 2>&1 \
  || die "結果バンドルから添付を取り出せませんでした。/tmp/musicfin-capture.log を確認してください。"

# manifest.json が添付名と実ファイル名の対応を持っている。
python3 - "$STAGE" "$OUT" <<'PY'
import json, pathlib, shutil, sys

stage, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
manifests = list(stage.rglob("manifest.json"))
copied = 0
for manifest in manifests:
    for entry in json.loads(manifest.read_text()):
        for att in entry.get("attachments", []):
            name = att.get("suggestedHumanReadableName") or att.get("exportedFileName")
            src = manifest.parent / att["exportedFileName"]
            if not src.exists() or not name:
                continue
            stem = pathlib.Path(name).stem
            shutil.copy2(src, out / f"{stem}.png")
            copied += 1
print(f"  {copied} 枚を {out} へ出力")
PY

ls -1 "$OUT" | sed 's/^/    /'
