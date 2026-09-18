#!/bin/zsh
set -e

sudo chown -R $(whoami):$(whoami) .build 2>/dev/null || true

# Silence direnv output.
# In direnv 2.36+, DIRENV_LOG_FORMAT env var is ignored unless direnv.toml exists.
# See: https://github.com/direnv/direnv/issues/1418
mkdir -p ~/.config/direnv
cat > ~/.config/direnv/direnv.toml <<'EOF'
[global]
log_format = ""
hide_env_diff = true
EOF

# Resolve SPM dependencies if the project has a package manifest of its own.
# Packages that depend on the tvOS SDK will not resolve here; that is expected.
if [ -f Package.swift ]; then
  swift package resolve || true
fi

# ../KotatsuCore は compose.yaml がホストから bind mount している。中身が無いのは
# ホスト側に clone されていないということで、その場合 Xcode も同じ理由でパッケージを
# 解決できない。ここで clone するとマウント越しにホストを書き換えることになるので、
# 直し方だけ知らせて手を出さない。
if [ ! -d ../KotatsuCore/.git ]; then
  printf '\033[33mwarning:\033[0m ../KotatsuCore が空です。ホスト側で以下を実行してください:\n'
  printf '  git clone https://github.com/qtmleap/KotatsuCore.git %s\n' \
    "$(dirname "$PWD")/KotatsuCore"
fi

git config --global --add safe.directory /home/vscode/KotatsuCore

# Playwright MCP は実物の Chromium を動かすが、ブラウザ本体もその system 依存も
# イメージには入っていないので、ここで入れておかないと最初の `browser_navigate` が
# `Browser "chromium" is not installed` で落ちる。MCP は自前の Playwright を抱えて
# いて devDependency の `playwright` とは別の revision を期待するため、
# `playwright install` ではなく MCP の CLI から入れる。
if [ -f playwright-mcp.config.json ]; then
  bunx @playwright/mcp install-browser --with-deps chromium
fi
