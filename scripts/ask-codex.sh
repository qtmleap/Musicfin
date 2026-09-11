#!/usr/bin/env bash
# 互換用: ask-agent.sh codex への薄いラッパー。
exec "$(dirname "${BASH_SOURCE[0]}")/ask-agent.sh" codex "$@"
