#!/usr/bin/env bash
#
# orchestrator / agent / codex の 3 エージェントを 1 画面に並べた tmux セッションを起動する。
#
#   ┌──────────────┬──────────────┐
#   │              │ agent        │  Claude Code（実装担当, .claude/agents/implementer.md）
#   │ orchestrator ├──────────────┤
#   │              │ codex        │  Codex gpt-6-astra（AGENTS.md を読む）
#   └──────────────┴──────────────┘
#     Claude Code（司令塔, .claude/agents/orchestrator.md）
#
# すでに同名のセッションがあれば、作り直さずにアタッチする。
#
# 環境変数:
#   MUSICFIN_TMUX_SESSION   セッション名                     (既定: musicfin)
#   ORCHESTRATOR_MODEL      orchestrator の claude モデル     (既定: エージェント定義に従う)
#   AGENT_MODEL             agent の claude モデル            (既定: エージェント定義に従う)
#   CODEX_MODEL             codex に渡すモデル                (既定: gpt-6-astra)
#   CODEX_ARGS              codex に渡す引数                  (既定: --dangerously-bypass-approvals-and-sandbox)
#   CLAUDE_ARGS             両方の claude に渡す引数          (既定: --dangerously-skip-permissions)
#
# 承認プロンプトを出さないよう、既定で claude / codex とも権限チェックを全て外している。
# 外したくないときは CLAUDE_ARGS= / CODEX_ARGS= のように空を渡す（${VAR-default} なので
# 「未設定」のときだけ既定が入る）。

set -euo pipefail

SESSION="${MUSICFIN_TMUX_SESSION:-musicfin}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
CODEX_ARGS="${CODEX_ARGS---dangerously-bypass-approvals-and-sandbox}"
CLAUDE_ARGS="${CLAUDE_ARGS---dangerously-skip-permissions}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v tmux   >/dev/null 2>&1 || die "tmux が見つかりません。'brew install tmux' でインストールしてください。"
command -v claude >/dev/null 2>&1 || die "claude が見つかりません。"
command -v codex  >/dev/null 2>&1 || die "codex が見つかりません。"
[[ -f "$ROOT/.claude/agents/orchestrator.md" && -f "$ROOT/.claude/agents/implementer.md" ]] \
  || die ".claude/agents/ にエージェント定義がありません。"

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "既存のセッション '$SESSION' にアタッチします。"
  exec tmux attach-session -t "=$SESSION"
fi

# ─── 各ペインで実行するコマンド ────────────────────────────────────────
model_flag() { [[ -n "${1:-}" ]] && printf -- '--model %q ' "$1"; return 0; }
ORCH_CMD="claude --agent orchestrator --name orchestrator $(model_flag "${ORCHESTRATOR_MODEL:-}")${CLAUDE_ARGS}"
AGENT_CMD="claude --agent implementer --name agent $(model_flag "${AGENT_MODEL:-}")${CLAUDE_ARGS}"
CODEX_CMD="codex --model ${CODEX_MODEL} ${CODEX_ARGS}"

# ─── セッションを組み立てる ────────────────────────────────────────────
tmux new-session -d -s "$SESSION" -c "$ROOT" -n dev
tmux split-window -h -t "$SESSION:dev" -c "$ROOT"      # 右列
tmux split-window -v -t "$SESSION:dev.1" -c "$ROOT"    # 右列を上下に

# TUI が pane_title を書き換えても役割を引けるよう、ペイン変数に役割を持たせる。
# ask-agent.sh はこの @role で送信先を決める。
i=0
for role in orchestrator agent codex; do
  tmux set-option -p -t "$SESSION:dev.$i" @role "$role"
  tmux select-pane -t "$SESSION:dev.$i" -T "$role"
  i=$((i + 1))
done

tmux set-option -t "$SESSION" -g pane-border-status top
tmux set-option -t "$SESSION" -g pane-border-format ' #{@role} '
# ask-agent.sh が過去の応答を読み取れるよう、スクロールバックを厚めに取る。
tmux set-option -t "$SESSION" -g history-limit 50000
tmux set-option -t "$SESSION" -g mouse on

tmux send-keys -t "$SESSION:dev.0" "$ORCH_CMD" C-m
tmux send-keys -t "$SESSION:dev.1" "$AGENT_CMD" C-m
tmux send-keys -t "$SESSION:dev.2" "$CODEX_CMD" C-m

tmux select-pane -t "$SESSION:dev.0"

cat <<MSG
tmux セッション '$SESSION' を起動しました。

  左   : orchestrator  $ORCH_CMD
  右上 : agent         $AGENT_CMD
  右下 : codex         $CODEX_CMD

  ペイン移動      Ctrl-b → 矢印
  デタッチ        Ctrl-b → d
  再アタッチ      tmux attach -t $SESSION
  終了            tmux kill-session -t $SESSION

  ペインへ指示を送る:
    ./scripts/ask-agent.sh agent "実装して" 
    ./scripts/ask-agent.sh codex -f docs/ui-consult-prompt.md -w 120
    ./scripts/ask-agent.sh agent --read
MSG

exec tmux attach-session -t "=$SESSION"
