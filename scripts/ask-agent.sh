#!/usr/bin/env bash
#
# start-agents.sh で立てた tmux セッションの指定ペインへプロンプトを送り、
# 応答をそのまま読み取れるようにする。
#
# 使い方:
#   ./scripts/ask-agent.sh agent "この画面を実装して"       引数の文字列を送る
#   ./scripts/ask-agent.sh codex -f docs/ui-consult-prompt.md  ファイルの中身を送る
#   cat notes.md | ./scripts/ask-agent.sh orchestrator -    標準入力から送る
#   ./scripts/ask-agent.sh agent --read                     送らずに現在の内容だけ読む
#
# 送信先: orchestrator | agent | codex
#
# オプション:
#   -f, --file FILE   FILE の内容を送る
#   -r, --read        送信せずペインの内容を出力する
#   -w, --wait SEC    送信後 SEC 秒待ってからペインの内容を出力する (既定: 0 = 待たない)
#   -n, --lines N     読み取る行数 (既定: 200)
#
# 複数行のプロンプトは tmux のバッファ経由で「貼り付け」として送る。
# 1 行ずつ send-keys すると改行のたびに送信が確定してしまうため。

set -euo pipefail

SESSION="${MUSICFIN_TMUX_SESSION:-musicfin}"
WAIT=0
LINES=200
MODE="send"
PROMPT=""
ROLE=""

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)  [[ -r "${2:-}" ]] || die "ファイルを読めません: ${2:-（未指定）}"
                PROMPT="$(cat "$2")"; shift 2 ;;
    -r|--read)  MODE="read"; shift ;;
    -w|--wait)  WAIT="${2:?}"; shift 2 ;;
    -n|--lines) LINES="${2:?}"; shift 2 ;;
    -)          PROMPT="$(cat)"; shift ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    orchestrator|agent|codex)
                [[ -z "$ROLE" ]] || die "送信先は 1 つだけ指定してください。"
                ROLE="$1"; shift ;;
    *)          PROMPT="$1"; shift ;;
  esac
done

[[ -n "$ROLE" ]] || die "送信先 (orchestrator | agent | codex) を指定してください。"
command -v tmux >/dev/null 2>&1 || die "tmux が見つかりません。"
tmux has-session -t "=$SESSION" 2>/dev/null \
  || die "セッション '$SESSION' がありません。先に ./scripts/start-agents.sh を実行してください。"

# start-agents.sh がペインに付けた @role で送信先を決める。
# TUI は pane_title を自分で書き換えるので、タイトルは当てにしない。
TARGET="$(tmux list-panes -t "=$SESSION" -F '#{pane_id} #{@role}' \
  | awk -v r="$ROLE" '$2 == r { print $1; exit }')"
[[ -n "$TARGET" ]] || die "'$ROLE' のペインが見つかりません。tmux list-panes -a -F '#{pane_id} #{@role}' で確認してください。"

BUFFER="musicfin-ask-$ROLE"

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

echo "$ROLE ペイン ($TARGET) に送信しました。" >&2

if [[ "$WAIT" != "0" ]]; then
  sleep "$WAIT"
  echo "--- $ROLE ペインの内容 ---" >&2
  read_pane
fi
