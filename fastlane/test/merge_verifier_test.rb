# 秘密を持たない検証ジョブが、push を「新しい PR マージ 1 回分」と認める条件を検証する。
# GitHub API と Git は注入できる偽物で、ネットワークにも実リポジトリにも触れない。
require "json"
require_relative "../lib/merge_verifier"

$failures = 0

def check(name)
  yield
  puts "ok   #{name}"
rescue StandardError => e
  $failures += 1
  puts "FAIL #{name}: #{e.class} #{e.message}"
end

def assert(condition, message = "assertion failed")
  raise message unless condition
end

REPO = "qtmleap/Musicfin"
MERGE = "a" * 40
BEFORE = "c" * 40
HEAD = "b" * 40
OTHER = "d" * 40
INTEGRATION = ".github/workflows/integration.yaml"
VALIDATION = ".github/workflows/release_validation.yaml"
INTEGRATION_CHECKS = ["Commit Lint", "ShellCheck", "swift-format", "Build", "Unit Tests", "actionlint", "Fastlane Policy and Notes"].freeze

class FakeApi
  attr_reader :requests

  def initialize(responses)
    @responses = responses
    @requests = []
  end

  def get(path)
    @requests << path
    value = @responses.fetch(path) { raise MergeVerifier::Error, "unexpected API path #{path}" }
    value.respond_to?(:call) ? value.call : value
  end
end

class FakeGit
  def initialize(table)
    @table = table
  end

  def call(*args)
    @table.fetch(args) { raise MergeVerifier::Error, "unexpected git #{args.inspect}" }
  end
end

def run_record(path:, id:, suite:, number: 1, attempt: 1, status: "completed", conclusion: "success", head: HEAD, event: "pull_request", branch: "codex/feature")
  {
    "id" => id, "path" => path, "event" => event, "head_sha" => head, "head_branch" => branch,
    "run_number" => number, "run_attempt" => attempt, "status" => status, "conclusion" => conclusion,
    "check_suite_id" => suite, "pull_requests" => [],
    "head_repository" => { "full_name" => REPO }
  }
end

def check_record(name, suite:, id:, status: "completed", conclusion: "success", head: HEAD, app: "github-actions")
  {
    "id" => id, "name" => name, "head_sha" => head, "status" => status, "conclusion" => conclusion,
    "app" => { "slug" => app }, "check_suite" => { "id" => suite }, "pull_requests" => []
  }
end

def scenario(branch: "develop")
  runs = [
    run_record(path: INTEGRATION, id: 100, suite: 1000, number: 5),
    run_record(path: VALIDATION, id: 101, suite: 1001, number: 3)
  ]
  checks = INTEGRATION_CHECKS.each_with_index.map { |name, i| check_record(name, suite: 1000, id: 200 + i) } +
    [check_record("Validate marketing version", suite: 1001, id: 300)]
  pull = {
    "number" => 7, "merged" => true, "merge_commit_sha" => MERGE, "state" => "closed",
    "base" => { "ref" => branch, "repo" => { "full_name" => REPO } },
    "head" => { "sha" => HEAD, "ref" => "codex/feature", "repo" => { "full_name" => REPO } }
  }
  {
    branch: branch, runs: runs, checks: checks, pull: pull, pulls: [{ "number" => 7 }], tip: MERGE,
    parents: "#{MERGE} #{BEFORE}\n", changed: "Musicfin/App/RootView.swift\0",
    env: {
      "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REPOSITORY" => REPO, "GITHUB_REF" => "refs/heads/#{branch}",
      "GITHUB_WORKFLOW_REF" => "#{REPO}/.github/workflows/deployment.yaml@refs/heads/#{branch}",
      "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_SHA" => MERGE
    },
    event: {
      "ref" => "refs/heads/#{branch}", "before" => BEFORE, "after" => MERGE,
      "created" => false, "deleted" => false, "forced" => false, "repository" => { "full_name" => REPO }
    }
  }
end

def build(s)
  api = FakeApi.new(
    "repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => s[:pulls],
    "repos/#{REPO}/pulls/7" => s[:pull],
    "repos/#{REPO}/branches/#{s[:branch]}" => { "commit" => { "sha" => s[:tip] } },
    "repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=1" => { "workflow_runs" => s[:runs] },
    "repos/#{REPO}/commits/#{HEAD}/check-runs?per_page=100&filter=latest&page=1" => { "check_runs" => s[:checks] }
  )
  git = FakeGit.new(
    ["rev-list", "--parents", "-n", "1", MERGE] => s[:parents],
    ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed]
  )
  MergeVerifier.new(env: s[:env], event: s[:event], api: api, git: git, sleeper: ->(_) {}, attempts: 2)
end

def rejects(name, branches: %w[develop master])
  branches.each do |branch|
    check "#{branch} rejects #{name}" do
      s = scenario(branch: branch)
      yield s
      error = begin
        build(s).call
        nil
      rescue MergeVerifier::Error, DeploymentPolicy::Error => e
        e
      end
      assert error, "unsafe merge was accepted"
    end
  end
end

%w[develop master].each do |branch|
  check "#{branch} accepts a merge commit with empty post-merge PR arrays" do
    result = build(scenario(branch: branch)).call
    assert result == { pr_number: 7, sha: MERGE }, result.inspect
  end
end

check "a squash merge whose only parent is the previous tip is accepted" do
  s = scenario
  s[:parents] = "#{MERGE} #{BEFORE}\n"
  s[:pull]["head"]["sha"] = HEAD
  assert build(s).call[:sha] == MERGE
end

# push イベントの拒否
rejects("a pull_request event") { |s| s[:env]["GITHUB_EVENT_NAME"] = "pull_request" }
rejects("a manual dispatch") { |s| s[:env]["GITHUB_EVENT_NAME"] = "workflow_dispatch" }
rejects("a tag ref") { |s| s[:env]["GITHUB_REF"] = "refs/tags/v1"; s[:event]["ref"] = "refs/tags/v1" }
rejects("a feature branch") { |s| s[:env]["GITHUB_REF"] = "refs/heads/feature"; s[:event]["ref"] = "refs/heads/feature" }
rejects("a re-run") { |s| s[:env]["GITHUB_RUN_ATTEMPT"] = "2" }
rejects("another repository") { |s| s[:env]["GITHUB_REPOSITORY"] = "other/Musicfin" }
rejects("another workflow ref") { |s| s[:env]["GITHUB_WORKFLOW_REF"] = s[:env]["GITHUB_WORKFLOW_REF"].sub("deployment", "integration") }
rejects("branch creation") { |s| s[:event]["created"] = true }
rejects("branch deletion") { |s| s[:event]["deleted"] = true }
rejects("a forced push") { |s| s[:event]["forced"] = true }
rejects("a zero before") { |s| s[:event]["before"] = "0" * 40 }
rejects("an after that differs from GITHUB_SHA") { |s| s[:event]["after"] = OTHER }
rejects("a first parent that is not before") { |s| s[:parents] = "#{MERGE} #{OTHER} #{HEAD}\n" }
rejects("a root commit") { |s| s[:parents] = "#{MERGE}\n" }
rejects("a merge whose second parent is not the PR head") { |s| s[:parents] = "#{MERGE} #{BEFORE} #{OTHER}\n" }
rejects("a record-only change") { |s| s[:changed] = "fastlane/testflight/last_shipped.json\0" }
rejects("an empty change") { |s| s[:changed] = "" }

# PR の特定
rejects("a push that no PR produced") { |s| s[:pulls] = [] }
rejects("an unmerged PR") { |s| s[:pull]["merged"] = false }
rejects("a merge SHA that differs") { |s| s[:pull]["merge_commit_sha"] = OTHER }
rejects("a PR into another base") { |s| s[:pull]["base"]["ref"] = s[:branch] == "develop" ? "master" : "develop" }
rejects("a fork PR") { |s| s[:pull]["head"]["repo"]["full_name"] = "other/Musicfin" }
rejects("a deleted fork") { |s| s[:pull]["head"]["repo"] = nil }
rejects("an obsolete merge") { |s| s[:tip] = OTHER }
check "two matching PRs are ambiguous" do
  s = scenario
  s[:pulls] = [{ "number" => 7 }, { "number" => 8 }]
  api = FakeApi.new(
    "repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => s[:pulls],
    "repos/#{REPO}/pulls/7" => s[:pull],
    "repos/#{REPO}/pulls/8" => s[:pull].merge("number" => 8)
  )
  git = FakeGit.new(["rev-list", "--parents", "-n", "1", MERGE] => s[:parents], ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed])
  error = begin
    MergeVerifier.new(env: s[:env], event: s[:event], api: api, git: git, sleeper: ->(_) {}, attempts: 1).call
    nil
  rescue MergeVerifier::Error => e
    e
  end
  assert error && error.message.include?("複数"), error.inspect
end

check "a late PR index is retried a bounded number of times" do
  s = scenario
  calls = 0
  list = -> { (calls += 1) < 2 ? [] : s[:pulls] }
  api = FakeApi.new(
    "repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => list,
    "repos/#{REPO}/pulls/7" => s[:pull],
    "repos/#{REPO}/branches/develop" => { "commit" => { "sha" => MERGE } },
    "repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=1" => { "workflow_runs" => s[:runs] },
    "repos/#{REPO}/commits/#{HEAD}/check-runs?per_page=100&filter=latest&page=1" => { "check_runs" => s[:checks] }
  )
  git = FakeGit.new(["rev-list", "--parents", "-n", "1", MERGE] => s[:parents], ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed])
  sleeps = []
  result = MergeVerifier.new(env: s[:env], event: s[:event], api: api, git: git, sleeper: ->(n) { sleeps << n }, attempts: 3).call
  assert result[:sha] == MERGE && calls == 2 && sleeps.length == 1, "calls=#{calls} sleeps=#{sleeps.inspect}"
end

# 必須チェックと信頼できる実行
(INTEGRATION_CHECKS + ["Validate marketing version"]).each do |name|
  rejects("a missing #{name} check", branches: ["develop"]) { |s| s[:checks].reject! { |c| c["name"] == name } }
  rejects("a failed #{name} check", branches: ["develop"]) { |s| s[:checks].find { |c| c["name"] == name }["conclusion"] = "failure" }
  rejects("a skipped #{name} check", branches: ["develop"]) { |s| s[:checks].find { |c| c["name"] == name }["conclusion"] = "skipped" }
  rejects("a pending #{name} check", branches: ["develop"]) { |s| c = s[:checks].find { |c| c["name"] == name }; c["status"] = "in_progress"; c["conclusion"] = nil }
end
rejects("a check from another app", branches: ["develop"]) { |s| s[:checks].each { |c| c["app"]["slug"] = "other-app" } }
rejects("a same-named check from an untrusted suite", branches: ["develop"]) do |s|
  s[:checks].find { |c| c["name"] == "Build" }["check_suite"]["id"] = 9999
end
rejects("a run for another workflow path", branches: ["develop"]) { |s| s[:runs][0]["path"] = ".github/workflows/evil.yaml" }
rejects("a run from a workflow_dispatch event", branches: ["develop"]) { |s| s[:runs][0]["event"] = "workflow_dispatch" }
rejects("a run for another head SHA", branches: ["develop"]) { |s| s[:runs][0]["head_sha"] = OTHER }
rejects("a run from another source branch", branches: ["develop"]) { |s| s[:runs][0]["head_branch"] = "other" }
rejects("a run from another repository", branches: ["develop"]) { |s| s[:runs][0]["head_repository"]["full_name"] = "other/Musicfin" }
rejects("a missing integration run", branches: ["develop"]) { |s| s[:runs].shift }
rejects("a pending latest run", branches: ["develop"]) { |s| s[:runs][0]["status"] = "in_progress"; s[:runs][0]["conclusion"] = nil }
check "a latest failed rerun supersedes an older success" do
  s = scenario
  s[:runs] << run_record(path: INTEGRATION, id: 110, suite: 1010, number: 6, conclusion: "failure")
  s[:checks] << check_record("Build", suite: 1010, id: 400, conclusion: "failure")
  error = begin
    build(s).call
    nil
  rescue MergeVerifier::Error => e
    e
  end
  assert error, "an older success hid a newer failure"
end
check "a latest successful rerun supersedes an older failure" do
  s = scenario
  s[:runs] << run_record(path: INTEGRATION, id: 90, suite: 990, number: 4, conclusion: "failure")
  s[:checks] << check_record("Build", suite: 990, id: 190, conclusion: "failure")
  assert build(s).call[:sha] == MERGE
end

check "a failed second attempt of the same run blocks earlier successful checks" do
  s = scenario
  s[:runs][0]["run_attempt"] = 2
  s[:runs][0]["conclusion"] = "failure"
  error = begin
    build(s).call
    nil
  rescue MergeVerifier::Error => e
    e
  end
  assert error, "attempt one success hid the same run's failed second attempt"
end
check "a successful second attempt of the same run uses its latest check results" do
  s = scenario
  s[:runs][0]["run_attempt"] = 2
  assert build(s).call[:sha] == MERGE
  s[:checks].find { |c| c["name"] == "Build" }["conclusion"] = "failure"
  error = begin
    build(s).call
    nil
  rescue MergeVerifier::Error => e
    e
  end
  assert error, "same-suite old success hid the second attempt's failed build"
end
check "trusted workflow runs and checks on the second API page are accepted" do
  s = scenario
  api = FakeApi.new(
    "repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => s[:pulls],
    "repos/#{REPO}/pulls/7" => s[:pull],
    "repos/#{REPO}/branches/#{s[:branch]}" => { "commit" => { "sha" => MERGE } },
    "repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=1" => {
      "workflow_runs" => Array.new(100) { |i| run_record(path: ".github/workflows/other.yaml", id: 500+i, suite: 5000+i) }
    },
    "repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=2" => { "workflow_runs" => s[:runs] },
    "repos/#{REPO}/commits/#{HEAD}/check-runs?per_page=100&filter=latest&page=1" => {
      "check_runs" => Array.new(100) { |i| check_record("Other #{i}", suite: 9000, id: 900+i) }
    },
    "repos/#{REPO}/commits/#{HEAD}/check-runs?per_page=100&filter=latest&page=2" => { "check_runs" => s[:checks] }
  )
  git = FakeGit.new(["rev-list", "--parents", "-n", "1", MERGE] => s[:parents], ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed])
  result=MergeVerifier.new(env:s[:env],event:s[:event],api:api,git:git,sleeper:->(_) {},attempts:1).call
  assert result == {pr_number:7,sha:MERGE}, result.inspect
  assert api.requests.any? { |path| path.include?("&page=2") }
end

check "pagination is bounded" do
  s = scenario
  api = FakeApi.new(
    "repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => s[:pulls],
    "repos/#{REPO}/pulls/7" => s[:pull]
  )
  responses = api.instance_variable_get(:@responses)
  (1..40).each do |page|
    responses["repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=#{page}"] = {
      "workflow_runs" => Array.new(100) { |i| run_record(path: ".github/workflows/x.yaml", id: page * 1000 + i, suite: i, number: i) }
    }
  end
  git = FakeGit.new(["rev-list", "--parents", "-n", "1", MERGE] => s[:parents], ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed])
  error = begin
    MergeVerifier.new(env: s[:env], event: s[:event], api: api, git: git, sleeper: ->(_) {}, attempts: 1).call
    nil
  rescue MergeVerifier::Error => e
    e
  end
  assert error, "unbounded pagination"
  assert api.requests.length <= 2 + MergeVerifier::MAX_PAGES, "too many requests: #{api.requests.length}"
end

check "the output file receives only the verified SHA and PR number" do
  require "tmpdir"
  Dir.mktmpdir do |dir|
    path = File.join(dir, "out")
    MergeVerifier.write_output(path, pr_number: 7, sha: MERGE)
    assert File.read(path) == "pr_number=7\nsha=#{MERGE}\n", File.read(path)
  end
end

check "the verifier requires no credentials beyond a read token" do
  error = begin
    MergeVerifier::Api.new(token: "")
    nil
  rescue MergeVerifier::Error => e
    e
  end
  assert error, "empty token accepted"
end

if $failures.zero?
  puts "all passed"
else
  puts "#{$failures} failed"
  exit 1
end
