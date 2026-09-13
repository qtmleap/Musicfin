# notify_testers lane の純ロジック。ASC への通信を伴わない部分だけをここに置き、
# fastlane 非依存にして fastlane/test/ から検証できるようにしている。

module TesterNotification
  # 通知はビルドの処理が終わっていないと届かない。PROCESSING は待てば解決するが、
  # FAILED / INVALID は待っても解決しないので、理由を分けて伝える。
  READY_STATE = "VALID".freeze
  NOT_INVITED = "NOT_INVITED".freeze
  STATE_REASONS = {
    "PROCESSING" => "ビルドは処理中。完了してから再実行する",
    "FAILED" => "ビルドの処理が失敗している。通知できない",
    "INVALID" => "ビルドが無効と判定されている。通知できない"
  }.freeze

  module_function

  # 処理が終わっていない理由。nil なら通知してよい。
  def blocking_reason(processing_state)
    return nil if processing_state == READY_STATE

    STATE_REASONS.fetch(
      processing_state,
      "ビルドの処理状態が #{processing_state.inspect} で通知できない"
    )
  end

  # 候補から 1 件に絞る。build 番号の指定があればそれで絞り、無ければ
  # 候補が 1 件のときだけ確定する（暗黙に最新を選ぶと誤送信になるため）。
  # 戻り値は [build, nil] か [nil, エラーメッセージ]。
  def select(builds, version:, build_number: nil)
    builds = Array(builds)
    if build_number
      builds = builds.select { |b| b.version.to_s == build_number.to_s }
    end

    if builds.empty?
      return [nil, "該当するビルドが無い: バージョン #{version}#{build_number ? " ビルド #{build_number}" : ''}"]
    end

    if builds.size > 1
      numbers = builds.map { |b| b.version.to_s }.uniq.sort
      return [nil, "ビルドを一意に特定できない（候補: #{numbers.join(', ')}）。build: で番号を指定する"]
    end

    [builds.first, nil]
  end

  # POST /v1/buildBetaNotifications のボディ。
  # 通知対象は「そのビルドに割り当て済みで受け取る資格のあるテスター全員」で、
  # API にグループを指定する余地は無い。
  def notification_body(build_id)
    {
      data: {
        type: "buildBetaNotifications",
        relationships: {
          build: {
            data: {
              type: "builds",
              id: build_id
            }
          }
        }
      }
    }
  end

  # まだ招待が出ていないテスターだけを拾う。API の生レスポンス（attributes.state）を見るのは、
  # spaceship の BetaTester モデルが旧属性名 betaTesterState を参照していて state を落とすため。
  def pending_invitations(rows)
    Array(rows).select { |row| state_of(row) == NOT_INVITED }
  end

  def state_of(row)
    row.is_a?(Hash) ? row.dig("attributes", "state") : nil
  end

  def email_of(row)
    row.is_a?(Hash) ? row.dig("attributes", "email") : nil
  end

  # POST /v1/betaTesterInvitations のボディ。内部テスターに使えるかは実行時にしか分からないので、
  # 呼び出し側でエラーを拾ってグループ再追加にフォールバックする。
  def invitation_body(app_id, tester_id)
    {
      data: {
        type: "betaTesterInvitations",
        relationships: {
          app: { data: { type: "apps", id: app_id } },
          betaTester: { data: { type: "betaTesters", id: tester_id } }
        }
      }
    }
  end

  # autoNotifyEnabled が true のビルドは手動通知 API を受け付けない。
  # これは設定どおりの応答なので、エラーではなく「送る必要が無い」と扱う。
  def auto_notify_conflict?(message)
    message.to_s.downcase.include?("auto-notify already enabled")
  end

  # betaAppLocalizations の attributes。値が空のキーを送ると ASC が
  # 「空文字で上書き」と解釈するので、指定されたものだけ載せる。
  def app_localization_attributes(locale:, description:, feedback_email: nil)
    attributes = { locale: locale, description: description }
    email = feedback_email.to_s.strip
    attributes[:feedbackEmail] = email unless email.empty?
    attributes
  end

  # feedbackEmail 必須で弾かれたのかを API のエラー本文から判定する。
  # 捏造したアドレスを送らないよう、この場合だけ専用の案内で止める。
  def feedback_email_required?(message)
    message.to_s.downcase.include?("feedbackemail")
  end

  # fastlane の lane 引数は文字列で来るので、"true" も真として扱う。
  def truthy?(value)
    [true, "true", "1", "yes", "YES"].include?(value)
  end
end
