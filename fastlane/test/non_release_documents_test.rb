# frozen_string_literal: true

# 配信しないドキュメント一覧とワークフローの整合性、実 Git アダプターの rename 安全性を確かめる。
# 本番 MergeVerifier の拒否は non_release_changes_test.rb が一覧の全パスについて確かめる。
# Git のツリーオブジェクトは init / add / write-tree だけで作る。コミットも通信も認証情報も使わない。
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../lib/merge_verifier"
require_relative "../lib/non_release_documents"

module NonReleaseDocumentsCheck
  ROOT = File.expand_path("../..", __dir__)
  PATHS = NonReleaseDocuments::PATHS
  EXPECTED_DOCUMENTS = %w[
    .agents/skills/ios-development/SKILL.md
    .agents/skills/ios-development/references/app-review-followup.md
    .agents/skills/ios-development/references/release-policy.md
    .agents/skills/ios-development/references/testing-policy.md
    AGENTS.md
    CLAUDE.md
    docs/development/ci-change-scope.md
    docs/development/ios-development-routine.md
    docs/impl-brief.md
    docs/superpowers/plans/2026-09-10-remaining-ui.md
    docs/superpowers/plans/2026-10-06-recovery-and-develop-ci.md
    docs/superpowers/plans/2026-10-11-album-overlay-continuity.md
    docs/ui-consult-prompt.md
    docs/ui-spec.md
  ].freeze
  WORKFLOW = ".github/workflows/deployment.yaml"
  EXPECTED_IGNORE = (defined?(DeploymentPolicy::SHIPPED_RECORD) ? [DeploymentPolicy::SHIPPED_RECORD] : []) + NonReleaseDocuments::PATHS

  module_function

  @failures = 0

  def check(name)
    yield
    puts "ok   #{name}"
  rescue StandardError => e
    @failures += 1
    puts "FAIL #{name}: #{e.class} #{e.message}"
  end

  def finish
    puts(@failures.zero? ? "all passed" : "#{@failures} failed")
    exit 1 unless @failures.zero?
  end

  def assert(condition, message = "assertion failed")
    raise message unless condition
  end

  def workflow_ignore
    lines = File.read(File.join(ROOT, WORKFLOW)).lines
    start = lines.index { |line| line =~ /^    paths-ignore:\s*$/ } or raise "paths-ignore not found"
    lines.drop(start + 1).take_while { |line| line.start_with?("      - ") }.map { |line| line.sub("      - ", "").strip }
  end

  def clean_env
    { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0" }
  end

  def git!(directory, *args)
    out, err, status = Open3.capture3(clean_env, "git", "-C", directory, *args)
    raise "git #{args.first} failed: #{err}" unless status.success?

    out.strip
  end

  # コミットを作らず、2 つのツリーオブジェクト (ソース版と、同一内容をドキュメントへ移した版) を作る。
  def with_rename_trees
    Dir.mktmpdir("non-release-docs-") do |directory|
      git!(directory, "init", "--quiet")
      git!(directory, "config", "diff.renames", "true")
      body = (1..60).map { |n| "line #{n}\n" }.join
      FileUtils.mkdir_p(File.join(directory, "Sources"))
      File.write(File.join(directory, "Sources/App.swift"), body)
      git!(directory, "add", "--all")
      source_tree = git!(directory, "write-tree")
      File.delete(File.join(directory, "Sources/App.swift"))
      FileUtils.mkdir_p(File.join(directory, "docs"))
      File.write(File.join(directory, "docs/ui-spec.md"), body)
      git!(directory, "add", "--all")
      document_tree = git!(directory, "write-tree")
      yield directory, source_tree, document_tree
    end
  end
end

module NonReleaseDocumentsCheck
  check "the exact list is finite, unique and contains no glob or directory entries" do
    assert PATHS.is_a?(Array) && PATHS.frozen? && !PATHS.empty?, "list must be a frozen non-empty array"
    assert PATHS.uniq == PATHS, "duplicate entries"
    assert PATHS.all? { |path| path.match?(%r{\A[\w.\-/]+\z}) && !path.end_with?("/") }, "glob or directory entry"
    assert PATHS.none? { |path| path.start_with?("/") || path.split("/").include?("..") }, "unsafe path"
    assert PATHS.none? { |path| path.start_with?("Sources/", "fastlane/", ".github/") }, "source, fastlane or CI path exempted"
    assert PATHS.include?("AGENTS.md") && PATHS.include?("CLAUDE.md") && PATHS.include?("docs/development/ci-change-scope.md")
  end

  check "the native list equals the audited exact document set" do
    assert PATHS.sort == EXPECTED_DOCUMENTS.sort, "approved document set changed"
    EXPECTED_DOCUMENTS.each do |path|
      assert File.file?(File.join(ROOT, path)), "declared document is missing: #{path}"
    end
  end

  check "deployment.yaml paths-ignore is the native list" do
    expected = EXPECTED_IGNORE
    assert workflow_ignore.sort == expected.sort, "workflow differs from native list: #{(workflow_ignore - expected) | (expected - workflow_ignore)}"
    assert workflow_ignore.uniq == workflow_ignore, "duplicate workflow entries"
  end

  check "integration.yaml doc-paths equals the native list" do
    source = File.read(File.join(ROOT, ".github/workflows/integration.yaml"))
    literal = source[/doc-paths: '(\[.*?\])'/, 1] or raise "doc-paths not found"
    assert JSON.parse(literal).sort == PATHS.sort, "integration audit list differs from native list"
  end

  check "RenameSafeDiff adds --no-renames only to git diff --name-only and keeps other calls and errors" do
    seen = []
    base = Class.new do
      define_method(:call) { |*args| seen << args; args.include?("boom") ? raise(ArgumentError, "original") : "ok" }
    end
    wrapped = Class.new(base) { prepend NonReleaseDocuments::RenameSafeDiff }.new
    wrapped.call("diff", "--name-only", "-z", "a", "b", "--")
    wrapped.call("diff", "--no-renames", "--name-only", "a", "b")
    wrapped.call("diff", "--stat", "a", "b")
    wrapped.call("rev-list", "--parents", "-n", "1", "a")
    assert seen[0] == ["diff", "--no-renames", "--name-only", "-z", "a", "b", "--"], seen[0].inspect
    assert seen[1] == ["diff", "--no-renames", "--name-only", "a", "b"], "inserted twice"
    assert seen[2] == ["diff", "--stat", "a", "b"] && seen[3] == ["rev-list", "--parents", "-n", "1", "a"], "other calls changed"
    error = begin
      wrapped.call("diff", "--name-only", "boom")
      nil
    rescue ArgumentError => e
      e
    end
    assert error && error.message == "original", "original error was not preserved"
  end

  check "the exported protected Git adapter keeps both source and document paths for an identical rename" do
    with_rename_trees do |directory, source_tree, document_tree|
      adapter = MergeVerifier::Git.new(directory)
      assert MergeVerifier::Git.ancestors.include?(NonReleaseDocuments::RenameSafeDiff), "adapter is not protected"
      paths = adapter.call("diff", "--name-only", "-z", source_tree, document_tree, "--").split("\0")
      assert paths.sort == ["Sources/App.swift", "docs/ui-spec.md"], "removed source path hidden: #{paths.inspect}"
      # 負の対照: 素の Git は rename 検出で削除されたソースを隠す。
      plain = git!(directory, "diff", "--name-only", "-z", source_tree, document_tree, "--").split("\0")
      assert plain == ["docs/ui-spec.md"], "control did not show the hidden rename: #{plain.inspect}"
      # 負の対照: 明示的な rename 検出 (-M) でも同じくソースが消える。保護が無いと検出されてしまう差分である。
      explicit = git!(directory, "diff", "-M", "--name-only", "-z", source_tree, document_tree, "--").split("\0")
      assert explicit == ["docs/ui-spec.md"], "explicit rename detection control changed: #{explicit.inspect}"
    end
  end

  check "the adapter refuses a bad tree and a bad repository" do
    with_rename_trees do |directory, source_tree, _|
      [[directory, "f" * 40], [File.join(directory, "missing"), source_tree]].each do |dir, tree|
        error = begin
          MergeVerifier::Git.new(dir).call("diff", "--name-only", "-z", source_tree, tree, "--")
          nil
        rescue MergeVerifier::Error => e
          e
        end
        assert error, "Git failure was not refused"
      end
    end
  end
end

NonReleaseDocumentsCheck.finish
