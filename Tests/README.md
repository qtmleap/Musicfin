# アプリの単体回帰テスト

macOS の Swift コンパイラで実行する。ローカルと CI は同じスクリプトを使う。

```sh
./scripts/run-unit-tests.sh
```

ページ取得・ジャンル集約・重複要求防止・失敗後の再試行と一覧保持を検証する。アプリのテストターゲットやサーバーは不要。

アートワークは UIKit 非依存のキャッシュを同じスクリプトで検証する。同時要求の共有、
再生成後のディスク再利用、破損復旧、画像タグ・サーバー・認証の分離、共有取得での一時 HTTP / 通信失敗の限定再試行、
EXIF の回転・反転、画像検証、保存容量上限、先読み同時数、表示優先、共有取得のキャンセル耐性、取消済みの未着手先読みの除去を対象とする。通信は注入した応答で制御し、実サーバーや Simulator は使わない。

歌詞の前奏は、点灯の順序・拡縮・歌い出しでの退場と、一時停止・シーク・再生位置の更新が止まったときの時計を検証する。
Simulator の歌詞テストでは、実際に描画されたドットの変化と、一時停止で静止することを別に確かめる。

歌詞送りは現在行の即応、下の行の遅れ、最後の位置への追いつき、短い行が続くときの連続性とシークの区別を検証する。
Simulator では自然な行送り・手動の読み戻し・現在行が見えたときの復帰・前奏への戻りを確認し、行ごとの動きは録画で見比べる。

歌詞の操作帯は、実指と慣性の所有、器の伸縮に伴う位置補正、指の反転とスクロール幅のない歌詞を検証する。
追従は現在行が画面外にある間の読み位置の維持、指と慣性が止まってからの再取得、前奏と過去・未来行のぼかしを検証する。

曲と Home の一覧は、100 件を越える継続取得・重複を含む応答の取得位置・取消・アカウント変更時の応答破棄を検証する。Radio は種の切り替え・重複除去・失敗した種の再試行・終端を検証する。

ローカライズは一時的なアプリ Bundle に本番の翻訳リソースを入れ、英語・日本語の独立プロセスで検証する。
前奏・ロスレス・複数アーティストの区切り、不正日付の診断、エラー概要と内部原因の保持を対象にする。
`bash scripts/run-localization-tests.sh` で個別実行でき、ホストの言語設定や Simulator は使わない。

再生順と曲末の先読み判定は通常の単体スイートで検証する。
`bash scripts/run-playback-transition-tests.sh` は無音の短い音声と本番の AVQueuePlayer・再生エンジンを使い、
先読み遅延、食い違う先読み、重複曲、一曲リピート、古い終了通知で音声と表示用メタデータが一致することを確認する。
この実再生検証は macOS の再生クロックを使う。音量は 0 で、ネットワーク・iOS の音声経路・ロック画面への公開はテスト用の受け口に差し替える。

Home の iPad アルバム遷移は、UI テスト `testPadHomeAlbumKeepsMiniPlayer` で長いドラッグと取消、戻る操作、再生操作を検証する。
`MUSICFIN_SHOT_DIR` に残った `album-overlay-*.jsonl` を `python3 Tests/check-album-overlay-trace.py <保存先>` で検証すると、
実際に描画された画像が同じまま、指を離したサイズから元の画像へ単調に縮み、直線上を移動して帰着したことを確かめられる。
帰着せずフェードだけで閉じた記録では成功にならない。取消で詳細へ戻るときの寸法も検証する。
`testPadAlbumOverlayScrollAndEntries` は文字を大きくして一覧を確実にスクロールできる状態にし、
先頭以外で始めた下スクロールが途中で終了操作へ変わらないことと、Home の 3 種類の入口を確認する。

iPad フルプレイヤーの終了領域は、通常表示・歌詞とキューの左列・狭い幅のヘッダー・シークと音量の除外枠を単体スイートで検証する。
`testPadFullPlayerDismissRegions` は実際の下スワイプ、左右をまたぐ操作、右本文、シーク始点の保護を確認する。
`testPadSidebarSingleTapTargets` は行のアイコンと空白を単押しし、再選択時のアルバム終了も確認する。
`testPadPlaylistSwitchReloadsShuffleSource` は API で確認した異なる曲を持つ 2 作品を切り替え、曲一覧・現在曲・キューに前の作品が混入しないことを検証する。

`testPadAccountKeepsSidebarWidth` は初回ログイン・ログイン済みの再起動とアカウントの提示中・表示中・終了後で、
メニュー幅が 269.5 pt のままかを検証する。2 回繰り返し、Home 行の位置と幅も確認する。
`testPadShuffledMiniPlayerControls` は実サーバーの作品をシャッフルし、ミニプレイヤーの一時停止・全画面への移動・
再生位置の保持・次曲送りを実際の座標タップで検証する。2 曲以上を持つ作品が必要。
`testPadMiniPlayerRightControls` は右端の「…」・歌詞・キューを中心座標で押し、メニューの表示・
最初のタップでの表示選択・通常の入口がアートワークへ戻ることと、曲が替わらないことを確認する。
同じテストで、アルバムからシャッフル開始後の選択表示、ミニ／フルプレイヤー間のオン・オフ反映、
通常再生での解除も確認する。ミニ側は記号の中心座標を押し、切替中も現在曲が変わらないことを検証する。
アカウントを開く途中の幅変化は、静止後の frame だけでは検出できないため録画でも確認する。
`TEST_RUNNER_MUSICFIN_REGRESSION_DEMO_VIDEO=1` を渡すと `testPadShuffledMiniPlayerControls` は
通常の再生操作検証の前に、シャッフル再生中の左下のアカウントを 3 回開閉する撮影経路を通る。
録画は静止フレームの間隔が一定とは限らない。変換で間引かず、全フレームの V 字と板の端を比較する。

これらは `xcodebuild test` の `-only-testing:MusicfinUITests/CaptureScreensUITests/<テスト名>` で個別に実行する。
`TEST_RUNNER_MUSICFIN_IPAD_CAPTURE=1` を渡し、所有する使い捨て端末の UDID を destination に指定する。
撮影用のスクリプトと同じ `TEST_RUNNER_MUSICFIN_SERVER_URL` / `TEST_RUNNER_MUSICFIN_USERNAME` / `TEST_RUNNER_MUSICFIN_PASSWORD` で接続先を指定できる。
追加の起動環境 `TEST_RUNNER_MUSICFIN_REGRESSION_PORTRAIT=1` は縦向き、
`TEST_RUNNER_MUSICFIN_REGRESSION_ACCOUNT_TOOLBAR=1` は Home 右上のアカウント、
`TEST_RUNNER_MUSICFIN_REGRESSION_PLAYLIST=1` は左メニューのプレイリストを対象にする。
開始前に既存端末を記録し、成功・失敗にかかわらず作成した端末を終了・削除する。結果バンドルのスクリーンショットは残す。

`testPadFullPlayerInteractiveDrag` は 40 pt の短い引きと 300 pt の引きを、それぞれ指を離す前に 2 秒保持する。
短い引きの復帰、長い引きの終了、歌詞・キューの右側とシークからの操作除外を検証する。
`TEST_RUNNER_MUSICFIN_PLAYER_DRAG_ORIENTATION=portrait` で縦向きも確認できる。
保持中の追従は終了後の XCTest の frame だけでは検出できないため、同時に画面録画を行い、
ログの `PLAYER-DRAG epoch=` と照合して、指を保持した区間のタイトル・画像が移動していることを確認する。
全フレームを使い、短い引きの保持中は約 40 pt 動き、離すと元へ戻ることと、終了時に位置が飛ばないことを見る。
