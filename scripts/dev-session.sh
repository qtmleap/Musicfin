#!/usr/bin/env bash
#
# Claude Code と Codex を 1 画面に並べた tmux セッションを起動する。
#
#   左ペイン: claude   右ペイン: codex
#
# すでに同名のセッションがあれば、作り直さずにアタッチする。
#
# 環境変数:
#   MUSICFIN_TMUX_SESSION  セッション名           (既定: musicfin)
#   CODEX_MODEL            codex に渡すモデル     (既定: gpt-6-astra)
#   MUSICFIN_SPLIT         分割方向 h|v           (既定: h)

set -euo pipefail

SESSION="${MUSICFIN_TMUX_SESSION:-musicfin}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
SPLIT="${MUSICFIN_SPLIT:-h}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v tmux  >/dev/null 2>&1 || die "tmux が見つかりません。'brew install tmux' でインストールしてください。"
command -v claude >/dev/null 2>&1 || die "claude が見つかりません。"
command -v codex  >/dev/null 2>&1 || die "codex が見つかりません。"

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "既存のセッション '$SESSION' にアタッチします。"
  exec tmux attach-session -t "=$SESSION"
fi

# ─── セッションを組み立てる ────────────────────────────────────────────
tmux new-session -d -s "$SESSION" -c "$ROOT" -n dev

case "$SPLIT" in
  h) tmux split-window -h -t "$SESSION:dev" -c "$ROOT" ;;
  v) tmux split-window -v -t "$SESSION:dev" -c "$ROOT" ;;
  *) die "MUSICFIN_SPLIT は h か v を指定してください（指定値: $SPLIT）" ;;
esac

# ask-codex.sh がペインを名前で特定できるようにタイトルを付ける。
tmux select-pane -t "$SESSION:dev.0" -T claude
tmux select-pane -t "$SESSION:dev.1" -T codex

tmux set-option -t "$SESSION" -g pane-border-status top
tmux set-option -t "$SESSION" -g pane-border-format ' #{pane_title} '
# ask-codex.sh が過去の応答を読み取れるよう、スクロールバックを厚めに取る。
tmux set-option -t "$SESSION" -g history-limit 50000
tmux set-option -t "$SESSION" -g mouse on

tmux send-keys -t "$SESSION:dev.0" 'claude' C-m
tmux send-keys -t "$SESSION:dev.1" "codex --model ${CODEX_MODEL}" C-m

tmux select-pane -t "$SESSION:dev.0"

cat <<EOF
tmux セッション '$SESSION' を起動しました。

  左: claude    右: codex (--model ${CODEX_MODEL})

  ペイン移動      Ctrl-b → ←/→
  デタッチ        Ctrl-b → d
  再アタッチ      tmux attach -t $SESSION
  終了            tmux kill-session -t $SESSION

  Codex へ質問を投げる:
    ./scripts/ask-codex.sh "質問文"
    ./scripts/ask-codex.sh -f docs-ui-consult.md
EOF

exec tmux attach-session -t "=$SESSION"
