# 配信を伴う依存だけを止め、実際の lane が認証より先に拒否することを検証する。
require "json"
require "tmpdir"

$failures = 0

def check(name)
  yield
  puts "ok   #{name}"
rescue StandardError => e
  $failures += 1
  puts "FAIL #{name}: #{e.message}"
end

def assert(condition, message = "assertion failed")
  raise message unless condition
end

def with_environment(values)
  previous = values.to_h { |key, _| [key, ENV[key]] }
  values.each { |key, value| ENV[key] = value }
  yield
ensure
  previous.each { |key, value| ENV[key] = value }
end

def production_lane
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
  ui = Module.new
  [:message, :important, :success].each { |level| ui.define_singleton_method(level) { |_| } }
  ui.define_singleton_method(:user_error!) { |message| raise message }
  sandbox.const_set(:UI, ui)
  path = File.expand_path("../Fastfile", __dir__)
  sandbox.class_eval(File.read(path), path)
  calls = []
  instance = sandbox.new
  instance.define_singleton_method(:get_version_number) { |**_| "0.1.0" }
  instance.define_singleton_method(:asc_api_key) do
    calls << :credentials
    raise "credentials reached"
  end
  [instance, calls]
end

[:beta, :release].each do |name|
  check "local #{name} is rejected before credentials" do
    with_environment("GITHUB_ACTIONS" => nil, "GITHUB_EVENT_NAME" => nil) do
      lane, calls = production_lane
      error = begin
        lane.run(name)
        nil
      rescue StandardError => e
        e
      end
      assert error && error.message.include?("CI"), "lane did not reject local deployment: #{error&.message}"
      assert calls.empty?, "credentials were reached"
    end
  end
end

require_relative "../lib/deployment_policy"

MERGED_SHA = "a" * 40
OTHER_SHA = "b" * 40

check "a read-only HTTPS token configures match authorization" do
  env = { "MATCH_GIT_TOKEN" => "fixture-token", "MATCH_GIT_PRIVATE_KEY" => "" }
  DeploymentPolicy.signing_environment!(env: env)
  assert env["MATCH_GIT_URL"] == "https://github.com/qtmleap/match.git"
  assert env["MATCH_GIT_BASIC_AUTHORIZATION"] == "eC1hY2Nlc3MtdG9rZW46Zml4dHVyZS10b2tlbg=="
  assert !env.key?("MATCH_GIT_PRIVATE_KEY"), "empty SSH key remained selected"
end

check "a read-only deploy key selects SSH without HTTPS authorization" do
  env = { "MATCH_GIT_PRIVATE_KEY" => "fixture-key", "MATCH_GIT_BASIC_AUTHORIZATION" => "old" }
  DeploymentPolicy.signing_environment!(env: env)
  assert env["MATCH_GIT_URL"] == "git@github.com:qtmleap/match.git"
  assert env["MATCH_GIT_PRIVATE_KEY"] == "fixture-key"
  assert !env.key?("MATCH_GIT_BASIC_AUTHORIZATION"), "old HTTPS authorization remained selected"
end

[{ }, { "MATCH_GIT_TOKEN" => "fixture-token", "MATCH_GIT_PRIVATE_KEY" => "fixture-key" }].each do |env|
  check "missing or ambiguous signing credentials are rejected without exposing them" do
    error = begin
      DeploymentPolicy.signing_environment!(env: env)
      nil
    rescue DeploymentPolicy::Error => e
      e
    end
    assert error, "invalid signing configuration was accepted"
    assert !error.message.include?("fixture-token") && !error.message.include?("fixture-key"), "credential was exposed"
  end
end

def allowed_fixture
  {
    lane: :beta,
    env: {
      "GITHUB_ACTIONS" => "true",
      "GITHUB_EVENT_NAME" => "pull_request",
      "GITHUB_REPOSITORY" => "qtmleap/Musicfin",
      "GITHUB_REF" => "refs/heads/develop",
      "GITHUB_WORKFLOW_REF" => "qtmleap/Musicfin/.github/workflows/deployment.yaml@refs/heads/develop",
      "GITHUB_RUN_ATTEMPT" => "1",
      "GITHUB_SHA" => MERGED_SHA
    },
    event: {
      "action" => "closed",
      "repository" => { "full_name" => "qtmleap/Musicfin" },
      "pull_request" => {
        "merged" => true,
        "state" => "closed",
        "merge_commit_sha" => MERGED_SHA,
        "base" => { "ref" => "develop", "repo" => { "full_name" => "qtmleap/Musicfin" } },
        "head" => { "repo" => { "full_name" => "qtmleap/Musicfin" } }
      }
    },
    head_sha: MERGED_SHA,
    develop_sha: MERGED_SHA,
    dirty_count: 0,
    changed_paths: ["Musicfin/App/RootView.swift"]
  }
end

check "the exact current merge from this repository is accepted" do
  assert DeploymentPolicy.validate!(**allowed_fixture) == MERGED_SHA
end

cases = {
  "local execution" => ->(f) { f[:env]["GITHUB_ACTIONS"] = nil },
  "manual dispatch" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "workflow_dispatch" },
  "tag push" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "push"; f[:env]["GITHUB_REF"] = "refs/tags/v0.1.0" },
  "open PR" => ->(f) { f[:event]["action"] = "opened" },
  "unmerged PR" => ->(f) { f[:event]["pull_request"]["merged"] = false },
  "open PR state" => ->(f) { f[:event]["pull_request"]["state"] = "open" },
  "wrong base" => ->(f) { f[:event]["pull_request"]["base"]["ref"] = "master" },
  "wrong ref" => ->(f) { f[:env]["GITHUB_REF"] = "refs/heads/master" },
  "other workflow" => ->(f) { f[:env]["GITHUB_WORKFLOW_REF"] = "qtmleap/Musicfin/.github/workflows/integration.yaml@refs/heads/develop" },
  "other environment repository" => ->(f) { f[:env]["GITHUB_REPOSITORY"] = "other/Musicfin" },
  "other event repository" => ->(f) { f[:event]["repository"]["full_name"] = "other/Musicfin" },
  "fork source" => ->(f) { f[:event]["pull_request"]["head"]["repo"]["full_name"] = "other/Musicfin" },
  "other base repository" => ->(f) { f[:event]["pull_request"]["base"]["repo"]["full_name"] = "other/Musicfin" },
  "missing merge SHA" => ->(f) { f[:event]["pull_request"]["merge_commit_sha"] = nil },
  "revision expression" => ->(f) { f[:event]["pull_request"]["merge_commit_sha"] = "HEAD" },
  "wrong event SHA" => ->(f) { f[:env]["GITHUB_SHA"] = OTHER_SHA },
  "wrong checkout" => ->(f) { f[:head_sha] = OTHER_SHA },
  "second run attempt" => ->(f) { f[:env]["GITHUB_RUN_ATTEMPT"] = "2" },
  "missing run attempt" => ->(f) { f[:env]["GITHUB_RUN_ATTEMPT"] = nil },
  "obsolete develop merge" => ->(f) { f[:develop_sha] = OTHER_SHA },
  "dirty checkout" => ->(f) { f[:dirty_count] = 1 },
  "unknown checkout status" => ->(f) { f[:dirty_count] = nil },
  "record-only merge" => ->(f) { f[:changed_paths] = ["fastlane/testflight/last_shipped.json"] },
  "empty diff" => ->(f) { f[:changed_paths] = [] },
  "unknown diff" => ->(f) { f[:changed_paths] = nil },
  "invalid diff paths" => ->(f) { f[:changed_paths] = [nil] },
  "malformed event repository" => ->(f) { f[:event]["repository"] = "invalid" },
  "malformed PR" => ->(f) { f[:event]["pull_request"] = [] },
  "App Store lane" => ->(f) { f[:lane] = :release }
}
cases.each do |name, mutate|
  check "rejects #{name}" do
    fixture = allowed_fixture
    mutate.call(fixture)
    error = begin
      DeploymentPolicy.validate!(**fixture)
      nil
    rescue DeploymentPolicy::Error => e
      e
    end
    assert error, "unsafe deployment was accepted"
  end
end

check "a merge containing code and the shipped record is accepted" do
  fixture = allowed_fixture
  fixture[:changed_paths] << "fastlane/testflight/last_shipped.json"
  assert DeploymentPolicy.validate!(**fixture) == MERGED_SHA
end

check "CI release rejects before reading the event file" do
  with_environment(allowed_fixture[:env].merge("GITHUB_EVENT_PATH" => nil)) do
    lane, calls = production_lane
    error = begin
      lane.run(:release)
      nil
    rescue StandardError => e
      e
    end
    assert error && error.message.include?("App Store"), "release did not reject immediately: #{error&.message}"
    assert calls.empty?, "credentials were reached"
  end
end

check "develop advancing during archive stops the lane before upload and recording" do
  Dir.mktmpdir do |dir|
    lane, = production_lane
    sandbox = lane.class
    sandbox.send(:remove_const, :REPO_ROOT)
    sandbox.const_set(:REPO_ROOT, dir)
    calls = []
    lane.define_singleton_method(:authorize_deployment) { |_| MERGED_SHA }
    lane.define_singleton_method(:prepare_ci_signing) { }
    lane.define_singleton_method(:setup_ci) { }
    lane.define_singleton_method(:asc_api_key) { :test_key }
    lane.define_singleton_method(:next_build_number) { |_| 49 }
    lane.define_singleton_method(:whats_new_notes) { "Test notes" }
    lane.define_singleton_method(:build_for_appstore) { |**_| calls << :build }
    lane.define_singleton_method(:verify_deployment_target) do |sha|
      DeploymentPolicy.current!(sha: sha, head_sha: sha, develop_sha: OTHER_SHA, dirty_count: 0)
    end
    lane.define_singleton_method(:upload_to_testflight) { |**_| calls << :upload }
    error = begin
      lane.run(:beta)
      nil
    rescue DeploymentPolicy::Error => e
      e
    end
    assert error, "obsolete build was uploaded"
    assert calls == [:build], "upload ran: #{calls.inspect}"
    assert !File.exist?(File.join(dir, "fastlane/testflight/last_shipped.json")), "failed upload advanced the record"
  end
end

check "the lane prepares a CI keychain after authorization and before signing" do
  Dir.mktmpdir do |dir|
    lane, = production_lane
    sandbox = lane.class
    sandbox.send(:remove_const, :REPO_ROOT)
    sandbox.const_set(:REPO_ROOT, dir)
    calls = []
    lane.define_singleton_method(:authorize_deployment) { |_| calls << :authorize; MERGED_SHA }
    lane.define_singleton_method(:prepare_ci_signing) { calls << :signing }
    lane.define_singleton_method(:setup_ci) { calls << :keychain }
    lane.define_singleton_method(:asc_api_key) { calls << :credentials; :test_key }
    lane.define_singleton_method(:next_build_number) { |_| 49 }
    lane.define_singleton_method(:whats_new_notes) { "Test notes" }
    lane.define_singleton_method(:build_for_appstore) { |**_| calls << :archive }
    lane.define_singleton_method(:verify_deployment_target) { |_| calls << :revalidate }
    lane.define_singleton_method(:upload_to_testflight) { |**_| calls << :upload }
    lane.run(:beta)
    assert calls == [:authorize, :signing, :keychain, :credentials, :archive, :revalidate, :upload], calls.inspect
    record = JSON.parse(File.read(File.join(dir, "fastlane/testflight/last_shipped.json")))
    assert record["sha"] == MERGED_SHA && record["build"] == 49, record.inspect
  end
end

if $failures.zero?
  puts "all passed"
else
  puts "#{$failures} failed"
  exit 1
end
