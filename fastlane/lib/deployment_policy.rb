# 作業ツリーや別ブランチの配信で機能が巻き戻らないよう、CI のマージ対象だけ許可する。
require "json"
require "open3"
require "base64"
require_relative "testflight_notes"

module DeploymentPolicy
  class Error < StandardError; end

  REPOSITORY = "qtmleap/Musicfin"
  BRANCHES = %w[develop master].freeze
  SHIPPED_RECORD = "fastlane/testflight/last_shipped.json"
  SHA_PATTERN = /\A[0-9a-f]{40}\z/

  module_function

  # 組織で deploy key が禁止されていても、署名リポジトリへの読み取り権限だけで配信する。
  def signing_environment!(env:)
    token = env["MATCH_GIT_TOKEN"].to_s.strip
    has_token = !token.empty?
    private_key = env["MATCH_GIT_PRIVATE_KEY"].to_s
    has_key = !private_key.strip.empty?
    if has_token == has_key
      raise Error, "署名用の MATCH_GIT_TOKEN または MATCH_GIT_PRIVATE_KEY を一方だけ設定してください。"
    end

    if has_key
      env["MATCH_GIT_URL"] = "git@github.com:qtmleap/match.git"
      env.delete("MATCH_GIT_BASIC_AUTHORIZATION")
    else
      env["MATCH_GIT_URL"] = "https://github.com/qtmleap/match.git"
      env["MATCH_GIT_BASIC_AUTHORIZATION"] = Base64.strict_encode64("x-access-token:#{token}")
      env.delete("MATCH_GIT_PRIVATE_KEY")
    end
  end

  def environment!(lane:, env:)
    raise Error, "配信は develop または master マージ時の CI beta だけで実行できます。App Store release は無効です。" unless lane.to_s == "beta"
    unless env["GITHUB_ACTIONS"] == "true" && env["GITHUB_EVENT_NAME"] == "pull_request"
      raise Error, "配信は develop または master マージ時の GitHub CI だけで実行できます。"
    end
    unless env["RUNNER_ENVIRONMENT"] == "self-hosted"
      raise Error, "配信は self-hosted runner の CI だけで実行できます。"
    end
    branch = env["GITHUB_REF"].to_s.delete_prefix("refs/heads/")
    unless env["GITHUB_REPOSITORY"] == REPOSITORY && BRANCHES.include?(branch) &&
           env["GITHUB_REF"] == "refs/heads/#{branch}" &&
           env["GITHUB_WORKFLOW_REF"] == "#{REPOSITORY}/.github/workflows/deployment.yaml@refs/heads/#{branch}"
      raise Error, "配信元の CI リポジトリ・ブランチ・ワークフローが一致しません。"
    end
    raise Error, "二重配信を防ぐため CI の再実行は許可しません。" unless env["GITHUB_RUN_ATTEMPT"] == "1"
    branch
  end

  def context!(lane:, env:, event:)
    branch = environment!(lane: lane, env: env)
    unless event.is_a?(Hash) && event["action"] == "closed" &&
           event.dig("repository", "full_name") == REPOSITORY &&
           event.dig("pull_request", "merged") == true && event.dig("pull_request", "state") == "closed" &&
           event.dig("pull_request", "base", "ref") == branch &&
           event.dig("pull_request", "base", "repo", "full_name") == REPOSITORY &&
           event.dig("pull_request", "head", "repo", "full_name") == REPOSITORY
      raise Error, "同じリポジトリから develop または master へマージされた PR だけ配信できます。"
    end
    sha = event.dig("pull_request", "merge_commit_sha")
    unless sha.is_a?(String) && sha.match?(SHA_PATTERN) && env["GITHUB_SHA"] == sha
      raise Error, "CI の SHA と PR のマージ SHA が一致しません。"
    end
    sha
  rescue TypeError
    raise Error, "CI の PR イベントが不正です。"
  end

  def current!(sha:, head_sha:, branch_sha:, dirty_count:)
    unless head_sha == sha && branch_sha == sha
      raise Error, "配信対象は最新のマージ先ブランチと一致するマージ SHA である必要があります。"
    end
    raise Error, "未コミットの変更がある、または Git の状態を確認できないため配信しません。" unless dirty_count == 0
  end

  def validate!(lane:, env:, event:, head_sha:, branch_sha:, dirty_count:, changed_paths:)
    sha = context!(lane: lane, env: env, event: event)
    current!(sha: sha, head_sha: head_sha, branch_sha: branch_sha, dirty_count: dirty_count)
    unless changed_paths.is_a?(Array) && changed_paths.all? { |path| path.is_a?(String) && !path.empty? } &&
           changed_paths.any? { |path| path != SHIPPED_RECORD }
      raise Error, "配信記録だけの変更、または変更の無いマージは配信しません。"
    end
    sha
  end

  def git_output(repo_root, *arguments)
    output, status = Open3.capture2e("git", "-C", repo_root, *arguments)
    raise Error, "配信対象の Git 情報を取得できません。" unless status.success?
    output
  rescue SystemCallError
    raise Error, "配信対象の Git 情報を取得できません。"
  end

  # キャッシュされた追跡ブランチでは、待機中に入った新しいマージを検出できない。
  def branch_sha(repo_root, branch:)
    raise Error, "配信先ブランチが許可されていません。" unless BRANCHES.include?(branch)
    ref = "refs/heads/#{branch}"
    output = git_output(repo_root, "ls-remote", "--exit-code", "origin", ref)
    fields = output.strip.split(/\s+/)
    unless fields.size == 2 && fields[0].match?(SHA_PATTERN) && fields[1] == ref
      raise Error, "最新のマージ先ブランチの SHA を取得できません。"
    end
    fields[0]
  end

  def authorize!(lane:, repo_root:, env: ENV)
    # ローカルではイベントファイルや認証情報へ進む前に必ず止める。
    branch = environment!(lane: lane, env: env)
    event = JSON.parse(File.read(env.fetch("GITHUB_EVENT_PATH")))
    sha = context!(lane: lane, env: env, event: event)
    paths = git_output(repo_root, "diff", "--name-only", "-z", "#{sha}^1", sha, "--").split("\0")
    validate!(
      lane: lane, env: env, event: event,
      head_sha: TestflightNotes.head_sha(repo_root),
      branch_sha: branch_sha(repo_root, branch: branch),
      dirty_count: TestflightNotes.dirty_count(repo_root),
      changed_paths: paths
    )
  rescue JSON::ParserError, KeyError, SystemCallError, IOError
    raise Error, "CI の PR イベントを読み取れないため配信しません。"
  end

  # アーカイブ中にマージ先が進んだ場合も、別ブランチの先端で古いビルドを許可しない。
  def verify_current!(repo_root:, sha:, env: ENV)
    branch = environment!(lane: :beta, env: env)
    event = JSON.parse(File.read(env.fetch("GITHUB_EVENT_PATH")))
    unless context!(lane: :beta, env: env, event: event) == sha
      raise Error, "アーカイブ開始時と CI のマージ SHA が一致しません。"
    end
    current!(
      sha: sha,
      head_sha: TestflightNotes.head_sha(repo_root),
      branch_sha: branch_sha(repo_root, branch: branch),
      dirty_count: TestflightNotes.dirty_count(repo_root)
    )
  rescue JSON::ParserError, KeyError, SystemCallError, IOError
    raise Error, "CI の PR イベントを読み取れないため配信しません。"
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    root = File.expand_path("../..", __dir__)
    sha = DeploymentPolicy.authorize!(lane: :beta, repo_root: root)
    puts "CI deployment target: #{sha}"
  rescue DeploymentPolicy::Error => error
    warn error.message
    exit 1
  end
end
