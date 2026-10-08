#!/usr/bin/env bash
# UI test の atomic request を native Simulator screenshot と atomic ack に変換する。
# 実機(Mac Studio)は Node 程度しか入っておらず、この薄いブリッジのためだけに Python
# ランタイムを用意するのは過剰なので、macOS 標準コマンドだけで完結する bash に寄せる。
set -euo pipefail

bridge=""
output=""
udid=""
width=""
height=""
while [ $# -gt 0 ]; do
    case "$1" in
    --bridge) bridge="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --udid) udid="$2"; shift 2 ;;
    --width) width="$2"; shift 2 ;;
    --height) height="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$bridge" ] || [ -z "$output" ] || [ -z "$udid" ] || [ -z "$width" ] || [ -z "$height" ]; then
    echo "usage: $0 --bridge DIR --output DIR --udid UDID --width N --height N" >&2
    exit 2
fi
mkdir -p "$bridge" "$output"

# GNU coreutils の timeout が無いので、0.1 秒間隔でポーリングして自前で強制終了する。
run_with_timeout() {
    local limit_seconds="$1" errfile="$2"
    shift 2
    "$@" >/dev/null 2>>"$errfile" &
    local pid=$! elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$elapsed" -ge $((limit_seconds * 10)) ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            echo "timed out after ${limit_seconds}s: $*" >>"$errfile"
            return 124
        fi
        sleep 0.1
        elapsed=$((elapsed + 1))
    done
    wait "$pid"
}

# 手でPNGヘッダを読むより、既にこのスクリプトが前提としている sips の出力をそのまま使う方が素直。
png_size() {
    local file="$1" w h
    w="$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    h="$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
    if [ -z "$w" ] || [ -z "$h" ]; then
        return 1
    fi
    printf '%s %s\n' "$w" "$h"
}

process_request() {
    local request="$1"
    local screen temporary final ack_tmp ack error_file errfile
    local w="" h="" ok=1
    screen="$(basename "$request" .request)"
    temporary="$output/.$screen.native.tmp.png"
    final="$output/$screen.png"
    ack_tmp="$bridge/.$screen.ack.tmp"
    ack="$bridge/$screen.ack"
    error_file="$bridge/$screen.error"
    errfile="$(mktemp)"

    if ! run_with_timeout 15 "$errfile" xcrun simctl io "$udid" screenshot --type=png "$temporary"; then
        ok=0
    fi

    if [ "$ok" -eq 1 ] && ! read -r w h < <(png_size "$temporary"); then
        echo "output is not PNG" >>"$errfile"
        ok=0
    fi

    if [ "$ok" -eq 1 ] && [ "$w" = "$height" ] && [ "$h" = "$width" ]; then
        # iPad の framebuffer は scene が landscape でも物理 portrait 配列で返るため、
        # native pixels を host 側で向きだけ焼き込み、比較器へ自然寸法で渡す。
        if run_with_timeout 15 "$errfile" sips --rotate -90 "$temporary"; then
            if ! read -r w h < <(png_size "$temporary"); then
                echo "output is not PNG after rotate" >>"$errfile"
                ok=0
            fi
        else
            ok=0
        fi
    fi

    if [ "$ok" -eq 1 ] && { [ "$w" != "$width" ] || [ "$h" != "$height" ]; }; then
        echo "expected ${width}x${height}, got ${w}x${h}" >>"$errfile"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        if mv -f -- "$temporary" "$final" 2>>"$errfile"; then
            printf 'captured %sx%s\n' "$w" "$h" >"$ack_tmp"
            if ! mv -f -- "$ack_tmp" "$ack" 2>>"$errfile"; then
                ok=0
            fi
        else
            ok=0
        fi
    fi

    if [ "$ok" -ne 1 ]; then
        cat "$errfile" >"$error_file" 2>/dev/null || echo "unknown error" >"$error_file"
    fi

    rm -f -- "$errfile" "$request" "$temporary"
}

while true; do
    shopt -s nullglob
    requests=("$bridge"/*.request)
    shopt -u nullglob
    if [ ${#requests[@]} -eq 0 ]; then
        # macOS の /bin/sleep は BSD 由来で strtod により小数秒を解釈できるため、
        # Python 版と同じ 25ms ポーリング間隔をそのまま使う。
        sleep 0.025
        continue
    fi
    sorted=()
    while IFS= read -r line; do
        sorted+=("$line")
    done < <(printf '%s\n' "${requests[@]}" | sort)
    for request in "${sorted[@]}"; do
        [ -e "$request" ] || continue
        process_request "$request"
    done
done
