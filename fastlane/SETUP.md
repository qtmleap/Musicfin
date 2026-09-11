# fastlane セットアップ手順

iOS アプリ `am.nasawake.Musicfin`（iPhone / iPad）を App Store Connect に配信する。

```sh
bundle install
bundle exec fastlane lanes
```

## lanes

| コマンド | 動作 | 危険度 |
|---|---|---|
| `fastlane setup_profiles` | Bundle ID 登録 + アプリレコード作成 + **match リポジトリへ書き込み**。初回のみ | **高**（他アプリと同居する署名資産を触る） |
| `fastlane verify` | 署名 + アーカイブのみ。アップロードしない | なし |
| `fastlane beta` | ビルド → TestFlight | 低（ASC 側で無効化できる） |
| `fastlane release` | ビルド → App Store。**審査には出さない** | 低 |
| `SUBMIT=1 fastlane release` | 上に加えて審査提出 | **高** |
| `fastlane upload_metadata` | `fastlane/metadata/` の説明文等だけ送る。ビルドしない | 中（ASC の入力を上書き） |
| `fastlane upload_screenshots` | `fastlane/screenshots/<locale>/` だけ送る。既存は上書き | 中 |

ビルド番号は TestFlight の最新値 +1 を自動で取り、`xcargs` でビルド時に注入する。
`project.pbxproj` は書き換わらないので git は常にクリーンなまま。

## 初回セットアップ

### 1. App Store Connect で API Key を発行

**ユーザとアクセス → 統合 → App Store Connect API** でチームキーを生成する。
ロールは **App Manager**（Developer だと match が証明書を作れない）。

`AuthKey_XXXXXXXXXX.p8` は**再ダウンロードできない**ので必ず保管する。

```sh
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
```

同じ画面の **Issuer ID** と **Key ID** を控える。

### 2. .env を用意

```sh
cp fastlane/.env.example fastlane/.env
```

| キー | 値 |
|---|---|
| `ASC_KEY_ID` | API Key の Key ID |
| `ASC_ISSUER_ID` | API Key の Issuer ID |
| `ASC_KEY_FILEPATH` | `.p8` の絶対パス |
| `MATCH_PASSWORD` | `qtmleap/match` の暗号化パスフレーズ |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `echo -n "user:token" | base64`（private リポジトリ用） |

`fastlane/.env` は gitignore 済み。

### 3. Bundle ID・アプリレコード・プロファイルを作る

`qtmleap/match` には既に他アプリの署名資産が入っている。**書き込む前にバックアップを取る。**

```sh
git clone --mirror https://github.com/qtmleap/match /tmp/match-backup
```

疎通と復号だけ先に確認する（何も変更しない）。

```sh
bundle exec fastlane match appstore --readonly
```

Musicfin のプロファイルはまだ無いので「見つからない」エラーが正常。
パスフレーズを聞かれた時点でリポジトリへの接続と復号は成功している。

生成する。

```sh
bundle exec fastlane setup_profiles
```

**生成後は必ず目視確認すること:**
- `profiles/appstore/AppStore_am.nasawake.Musicfin.mobileprovision` が増えているか
- 既存の他アプリのプロファイル・証明書が上書き・削除されていないか

アプリレコードの自動作成に失敗したときは App Store Connect の **マイ App → +** で
**iOS / Musicfin / `am.nasawake.Musicfin`** を手動で作る。

### 4. 動作確認

```sh
bundle exec fastlane verify
```

生成された ipa を検証する。

```sh
unzip -o -q build/Musicfin.ipa -d /tmp/musicfin-ipa
codesign -dvvv /tmp/musicfin-ipa/Payload/Musicfin.app 2>&1 | grep -E "Authority|TeamIdentifier"
# → Apple Distribution / TeamIdentifier=5Q94QJ7G98

plutil -p /tmp/musicfin-ipa/Payload/Musicfin.app/Info.plist | grep -iE "CFBundleVersion|DTPlatformName"
# → CFBundleVersion が注入値（pbxproj の 1 ではない）、iphoneos が入っている
```

問題なければ `bundle exec fastlane beta`。

## CI（GitHub Actions）

`.github/workflows/deployment.yaml` が `bundle exec fastlane beta|release` を呼ぶ。
`.p8` はファイルとして置けないので、`ASC_KEY_CONTENT` に base64 で渡すと
`asc_api_key` が一時ファイルに書き出して使う（`ASC_KEY_FILEPATH` は不要）。

| GitHub Secret | 値 |
|---|---|
| `ASC_KEY_ID` | API Key の Key ID |
| `ASC_ISSUER_ID` | API Key の Issuer ID |
| `ASC_KEY_CONTENT` | `base64 -i AuthKey_XXXXXXXXXX.p8` の出力（改行なし） |
| `MATCH_PASSWORD` | `qtmleap/match` の暗号化パスフレーズ |
| `MATCH_GIT_TOKEN` | `qtmleap/match` を読める PAT。ワークフロー側で `MATCH_GIT_BASIC_AUTHORIZATION` に変換する |

## 審査に出す前に必要なもの

App Store Connect 側で以下を埋めていないと `release` lane が失敗する。

- 輸出コンプライアンス（`ITSAppUsesNonExemptEncryption = false` を Info.plist に入れてある）
- 年齢制限
- プライバシーポリシー URL（`fastlane/metadata/*/privacy_url.txt` は空。決まったら埋めて `upload_metadata`）
- サポート URL（同上 `support_url.txt`）
- スクリーンショット（`release` は `skip_screenshots: true`。`upload_screenshots` で別送）

## 設計メモ

**署名は pbxproj を変えず一時的に上書きする。**
match は Manual signing 前提だが、それが必要なのは archive のときだけ。
pbxproj を Manual に固定すると日常の Xcode 開発で署名エラーが出る。
`build_for_appstore` は pbxproj をバックアップ → app target だけ Manual に書き換え → build →
`ensure` で丸ごと復元する。build が落ちても pbxproj は汚れない。

**ビルド番号に agvtool を使わない。**
このプロジェクトは `VERSIONING_SYSTEM` 未設定かつ `GENERATE_INFOPLIST_FILE = YES` で、
`Config/Info.plist` に `CFBundleVersion` を書いていない。`CURRENT_PROJECT_VERSION` を
xcargs で渡し、生成される Info.plist に反映させる方式にしている。

**lane 内の `match` は常に `readonly: true`。**
証明書の再発行は他アプリの署名を巻き添えに壊すため、lane からは起きないようにしてある。
書き込みは `setup_profiles` だけ。
