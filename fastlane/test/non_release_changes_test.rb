# frozen_string_literal: true

# Docs-only (agent/human documentation) merges must be rejected as non-release by the real consumer
# MergeVerifier, while any merge that also touches a shipped path keeps every original provenance gate.
# GitHub API and Git are injected fakes; no network, no repository, no commits are created.
require "json"
require_relative "../lib/merge_verifier"
require_relative "../lib/non_release_documents"

module NonReleaseChanges
  MERGE = "a" * 40
  BEFORE = "c" * 40
  HEAD = "b" * 40
  SOURCE = "Sources/App.swift"
  AGENT_DOCS = %w[AGENTS.md CLAUDE.md].freeze
  HUMAN_DOCS = %w[docs/impl-brief.md docs/ui-spec.md].freeze

  @failures = 0
  class << self
    attr_accessor :failures
  end

  class FakeApi
    def initialize(responses)
      @responses = responses
    end

    def get(path)
      value = @responses.fetch(path) { raise StandardError, "unexpected API path #{path}" }
      value.respond_to?(:call) ? value.call : value
    end
  end

  class FakeGit
    def initialize(table)
      @table = table
    end

    def call(*args)
      @table.fetch(args) { raise StandardError, "unexpected git #{args.inspect}" }
    end
  end

  module_function

  def check(name)
    yield
    puts "ok   #{name}"
  rescue StandardError => e
    NonReleaseChanges.failures += 1
    puts "FAIL #{name}: #{e.class} #{e.message}"
  end

  def assert(condition, message = "assertion failed")
    raise message unless condition
  end

  def run_record(repo, path, id, suite)
    { "id" => id, "path" => path, "event" => "pull_request", "head_sha" => HEAD, "head_branch" => "codex/feature",
      "run_number" => 5, "run_attempt" => 1, "status" => "completed", "conclusion" => "success",
      "check_suite_id" => suite, "pull_requests" => [], "head_repository" => { "full_name" => repo } }
  end

  def check_record(name, suite, id)
    { "id" => id, "name" => name, "head_sha" => HEAD, "status" => "completed", "conclusion" => "success",
      "app" => { "slug" => "github-actions" }, "check_suite" => { "id" => suite }, "pull_requests" => [] }
  end

  # A complete, successful scenario derived from the consumer verifier's own configuration.
  # Two parents (previous tip, PR head), one trusted successful run per required workflow.
  def scenario(verifier, branch, changed)
    repo = verifier::REPOSITORY
    runs = []
    checks = []
    verifier::REQUIRED.each_with_index do |(path, names), index|
      runs << run_record(repo, path, 100 + index, 1000 + index)
      names.each_with_index { |name, i| checks << check_record(name, 1000 + index, 200 + index * 50 + i) }
    end
    pull = {
      "number" => 7, "merged" => true, "merge_commit_sha" => MERGE, "state" => "closed",
      "base" => { "ref" => branch, "repo" => { "full_name" => repo } },
      "head" => { "sha" => HEAD, "ref" => "codex/feature", "repo" => { "full_name" => repo } }
    }
    {
      verifier: verifier, repo: repo, branch: branch, runs: runs, checks: checks, pull: pull, tip: MERGE,
      parents: "#{MERGE} #{BEFORE} #{HEAD}\n", changed: changed,
      env: {
        "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_EVENT_NAME" => "push",
        "GITHUB_REPOSITORY" => repo, "GITHUB_REF" => "refs/heads/#{branch}",
        "GITHUB_WORKFLOW_REF" => "#{repo}/#{verifier::WORKFLOW}@refs/heads/#{branch}",
        "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_SHA" => MERGE
      },
      event: {
        "ref" => "refs/heads/#{branch}", "before" => BEFORE, "after" => MERGE,
        "created" => false, "deleted" => false, "forced" => false, "repository" => { "full_name" => repo }
      }
    }
  end

  def responses(s)
    repo = s[:repo]
    check_head = s[:pull].dig("head", "sha")
    table = {
      "repos/#{repo}/commits/#{MERGE}/pulls?per_page=100&page=1" => [{ "number" => 7 }],
      "repos/#{repo}/pulls/7" => s[:pull],
      "repos/#{repo}/branches/#{s[:branch]}" => { "commit" => { "sha" => s[:tip] } },
      "repos/#{repo}/actions/runs?head_sha=#{check_head}&per_page=100&page=1" => { "workflow_runs" => s[:runs] },
      "repos/#{repo}/commits/#{check_head}/check-runs?per_page=100&filter=latest&page=1" => { "check_runs" => s[:checks] }
    }
    s[:runs].each do |run|
      jobs = s[:checks].select { |entry| entry.dig("check_suite", "id") == run["check_suite_id"] }.map do |entry|
        { "name" => entry["name"], "status" => entry["status"], "conclusion" => entry["conclusion"],
          "check_run_url" => "https://api.github.com/repos/#{repo}/check-runs/#{entry['id']}" }
      end
      table["repos/#{repo}/actions/runs/#{run['id']}/attempts/#{run['run_attempt']}/jobs?per_page=100&page=1"] = { "jobs" => jobs }
    end
    table
  end

  def build(s)
    git = FakeGit.new(
      ["rev-list", "--parents", "-n", "1", MERGE] => s[:parents],
      ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed]
    )
    s[:verifier].new(env: s[:env], event: s[:event], api: FakeApi.new(responses(s)), git: git, sleeper: ->(_) {}, attempts: 2)
  end

  def paths(*names)
    names.flatten.map { |name| "#{name}\0" }.join
  end

  # Returns [result, error]; exactly one is non-nil.
  def outcome(s)
    [build(s).call, nil]
  rescue StandardError => e
    [nil, e]
  end

  # Baseline proof inside every case: the same complete scenario with a shipped source file added
  # is accepted, so a rejection of the docs-only variant can only come from its changed-path set.
  def assert_baseline_accepts(verifier, branch, extra)
    result, error = outcome(scenario(verifier, branch, paths(SOURCE, extra)))
    assert result == { pr_number: 7, sha: MERGE },
           "baseline (#{SOURCE} + #{extra.inspect}) was not accepted: #{error ? "#{error.class} #{error.message}" : result.inspect}"
  end

  def rejected_as_non_release(label, verifier, branches, docs)
    branches.each do |branch|
      check "#{verifier} #{branch} rejects #{label} as non-release" do
        assert_baseline_accepts(verifier, branch, docs)
        result, error = outcome(scenario(verifier, branch, paths(docs)))
        assert error.is_a?(verifier::Error), "expected production non-release refusal, got #{error.inspect}"
        assert result.nil?, "docs-only merge #{docs.inspect} was authorized for release: #{result.inspect}"
      end
    end
  end

  def accepted_as_release(label, verifier, branches, changed)
    branches.each do |branch|
      check "#{verifier} #{branch} still treats #{label} as release-relevant" do
        result, error = outcome(scenario(verifier, branch, paths(changed)))
        assert result == { pr_number: 7, sha: MERGE },
               "#{changed.inspect} was not accepted: #{error ? "#{error.class} #{error.message}" : result.inspect}"
      end
    end
  end

  def run_suite(verifier, branches)
    shipped_record = defined?(DeploymentPolicy::SHIPPED_RECORD) ? DeploymentPolicy::SHIPPED_RECORD : nil

    branches.each do |branch|
      check "#{verifier} #{branch} baseline: source-only merge is accepted" do
        result, error = outcome(scenario(verifier, branch, paths(SOURCE)))
        assert result == { pr_number: 7, sha: MERGE }, error ? "#{error.class} #{error.message}" : result.inspect
      end
    end

    rejected_as_non_release("AGENTS.md-only", verifier, branches, %w[AGENTS.md])
    rejected_as_non_release("CLAUDE.md-only", verifier, branches, %w[CLAUDE.md])
    rejected_as_non_release("AGENTS.md and CLAUDE.md only", verifier, branches, AGENT_DOCS)
    rejected_as_non_release("several human docs only", verifier, branches, HUMAN_DOCS)
    rejected_as_non_release("agent and human docs only", verifier, branches, AGENT_DOCS + HUMAN_DOCS)
    if shipped_record
      rejected_as_non_release("docs plus the shipped record only", verifier, branches, HUMAN_DOCS + AGENT_DOCS + [shipped_record])
      branches.each do |branch|
        check "#{verifier} #{branch} baseline: shipped-record-only merge stays rejected" do
          result, = outcome(scenario(verifier, branch, paths(shipped_record)))
          assert result.nil?, "record-only merge was authorized: #{result.inspect}"
        end
      end
    end

    # Docs next to a shipped source file keep every original gate (provenance + trusted checks).
    mixed = paths(SOURCE, AGENT_DOCS, HUMAN_DOCS)
    branches.each do |branch|
      check "#{verifier} #{branch} docs plus #{SOURCE} is accepted with all gates satisfied" do
        result, error = outcome(scenario(verifier, branch, mixed))
        assert result == { pr_number: 7, sha: MERGE }, error ? "#{error.class} #{error.message}" : result.inspect
      end
      {
        "a fast-forward push (PR head equals merge SHA)" => ->(s) { s[:pull]["head"]["sha"] = MERGE; s[:runs].each { |v| v["head_sha"] = MERGE }; s[:checks].each { |v| v["head_sha"] = MERGE }; s[:parents] = "#{MERGE} #{BEFORE}\n" },
        "a second parent that is not the PR head" => ->(s) { s[:parents] = "#{MERGE} #{BEFORE} #{'d' * 40}\n" },
        "a first parent that is not the push before" => ->(s) { s[:parents] = "#{MERGE} #{'d' * 40} #{HEAD}\n" },
        "an unmerged PR" => ->(s) { s[:pull]["merged"] = false },
        "a fork PR" => ->(s) { s[:pull]["head"]["repo"]["full_name"] = "other/fork" },
        "an obsolete branch tip" => ->(s) { s[:tip] = "d" * 40 },
        "a failed required check" => ->(s) { s[:checks].first["conclusion"] = "failure" },
        "a required check from another app" => ->(s) { s[:checks].each { |c| c["app"]["slug"] = "other-app" } },
        "a missing required run" => ->(s) { s[:runs].shift },
        "a re-run attempt" => ->(s) { s[:env]["GITHUB_RUN_ATTEMPT"] = "2" }
      }.each do |what, mutate|
        check "#{verifier} #{branch} docs plus #{SOURCE} still rejects #{what}" do
          s = scenario(verifier, branch, mixed)
          mutate.call(s)
          result, error = outcome(s)
          assert error.is_a?(verifier::Error), "expected production refusal, got #{error.inspect}"
          assert result.nil?, "unsafe merge was accepted: #{result.inspect}"
        end
      end
    end

    # Names outside the allowlist stay release-relevant, alone and next to docs.
    relevant = {
      "an unallowlisted bundled Markdown resource" => ["Sources/Resources/Terms.md"],
      "an unallowlisted Markdown file next to docs" => ["Sources/Resources/Terms.md", "README.md"],
      "a workflow change" => [".github/workflows/testflight.yaml"],
      "a workflow change next to docs" => [".github/workflows/testflight.yaml", "AGENTS.md", "CLAUDE.md"],
      "a composite action change" => [".github/actions/setup/action.yml"],
      "a fastlane helper change" => ["fastlane/lib/merge_verifier.rb"],
      "a fastlane helper change next to docs" => ["fastlane/lib/merge_verifier.rb", "README.md"],
      "the native document list change" => ["fastlane/lib/non_release_documents.rb"],
      "the native document list change next to docs" => ["fastlane/lib/non_release_documents.rb", *NonReleaseDocuments::PATHS],
      "an unlisted docs path" => ["docs/unlisted.md"],
      "an unlisted docs path next to every listed doc" => ["docs/unlisted.md", *NonReleaseDocuments::PATHS],
      "a lookalike of a listed document" => ["docs/ui-spec.md.swift", "AGENTS.md"]
    }
    relevant.each { |label, changed| accepted_as_release(label, verifier, branches, changed) }

    # 一覧の全パス: 単独、全部まとめて、記録と一緒でも配信対象外。ソースが 1 つ混ざれば受理する。
    NonReleaseDocuments::PATHS.each { |path| rejected_as_non_release("listed document #{path}", verifier, branches, [path]) }
    rejected_as_non_release("every listed document", verifier, branches, NonReleaseDocuments::PATHS)
    accepted_as_release("every listed document plus source", verifier, branches, [SOURCE, *NonReleaseDocuments::PATHS])
  end

  def finish
    if NonReleaseChanges.failures.zero?
      puts "all passed"
    else
      puts "#{NonReleaseChanges.failures} failed"
      exit 1
    end
  end
end

NonReleaseChanges.run_suite(MergeVerifier, MergeVerifier::BRANCHES)
NonReleaseChanges.finish
