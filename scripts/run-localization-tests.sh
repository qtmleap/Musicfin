#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 言語設定と翻訳リソースを本番と同じ Bundle で読み、ホストの設定には触れない。
localization_dir=$(mktemp -d "${TMPDIR:-/tmp}/musicfin-localization.XXXXXX")
trap 'rm -rf "$localization_dir"' EXIT
localization_app="$localization_dir/LocalizationTests.app"
mkdir -p "$localization_app/Contents/MacOS" "$localization_app/Contents/Resources"
cp -R Musicfin/Resources/en.lproj Musicfin/Resources/ja.lproj "$localization_app/Contents/Resources/"
cat > "$localization_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>localization-tests</string>
<key>CFBundleIdentifier</key><string>jp.qleap.musicfin.localization-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 6 \
  Musicfin/Core/Jellyfin/JellyfinModels.swift \
  Musicfin/Core/Jellyfin/JellyfinCoding.swift \
  Musicfin/Core/Jellyfin/JellyfinClient.swift \
  Musicfin/Core/Jellyfin/JellyfinClient+URLs.swift \
  Musicfin/Core/Settings/StreamQuality.swift \
  Tests/LocalizationTests.swift -o "$localization_app/Contents/MacOS/localization-tests"
"$localization_app/Contents/MacOS/localization-tests" en -AppleLanguages '(en)' -AppleLocale en_US
"$localization_app/Contents/MacOS/localization-tests" ja -AppleLanguages '(ja)' -AppleLocale ja_JP
