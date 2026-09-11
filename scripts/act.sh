#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: scripts/act.sh [--host] [job] [act options...]

引数なし: commitlint / shellcheck / actionlint を Ubuntu コンテナで順に実行。
ジョブ指定: scripts/act.sh shellcheck
macOS: scripts/act.sh --host unit-tests （format / build も指定可能）
--host は macos-26=-self-hosted マッピングで手元の macOS / Xcode を使います。
追加の act オプションはジョブ名の後に指定できます（例: shellcheck --dryrun）。
HELP
}

cd "$(dirname "$0")/.."
use_host=false
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if [[ ${1:-} == --host ]]; then
  use_host=true
  shift
fi
if [[ $# -eq 0 ]]; then
  if $use_host; then
    usage >&2
    exit 2
  fi
  # デプロイや自動レビューを誤って起動しないよう、Integration の検査だけに限定する。
  status=0
  for job in commitlint shellcheck actionlint; do
    act push -W .github/workflows/integration.yaml -j "$job" || status=1
  done
  exit "$status"
fi
job=$1
shift
case "$job" in
  commitlint|shellcheck|actionlint) ;;
  format|build|unit-tests)
    if ! $use_host; then
      echo "macOS ジョブには --host を指定してください。" >&2
      exit 2
    fi
    if [[ $(uname -s) != Darwin ]]; then
      echo "macOS ジョブは macOS ホストで実行してください。" >&2
      exit 2
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac
if $use_host; then
  exec act push -W .github/workflows/integration.yaml -j "$job" -P macos-26=-self-hosted "$@"
fi
exec act push -W .github/workflows/integration.yaml -j "$job" "$@"
