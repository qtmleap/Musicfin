# `ruby fastlane/test/tester_notification_test.rb` で実行する。依存追加なし。

require_relative "../lib/tester_notification"

$failures = 0

def check(name)
  yield
  puts "ok   #{name}"
rescue StandardError => e
  $failures += 1
  puts "FAIL #{name}: #{e.message}"
end

def assert(cond, msg = "assertion failed")
  raise msg unless cond
end

# Spaceship の Build の代わり。select が触るのは version だけ。
FakeBuild = Struct.new(:id, :version)

check "build 番号の指定で 1 件に絞れる" do
  builds = [FakeBuild.new("a", "12"), FakeBuild.new("b", "11")]
  build, error = TesterNotification.select(builds, version: "1.0.0", build_number: "12")
  assert error.nil?, error.to_s
  assert build.id == "a", build.inspect
end

check "build 番号が数値でも文字列の version と突き合わせられる" do
  build, error = TesterNotification.select([FakeBuild.new("a", "12")], version: "1.0.0", build_number: 12)
  assert error.nil?, error.to_s
  assert build.id == "a"
end

check "候補 1 件なら build 番号の指定なしで確定する" do
  build, error = TesterNotification.select([FakeBuild.new("a", "7")], version: "1.0.0")
  assert error.nil?, error.to_s
  assert build.id == "a"
end

check "候補 0 件はエラー" do
  build, error = TesterNotification.select([], version: "1.0.0")
  assert build.nil?
  assert error.include?("該当するビルドが無い"), error
  assert error.include?("1.0.0"), error
end

check "指定した build 番号が候補に無いときもエラーに番号が出る" do
  _build, error = TesterNotification.select([FakeBuild.new("a", "12")], version: "1.0.0", build_number: "99")
  assert error.include?("ビルド 99"), error
end

check "候補が複数で絞れないときはエラーに候補を並べる" do
  builds = [FakeBuild.new("a", "12"), FakeBuild.new("b", "11")]
  build, error = TesterNotification.select(builds, version: "1.0.0")
  assert build.nil?
  assert error.include?("一意に特定できない"), error
  assert error.include?("11, 12"), error
end

check "処理状態のガード" do
  assert TesterNotification.blocking_reason("VALID").nil?
  assert TesterNotification.blocking_reason("PROCESSING").include?("処理中")
  assert TesterNotification.blocking_reason("FAILED").include?("失敗")
  assert TesterNotification.blocking_reason("INVALID").include?("無効")
  assert TesterNotification.blocking_reason("UNKNOWN").include?("\"UNKNOWN\"")
end

check "POST ボディの形" do
  body = TesterNotification.notification_body("BUILD_ID")
  assert body[:data][:type] == "buildBetaNotifications", body.inspect
  assert body[:data][:relationships][:build][:data] == { type: "builds", id: "BUILD_ID" }, body.inspect
end

check "dry_run は文字列でも真として扱う" do
  assert TesterNotification.truthy?(true)
  assert TesterNotification.truthy?("true")
  assert !TesterNotification.truthy?(nil)
  assert !TesterNotification.truthy?("false")
end

check "未招待テスターだけを抽出する" do
  rows = [
    { "id" => "1", "attributes" => { "state" => "NOT_INVITED", "email" => "a@example.com" } },
    { "id" => "2", "attributes" => { "state" => "INVITED", "email" => "b@example.com" } },
    { "id" => "3", "attributes" => { "state" => "INSTALLED", "email" => "c@example.com" } },
    { "id" => "4", "attributes" => { "state" => "NOT_INVITED", "email" => "d@example.com" } }
  ]
  pending = TesterNotification.pending_invitations(rows)
  assert pending.map { |r| r["id"] } == %w[1 4], pending.inspect
  assert TesterNotification.email_of(pending.first) == "a@example.com"
  assert TesterNotification.state_of(pending.first) == "NOT_INVITED"
  assert TesterNotification.pending_invitations(nil).empty?
  assert TesterNotification.state_of("not a hash").nil?
end

check "招待 POST のボディの形" do
  body = TesterNotification.invitation_body("APP", "TESTER")
  assert body[:data][:type] == "betaTesterInvitations", body.inspect
  assert body[:data][:relationships][:app][:data] == { type: "apps", id: "APP" }, body.inspect
  assert body[:data][:relationships][:betaTester][:data] == { type: "betaTesters", id: "TESTER" }, body.inspect
end

check "Auto-notify already enabled はエラー扱いしない判定" do
  assert TesterNotification.auto_notify_conflict?(
    "There is a problem with the request entity - Auto-notify already enabled - /data"
  )
  assert TesterNotification.auto_notify_conflict?("auto-notify already enabled")
  assert !TesterNotification.auto_notify_conflict?("The build is expired")
  assert !TesterNotification.auto_notify_conflict?(nil)
end

check "テスト情報の attributes は空の feedbackEmail を載せない" do
  with_email = TesterNotification.app_localization_attributes(
    locale: "ja", description: "説明", feedback_email: " you@example.com "
  )
  assert with_email == { locale: "ja", description: "説明", feedbackEmail: "you@example.com" }, with_email.inspect
  %w[ ].each do |blank|
    attrs = TesterNotification.app_localization_attributes(locale: "ja", description: "説明", feedback_email: blank)
    assert !attrs.key?(:feedbackEmail), attrs.inspect
  end
  assert !TesterNotification.app_localization_attributes(
    locale: "ja", description: "説明"
  ).key?(:feedbackEmail)
end

check "feedbackEmail 必須エラーの判定" do
  assert TesterNotification.feedback_email_required?(
    "The attribute 'feedbackEmail' is required - /data/attributes/feedbackEmail"
  )
  assert !TesterNotification.feedback_email_required?("The locale is invalid")
end

if $failures.zero?
  puts "all passed"
else
  puts "#{$failures} failed"
  exit 1
end
