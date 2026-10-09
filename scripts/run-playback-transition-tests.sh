#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 実際の AVQueuePlayer を使い、ネットワーク・音声経路・ロック画面への公開だけを隔離する。
playback_dir=$(mktemp -d "${TMPDIR:-/tmp}/musicfin-playback.XXXXXX")
trap 'rm -rf "$playback_dir"' EXIT
python3 - "$playback_dir" <<'PYTHON'
import pathlib, sys, wave
with wave.open(str(pathlib.Path(sys.argv[1]) / "track.wav"), "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(44100)
    audio.writeframes(bytes(44100 * 2))
PYTHON
xcrun swiftc -parse-as-library -swift-version 6 \
  Musicfin/Core/Jellyfin/JellyfinModels.swift Musicfin/Core/ObserverBox.swift \
  Musicfin/Core/Settings/StreamQuality.swift Musicfin/Core/Settings/PlaybackSettings.swift \
  Musicfin/Player/PlaybackQueueOrder.swift Musicfin/Player/PlaybackAdvance.swift Musicfin/Player/PlaybackEngine.swift \
  Tests/PlaybackEngineFixtures.swift Tests/PlaybackEngineTransitionTests.swift \
  -o "$playback_dir/transition-tests"
"$playback_dir/transition-tests" "$playback_dir"
