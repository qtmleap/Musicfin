# fastlane セットアップ手順

iOS アプリ `jp.qleap.musicfin`（iPhone / iPad）を App Store Connect に配信する。

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
| `fastlane notify_testers` | アップロード済みビルドについてテスターへ通知を送る。ビルドしない | 中（テスターに通知が飛ぶ） |
| `fastlane notify_testers dry_run:true` | 対象の特定とログ出力だけ。通知は送らない | なし |
| `fastlane set_test_info feedback_email:…` | アプリ単位のテスト情報 (ja) を書き込む。ビルドしない | 中（ASC の入力を上書き） |
| `fastlane set_whats_new` | アップロード済みビルドの「テスト内容」(ja) を書き込む。ビルドしない | 中（ASC の入力を上書き） |
| `fastlane invite_testers` | 未招待テスターへ TestFlight の招待を送る。ビルドしない | 中（テスターにメールが飛ぶ） |
| `fastlane invite_testers dry_run:true` | 未招待テスターを数えるだけ。何も送らない | なし |
| `fastlane diagnose_testflight` | 配信状況（グループ・テスター・処理状態・テスト内容）を読み取って表示する。GET のみ | なし |
| `fastlane preview_whats_new` | TestFlight の「テスト内容」の生成結果を表示するだけ。何も送らない | なし |
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
- `profiles/appstore/AppStore_jp.qleap.musicfin.mobileprovision` が増えているか
- 既存の他アプリのプロファイル・証明書が上書き・削除されていないか

アプリレコードの自動作成に失敗したときは App Store Connect の **マイ App → +** で
**iOS / Musicfin / `jp.qleap.musicfin`** を手動で作る。

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

## 既存ビルドのテスター通知

内部テスターはグループへのビルド公開時に TestFlight が自動通知する。
`notify_testers` は「自動通知が届かなかった」「後からテスターを追加した」ときの手動通知手段で、
**ビルドもアップロードもしない**（既にアップロード済みのビルドが対象）。

```sh
# 対象を確認するだけ。何も送らない
bundle exec fastlane notify_testers version:1.0.0 build:12 dry_run:true
# 実際に送る
bundle exec fastlane notify_testers version:1.0.0 build:12
```

- `version` 省略時はプロジェクトの `MARKETING_VERSION`、`build` 省略時は
  そのバージョンの候補が 1 件のときだけ確定する。複数あるときは
  候補の番号を並べて止まるので `build:` で指定する。該当 0 件でも止まる。
- 送信前にアプリ名・バージョン・ビルド番号・ビルド ID・処理状態をログに出す。
- 処理状態が `VALID` でなければ送らない（`PROCESSING` は待てば解決、`FAILED` / `INVALID` は解決しない）。
- 通知先は「そのビルドに割り当て済みで受け取る資格のあるテスター全員」。
  App Store Connect API にグループを指定する余地は無いので、グループ引数も用意していない。
  外部テスターへの通知は Beta App Review 承認後になる。
- `What to Test` の文面はこの lane では更新しない（`beta` が設定したものを維持）。
- 実装は `POST /v1/buildBetaNotifications`。spaceship に専用メソッドが無いため、
  認証済みの `Spaceship::ConnectAPI.test_flight_request_client` から直接叩いている
  （JWT を自作しない）。純ロジックは `fastlane/lib/tester_notification.rb`、
  検証は `ruby fastlane/test/tester_notification_test.rb`。

## テスト情報 → テスト内容 → 招待 の順で整える

TestFlight は「アプリ単位のテスト情報 (betaAppLocalizations)」が空のままだと
テスターへの配信・招待が進まない。既存ビルドを配る手順は必ずこの順で行う。

```sh
# 1. アプリ単位のテスト情報 (ja)。feedbackEmail は必須なので必ず渡す
bundle exec fastlane set_test_info feedback_email:you@example.com
# 2. ビルド単位のテスト内容 (whatsNew)
bundle exec fastlane set_whats_new version:0.1.0 build:1
# 3. 未招待テスターへの招待
bundle exec fastlane invite_testers
```

`set_test_info` の本文は `fastlane/testflight/ja/description.txt`。
`feedback_email:` 省略時は環境変数 `TESTFLIGHT_FEEDBACK_EMAIL` を見る。
どちらも無いまま API が feedbackEmail 必須で弾いた場合は、アドレスを推測せずに
API の応答をそのまま出して止まる（誤ったアドレスがテスターに表示されるのを防ぐため）。

## 既存ビルドの「テスト内容」を後から書き込む

`beta` を経由せずにアップロードしたビルドには `betaBuildLocalizations` が無い。
TestFlight は「テスト内容」が空のビルドをテスターへ出し渋るので、後から入れる。

```sh
# Git コミットから自動生成した文面を入れる
bundle exec fastlane set_whats_new version:0.1.0 build:1
# 文面を直接指定する
bundle exec fastlane set_whats_new version:0.1.0 build:1 text:"初回配信です"
```

対象ビルドの決め方は `notify_testers` と同じ（`resolve_build` を共有）。
ja が未作成なら `POST`、あれば `PATCH` で更新し、直後に `GET` で読み直してログに出す。

## 未招待テスターへの招待

`state` が `NOT_INVITED` のテスターはグループに入っていてもメールを受け取っていない。
この lane はそのテスターだけを対象に招待を送る。**ビルドもアップロードもしない**。

```sh
bundle exec fastlane invite_testers dry_run:true   # 数えるだけ
bundle exec fastlane invite_testers                # 実際に送る
```

- `POST /v1/betaTesterInvitations` を使い、拒否された場合のみグループからの
  削除 → 再追加にフォールバックする（どちらを使ったかはログに出る）。
- テスターの `state` は spaceship のモデルが拾わない（API は `state`、モデルは
  `betaTesterState` を見ている）ため、`v1/betaTesters` の生 JSON を読んでいる。
- 送信後に `GET` で読み直して `state` を出す。

### 通知が届かないときの診断

```sh
bundle exec fastlane diagnose_testflight version:0.1.0 build:1
```

ビルドの処理状態・輸出コンプライアンス・有効期限、紐づくベータグループ、
グループごとのテスター（`state` が `NOT_INVITED` / `INVITED` / `ACCEPTED` / `INSTALLED`）、
個別テスター、`betaBuildLocalizations` を一覧する。**GET しか呼ばない**ので実行しても何も変わらない。

`notify_testers` が `Auto-notify already enabled` で拒否されるのは、そのビルドの
`autoNotifyEnabled` が true で Apple 側の自動通知に委ねられているため。この場合は
手動通知 API を使う余地が無いので、テスターの `state` を疑う。

## TestFlight の「テスト内容」(What to Test)

`beta` lane は Git のコミット件名から日本語のテストノートを組み立て、
`upload_to_testflight` の `localized_build_info` で ja ロケールに設定する。
外部 AI API は使わない。整形ロジックは `fastlane/lib/testflight_notes.rb`。

- **範囲**: 直近の祖先タグ `vX.Y.Z` の次から `HEAD` まで。該当タグが無ければ全履歴。
  マージコミットは除外し、新しい順に最大 10 件。
- **採用する type**: `feat` / `fix` / `perf` を優先。1 件も無いときだけ他の Conventional Commits
  （`ui` / `refactor` / `build` など）も拾って空欄を避ける。
- **整形**: `type(scope)!:` と末尾の `(#123)` を落とし、`- 新機能: 〜` の形にする。重複件名は 1 つに畳む。
  コミット本文・SHA・著者は載せない。
- **フォールバック**: Git を読めない、または採用できる件名が無いときは見出しと通常操作
  （ログイン・検索・再生・キュー）の確認依頼だけにする。
- **長さ**: UTF-8 4,000 バイト以内。超えるときは古い項目から落とし、1 項目でも収まらなければ
  文字境界で切って `…` を付ける。

プレビュー（何も送らない）:

```sh
bundle exec fastlane preview_whats_new
# fastlane を通さず素の Ruby でも見られる
ruby fastlane/lib/testflight_notes.rb
```

整形ロジックの検証:

```sh
ruby fastlane/test/testflight_notes_test.rb
```

`beta` はメタデータを書き込むために `skip_waiting_for_build_processing: false` にしてある
（ASC の処理完了まで待つ）。`skip_submission: true` は維持しているので配信は始まらない。

**浅い clone では履歴とタグが無いのでノートが空になる。** CI では次のように取り直す。

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # または: git fetch --prune --unshallow --tags
```

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
