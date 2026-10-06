# 配信を伴う依存だけを止め、実際の lane が認証より先に拒否することを検証する。
require "json"
require "tmpdir"
require "rbconfig"

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

def allowed_fixture(branch = "develop")
  {
    lane: :beta,
    env: {
      "GITHUB_ACTIONS" => "true",
      "GITHUB_EVENT_NAME" => "pull_request",
      "GITHUB_REPOSITORY" => "qtmleap/Musicfin",
      "GITHUB_REF" => "refs/heads/#{branch}",
      "GITHUB_WORKFLOW_REF" => "qtmleap/Musicfin/.github/workflows/deployment.yaml@refs/heads/#{branch}",
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
        "base" => { "ref" => branch, "repo" => { "full_name" => "qtmleap/Musicfin" } },
        "head" => { "repo" => { "full_name" => "qtmleap/Musicfin" } }
      }
    },
    head_sha: MERGED_SHA,
    branch_sha: MERGED_SHA,
    dirty_count: 0,
    changed_paths: ["Musicfin/App/RootView.swift"]
  }
end

["develop", "master"].each do |branch|
  check "the exact current #{branch} merge from this repository is accepted" do
    assert DeploymentPolicy.validate!(**allowed_fixture(branch)) == MERGED_SHA
  end
end

cases = {
  "local execution" => ->(f) { f[:env]["GITHUB_ACTIONS"] = nil },
  "manual dispatch" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "workflow_dispatch" },
  "direct branch push" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "push" },
  "tag push" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "push"; f[:env]["GITHUB_REF"] = "refs/tags/v0.1.0" },
  "tag ref" => ->(f) { f[:env]["GITHUB_REF"].sub!("refs/heads/", "refs/tags/") },
  "open PR" => ->(f) { f[:event]["action"] = "opened" },
  "unmerged PR" => ->(f) { f[:event]["pull_request"]["merged"] = false },
  "open PR state" => ->(f) { f[:event]["pull_request"]["state"] = "open" },
  "mismatched base" => ->(f) { f[:event]["pull_request"]["base"]["ref"] = f[:event]["pull_request"]["base"]["ref"] == "develop" ? "master" : "develop" },
  "mismatched ref" => ->(f) { f[:env]["GITHUB_REF"] = f[:env]["GITHUB_REF"] == "refs/heads/develop" ? "refs/heads/master" : "refs/heads/develop" },
  "mismatched workflow branch" => ->(f) { f[:env]["GITHUB_WORKFLOW_REF"] = f[:env]["GITHUB_WORKFLOW_REF"].sub(/(develop|master)\z/) { |b| b == "develop" ? "master" : "develop" } },
  "other workflow" => ->(f) { f[:env]["GITHUB_WORKFLOW_REF"].sub!("deployment.yaml", "integration.yaml") },
  "unapproved branch" => ->(f) {
    f[:event]["pull_request"]["base"]["ref"] = "feature"
    f[:env]["GITHUB_REF"] = "refs/heads/feature"
    f[:env]["GITHUB_WORKFLOW_REF"] = "qtmleap/Musicfin/.github/workflows/deployment.yaml@refs/heads/feature"
  },
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
  "obsolete merge" => ->(f) { f[:branch_sha] = OTHER_SHA },
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

def with_git_fixture(branch)
  Dir.mktmpdir do |dir|
    event_path = File.join(dir, "event.json")
    refs_path = File.join(dir, "refs.json")
    fixture = allowed_fixture(branch)
    File.write(event_path, JSON.generate(fixture[:event]))
    refs = { "develop" => OTHER_SHA, "master" => OTHER_SHA, branch => MERGED_SHA }
    File.write(refs_path, JSON.generate(refs))
    File.write(File.join(dir, "git"), <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      args = ARGV.drop(2)
      case args
      when ["rev-parse", "--verify", "HEAD^{commit}"]
        puts #{MERGED_SHA.inspect}
      when ["status", "--porcelain", "-z", "--untracked-files=all"]
      when ["diff", "--name-only", "-z", "#{MERGED_SHA}^1", #{MERGED_SHA.inspect}, "--"]
        print "Musicfin/App/RootView.swift\\0"
      when ["ls-remote", "--exit-code", "origin", "refs/heads/develop"],
           ["ls-remote", "--exit-code", "origin", "refs/heads/master"]
        ref = args.last
        sha = JSON.parse(File.read(#{refs_path.inspect})).fetch(ref.delete_prefix("refs/heads/"))
        puts "\#{sha}\\t\#{ref}"
      else
        abort "Unexpected Git query: \#{args.inspect}"
      end
    RUBY
    File.chmod(0o755, File.join(dir, "git"))
    with_environment(fixture[:env].merge("GITHUB_EVENT_PATH" => event_path, "PATH" => "#{dir}:#{ENV.fetch('PATH')}")) do
      yield dir, refs_path, refs
    end
  end
end

["develop", "master"].each do |branch|
  cases.each do |name, mutate|
    check "#{branch} rejects #{name}" do
      fixture = allowed_fixture(branch)
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

  check "#{branch} upload revalidation rejects a changed event or archive SHA" do
    with_git_fixture(branch) do |dir, _, _|
      sha = DeploymentPolicy.authorize!(lane: :beta, repo_root: dir)
      [OTHER_SHA, sha].each do |archive_sha|
        if archive_sha == sha
          event = allowed_fixture(branch == "develop" ? "master" : "develop")[:event]
          File.write(ENV.fetch("GITHUB_EVENT_PATH"), JSON.generate(event))
        end
        error = begin
          DeploymentPolicy.verify_current!(repo_root: dir, sha: archive_sha)
          nil
        rescue DeploymentPolicy::Error => e
          e
        end
        assert error, "revalidation accepted a different event or archive SHA"
      end
    end
  end

  ["#{MERGED_SHA}\trefs/heads/feature\n", "invalid\trefs/heads/#{branch}\n", "", "#{MERGED_SHA}\trefs/heads/#{branch}\n#{OTHER_SHA}\trefs/heads/master\n"].each do |output|
    check "#{branch} lookup rejects an invalid remote response #{output.inspect}" do
      policy = DeploymentPolicy.dup
      policy.define_singleton_method(:git_output) { |*_| output }
      error = begin
        policy.branch_sha("fixture", branch: branch)
        nil
      rescue DeploymentPolicy::Error => e
        e
      end
      assert error, "invalid remote response was accepted"
    end
  end
end

["develop", "master"].each do |branch|
  check "#{branch} authorization and upload revalidation use its live tip" do
    with_git_fixture(branch) do |dir, refs_path, refs|
      sha = DeploymentPolicy.authorize!(lane: :beta, repo_root: dir)
      assert sha == MERGED_SHA
      DeploymentPolicy.verify_current!(repo_root: dir, sha: sha)
      refs[branch] = OTHER_SHA
      refs[branch == "develop" ? "master" : "develop"] = MERGED_SHA
      File.write(refs_path, JSON.generate(refs))
      [:authorize, :revalidate].each do |operation|
        error = begin
          if operation == :authorize
            DeploymentPolicy.authorize!(lane: :beta, repo_root: dir)
          else
            DeploymentPolicy.verify_current!(repo_root: dir, sha: sha)
          end
          nil
        rescue DeploymentPolicy::Error => e
          e
        end
        assert error, "#{operation} accepted a stale #{branch} tip because the other branch matched"
      end
    end
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

check "the deployment branch advancing during archive stops the lane before upload and recording" do
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
      DeploymentPolicy.current!(sha: sha, head_sha: sha, branch_sha: OTHER_SHA, dirty_count: 0)
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
