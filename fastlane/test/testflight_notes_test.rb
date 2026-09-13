# `ruby fastlane/test/testflight_notes_test.rb` で実行する。
# minitest を Gemfile に足さずに済むよう、素の Ruby の assert だけで書いている。

require_relative "../lib/testflight_notes"
require "tmpdir"
require "json"
require "fileutils"
require "time"
require "stringio"

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

check "type/scope/PR 番号を除去して優先 type だけ採用する" do
  text = TestflightNotes.build([
    "feat(player): 歌詞表示を追加 (#12)",
    "fix!: 再生が止まる不具合を修正",
    "docs: README を更新",
    "chore: 依存を更新 (#13)"
  ])
  assert text.start_with?("今回の確認項目\n\n"), "見出しが無い"
  assert text.include?("- 新機能: 歌詞表示を追加\n"), "feat が無い / PR 番号が残っている: #{text}"
  assert text.include?("- 修正: 再生が止まる不具合を修正\n"), "fix が無い"
  assert !text.include?("README"), "docs が混ざっている"
  assert text.end_with?(TestflightNotes::FOOTER), "末尾の確認依頼が無い"
end

check "優先 type が 0 件なら他の type を採用する" do
  text = TestflightNotes.build(["docs: README を更新", "build: アイコンを追加"])
  assert text.include?("- ドキュメント: README を更新"), text
  assert text.include?("- ビルド: アイコンを追加"), text
end

check "重複を除外し、新しい順に最大 10 件" do
  subjects = (1..15).map { |i| "feat: 変更 #{i}" } + ["feat: 変更 1"]
  text = TestflightNotes.build(subjects)
  lines = text.lines.grep(/\A- /)
  assert lines.size == 10, "#{lines.size} 件"
  assert lines.first.include?("変更 1\n"), lines.first
  assert lines.last.include?("変更 10\n"), lines.last
  assert text.scan("変更 1\n").size == 1, "重複が残っている"
end

check "Conventional Commits でない件名と空件名は落とし、全て落ちたらフォールバック" do
  assert TestflightNotes.build(["WIP", "", "  "]) == TestflightNotes::FALLBACK
  assert TestflightNotes.build([]) == TestflightNotes::FALLBACK
  assert TestflightNotes.build(nil) == TestflightNotes::FALLBACK
end

check "4,000 バイトを超えたら古い項目から落とす" do
  subjects = (1..10).map { |i| "feat: #{'あ' * 200}#{i}" }
  text = TestflightNotes.build(subjects)
  assert text.bytesize <= TestflightNotes::MAX_BYTES, "#{text.bytesize} bytes"
  assert text.valid_encoding?
  assert text.lines.grep(/\A- /).size < 10
  assert text.end_with?(TestflightNotes::FOOTER)
end

check "1 項目でも超えるときは文字の途中で切らずに省略する" do
  text = TestflightNotes.build(["feat: #{'漢' * 2000}"])
  assert text.bytesize <= TestflightNotes::MAX_BYTES, "#{text.bytesize} bytes"
  assert text.valid_encoding?
  assert text.include?("…"), "省略記号が無い"
  assert text.end_with?(TestflightNotes::FOOTER)
end

check "タグが無い小さなリポジトリとタグ以降の履歴を取得する" do
  Dir.mktmpdir do |dir|
    git = ->(*args) { system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')}" }
    git.call("init", "-q")
    git.call("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "feat: 最初")
    assert TestflightNotes.git_subjects(dir) == ["feat: 最初"], "タグなし"
    git.call("tag", "v0.1.0")
    assert TestflightNotes.git_subjects(dir) == [], "タグ直後は空"
    git.call("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "fix: 次")
    assert TestflightNotes.git_subjects(dir) == ["fix: 次"], "タグ以降だけ"
  end
end

check "Git 履歴を取得できなければ nil → フォールバック" do
  Dir.mktmpdir do |dir|
    subjects = TestflightNotes.git_subjects(dir)
    assert subjects.nil?, subjects.inspect
    assert TestflightNotes.build(subjects) == TestflightNotes::FALLBACK
  end
end


def repo_git(dir, *args)
  output, status = Open3.capture2e("git", "-C", dir, *args)
  raise output unless status.success?
  output.strip
end

def commit_subject(dir, subject)
  repo_git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com",
           "commit", "-q", "--allow-empty", "-m", subject)
  repo_git(dir, "rev-parse", "HEAD")
end

def with_repo
  Dir.mktmpdir do |dir|
    repo_git(dir, "init", "-q")
    yield dir
  end
end

def shipped_path(dir)
  File.join(dir, "fastlane/testflight/last_shipped.json")
end

def write_shipped_fixture(dir, value)
  FileUtils.mkdir_p(File.dirname(shipped_path(dir)))
  File.write(shipped_path(dir), JSON.generate(value))
end

check "基準が無ければ直近20件だけを取り、古いfeatを混ぜない" do
  with_repo do |dir|
    commit_subject(dir, "feat: 初期の機能")
    (2..26).each { |i| commit_subject(dir, "chore: 変更#{i}") }
    subjects = TestflightNotes.git_subjects(dir)
    assert subjects == (7..26).to_a.reverse.map { |i| "chore: 変更#{i}" }, subjects.inspect
    assert !TestflightNotes.build(subjects).include?("初期の機能")
  end
end

check "uiはfeatやfixとともに優先しdocsを混ぜない" do
  text = TestflightNotes.build(["ui: 余白を調整", "feat: 新機能", "fix: 修正", "docs: 説明"])
  assert text.include?("- UI: 余白を調整"), text
  assert text.include?("- 新機能: 新機能"), text
  assert !text.include?("説明"), text
end

check "配信済みSHAをタグより優先し基準の説明を返す" do
  with_repo do |dir|
    commit_subject(dir, "feat: 初期")
    repo_git(dir, "tag", "v1.0.0")
    sha = commit_subject(dir, "ui: 配信済み")
    write_shipped_fixture(dir, { sha: sha })
    commit_subject(dir, "fix: 未配信")
    subjects, basis = TestflightNotes.git_history(dir)
    assert subjects == ["fix: 未配信"], subjects.inspect
    assert basis.include?("last_shipped.json") && basis.include?(sha), basis
  end
end

check "壊れた記録や存在しないSHAはタグへ落とす" do
  with_repo do |dir|
    commit_subject(dir, "feat: 初期")
    repo_git(dir, "tag", "v1.0.0")
    commit_subject(dir, "ui: タグ以降")
    blob, status = Open3.capture2e("git", "-C", dir, "hash-object", "-w", "--stdin", stdin_data: "blob")
    assert status.success?
    [nil, [], {}, { sha: "0" * 40 }, { sha: blob.strip }, { sha: "HEAD" }, { sha: 123 }].each do |value|
      write_shipped_fixture(dir, value)
      subjects, basis = TestflightNotes.git_history(dir)
      assert subjects == ["ui: タグ以降"], subjects.inspect
      assert basis.include?("v1.0.0"), basis
    end
    File.write(shipped_path(dir), "{broken")
    subjects, basis = TestflightNotes.git_history(dir)
    assert subjects == ["ui: タグ以降"]
    assert basis.include?("v1.0.0"), basis
    repo_git(dir, "tag", "-d", "v1.0.0")
    subjects, basis = TestflightNotes.git_history(dir)
    assert subjects == ["ui: タグ以降", "feat: 初期"]
    assert basis.include?("20"), basis
  end
end

check "HEADまで配信済みなら過去の項目を再掲しない" do
  with_repo do |dir|
    sha = commit_subject(dir, "feat: 配信済み")
    write_shipped_fixture(dir, { sha: sha })
    assert TestflightNotes.git_subjects(dir) == []
  end
end

check "汚れの件数は変更・未追跡・改名を数え、改行を含む名前でも崩れない" do
  with_repo do |dir|
    File.write(File.join(dir, "before"), "a")
    File.write(File.join(dir, "modified"), "b")
    repo_git(dir, "add", ".")
    commit_subject(dir, "chore: 初期")
    assert TestflightNotes.dirty_count(dir) == 0
    repo_git(dir, "mv", "before", "after")
    File.write(File.join(dir, "modified"), "changed")
    File.write(File.join(dir, "untracked\nname"), "c")
    assert TestflightNotes.dirty_count(dir) == 3
  end
end

# 配信やビルドだけを差し替え、レーン本体・Git・記録ファイルの入出力は実物で検証する。
def fastfile_sandbox(dir)
  sandbox = Class.new do
    def self.opt_out_usage; end
    def self.desc(*); end
    def self.lane(name, &block)
      (@lanes ||= {})[name] = block
    end
    def run(name)
      instance_exec(&self.class.instance_variable_get(:@lanes).fetch(name))
    end
  end
  events = []
  ui = Module.new
  [:message, :important, :success].each do |level|
    ui.define_singleton_method(level) { |text| events << [level, text] }
  end
  sandbox.const_set(:UI, ui)
  path = File.expand_path("../Fastfile", __dir__)
  sandbox.class_eval(File.read(path), path)
  sandbox.send(:remove_const, :REPO_ROOT)
  sandbox.const_set(:REPO_ROOT, dir)
  instance = sandbox.new
  instance.define_singleton_method(:asc_api_key) { :test_key }
  instance.define_singleton_method(:next_build_number) { |_| 42 }
  instance.define_singleton_method(:get_version_number) { |**_| "1.2.3" }
  instance.define_singleton_method(:build_for_appstore) { |**_| }
  [instance, events]
end

check "betaは成功後だけ配信記録を書き、アップロード中にHEADが動いても開始時のSHAを残す" do
  with_repo do |dir|
    sha = commit_subject(dir, "ui: 今回の変更")
    File.write(File.join(dir, "private-name"), "dirty")
    lane, events = fastfile_sandbox(dir)
    lane.define_singleton_method(:upload_to_testflight) do |**options|
      assert !File.exist?(shipped_path(dir)), "成功する前に基準が進んだ"
      assert options[:localized_build_info]["ja"][:whats_new].include?("今回の変更")
      commit_subject(dir, "fix: 配信処理中の別コミット")
    end
    before = Time.now.to_i
    lane.run(:beta)
    record = JSON.parse(File.read(shipped_path(dir)))
    assert record["sha"] == sha, record.inspect
    assert record["build"].to_s == "42" && record["version"] == "1.2.3", record.inspect
    assert Time.iso8601(record["uploaded_at"]).to_i.between?(before, Time.now.to_i)
    warning = events.select { |level, _| level == :important }.map(&:last)
    assert warning.include?("未コミットの変更が 1 件あります。テスト内容はコミット件名から作るので、この変更は文面に出ません。"), warning.inspect
    assert events.none? { |_, text| text.include?("private-name") }, events.inspect
    assert events.any? { |level, text| level == :message && text.include?("20") }, events.inspect
    assert TestflightNotes.git_subjects(dir) == ["fix: 配信処理中の別コミット"]
  end
end

check "betaのビルド失敗・アップロード失敗では既存の配信記録を変更しない" do
  [:build_for_appstore, :upload_to_testflight].each do |failure|
    with_repo do |dir|
      sha = commit_subject(dir, "feat: 前回")
      write_shipped_fixture(dir, { sha: sha, build: "41", version: "1.2.3", uploaded_at: "2026-09-12T00:00:00Z" })
      original = File.binread(shipped_path(dir))
      commit_subject(dir, "ui: 未配信")
      lane, = fastfile_sandbox(dir)
      lane.define_singleton_method(:upload_to_testflight) { |**_| }
      lane.define_singleton_method(failure) { |**_| raise "expected failure" }
      begin
        lane.run(:beta)
        raise "レーンが失敗しなかった"
      rescue RuntimeError => e
        assert e.message == "expected failure", e.message
      end
      assert File.binread(shipped_path(dir)) == original
    end
  end
end

check "previewは基準を表示するだけで配信せず記録も作らない" do
  with_repo do |dir|
    commit_subject(dir, "ui: プレビュー")
    repo_git(dir, "tag", "v1.0.0")
    commit_subject(dir, "fix: 差分")
    lane, events = fastfile_sandbox(dir)
    lane.define_singleton_method(:asc_api_key) { raise "プレビューで認証した" }
    lane.define_singleton_method(:upload_to_testflight) { |**_| raise "プレビューで配信した" }
    previous = $stdout
    begin
      $stdout = StringIO.new
      lane.run(:preview_whats_new)
      assert $stdout.string.include?("- 修正: 差分")
    ensure
      $stdout = previous
    end
    assert !File.exist?(shipped_path(dir))
    assert events.any? { |level, text| level == :message && text.include?("v1.0.0") }, events.inspect
  end
end

if $failures.zero?
  puts "all passed"
else
  puts "#{$failures} failed"
  exit 1
end
