# 配信ワークフローの verify ジョブ専用。秘密を持たない Linux ジョブで、push が
# 「同じリポジトリの PR を develop / master へマージした新しい 1 回分」であることを確かめ、
# 保護された Environment を使う配信ジョブへ SHA と PR 番号だけを渡す。
# fastlane にも Xcode にも依存しない純 Ruby で、GitHub API と Git は注入できる。
# テストは fastlane/test/merge_verifier_test.rb。
require "json"
require_relative "shared_actions_loader"
require_relative "deployment_policy"
SharedActionsLoader.load!(app_root: File.expand_path("../..", __dir__))
require File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime/compatibility")

MergeVerifier = SharedCI.merge_wrapper(
  error_class: StandardError,
  config: {
    repository: DeploymentPolicy::REPOSITORY, branches: DeploymentPolicy::BRANCHES,
    workflow: ".github/workflows/deployment.yaml",
    required_checks: {
    ".github/workflows/integration.yaml" => [
      "Commit Lint", "ShellCheck", "swift-format", "Build", "Unit Tests", "actionlint", "Fastlane Policy and Notes"
    ],
    ".github/workflows/release_validation.yaml" => ["Validate marketing version"]
  }.freeze,
    record_only_paths: [DeploymentPolicy::SHIPPED_RECORD]
  }
)

if __FILE__ == $PROGRAM_NAME
  begin
    result = MergeVerifier.new(env: ENV.to_h,
      event: JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH"))),
      api: MergeVerifier::Api.new(token: ENV["GITHUB_TOKEN"]), git: MergeVerifier::Git.new(Dir.pwd)).call
    MergeVerifier.write_output(ENV.fetch("GITHUB_OUTPUT"), **result)
  rescue MergeVerifier::Error, JSON::ParserError, KeyError, SystemCallError
    warn "Merge verification failed"
    exit 1
  end
end
