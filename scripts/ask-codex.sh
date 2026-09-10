#!/usr/bin/env bash
#
# start-agents.sh で立てた tmux セッションの codex ペインへプロンプトを送り、
# 応答をそのまま読み取れるようにする。
#
# 使い方:
#   ./scripts/ask-codex.sh "この設計どう思う？"      引数の文字列を送る
#   ./scripts/ask-codex.sh -f docs-ui-consult.md     ファイルの中身を送る
#   cat notes.md | ./scripts/ask-codex.sh -          標準入力から送る
#   ./scripts/ask-codex.sh --read                    送らずに現在の内容だけ読む
#
# オプション:
#   -f, --file FILE   FILE の内容を送る
#   -r, --read        送信せず codex ペインの内容を出力する
#   -w, --wait SEC    送信後 SEC 秒待ってからペインの内容を出力する (既定: 0 = 待たない)
#   -n, --lines N     読み取る行数 (既定: 200)
#
# 複数行のプロンプトは tmux のバッファ経由で「貼り付け」として送る。
# 1 行ずつ send-keys すると改行のたびに送信が確定してしまうため。

set -euo pipefail

SESSION="${MUSICFIN_TMUX_SESSION:-musicfin}"
BUFFER="musicfin-ask"
WAIT=0
LINES=200
MODE="send"
PROMPT=""

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)  [[ -r "${2:-}" ]] || die "ファイルを読めません: ${2:-（未指定）}"
                PROMPT="$(cat "$2")"; shift 2 ;;
    -r|--read)  MODE="read"; shift ;;
    -w|--wait)  WAIT="${2:?}"; shift 2 ;;
    -n|--lines) LINES="${2:?}"; shift 2 ;;
    -)          PROMPT="$(cat)"; shift ;;
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          PROMPT="$1"; shift ;;
  esac
done

command -v tmux >/dev/null 2>&1 || die "tmux が見つかりません。"
tmux has-session -t "=$SESSION" 2>/dev/null \
  || die "セッション '$SESSION' がありません。先に ./scripts/start-agents.sh を実行してください。"

# codex ペインを特定する。TUI は起動後に pane_title を自分で書き換えてしまうため、
# 実行中のコマンド名を第一の手がかりにする。
find_pane() {
  local fmt="$1" match="$2"
  tmux list-panes -t "=$SESSION" -F "#{pane_id} ${fmt}" \
    | awk -v m="$match" '$2 == m { print $1; exit }'
}

TARGET="$(find_pane '#{pane_current_command}' codex)"
[[ -n "$TARGET" ]] || TARGET="$(find_pane '#{pane_title}' codex)"
# それでも決まらなければ、claude ではない方のペインを使う。
[[ -n "$TARGET" ]] || TARGET="$(tmux list-panes -t "=$SESSION" \
  -F '#{pane_id} #{pane_current_command}' | awk '$2 != "claude" { print $1; exit }')"
[[ -n "$TARGET" ]] || die "codex ペインが見つかりません。tmux list-panes -a で確認してください。"

read_pane() {
  tmux capture-pane -p -J -t "$TARGET" -S "-${LINES}"
}

if [[ "$MODE" == "read" ]]; then
  read_pane
  exit 0
fi

[[ -n "$PROMPT" ]] || die "送信する内容がありません。文字列か -f FILE を指定してください。"

# bracketed paste (-p) で貼り付けると、改行を含んでいても 1 回の入力として扱われる。
printf '%s' "$PROMPT" | tmux load-buffer -b "$BUFFER" -
tmux paste-buffer -b "$BUFFER" -t "$TARGET" -p -d
sleep 0.3
tmux send-keys -t "$TARGET" Enter

echo "codex ペイン ($TARGET) に送信しました。" >&2

if [[ "$WAIT" != "0" ]]; then
  sleep "$WAIT"
  echo "--- codex ペインの内容 ---" >&2
  read_pane
fi
