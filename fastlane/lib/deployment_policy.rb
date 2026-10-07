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

  # verify ジョブの出力。push だけでは PR のマージかどうか分からないので、必ず要求する。
  VERIFIED_SHA = "MUSICFIN_VERIFIED_SHA"
  VERIFIED_PR = "MUSICFIN_VERIFIED_PR"

  # ビルドの子プロセス (xcodebuild など) へ渡さない資格情報。署名用 App の鍵は入力専用だが、
  # 環境変数に残っていても届かないよう多重に防ぐ。
  SCRUBBED_EXACT = %w[
    GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    MATCH_PASSWORD MATCH_GIT_TOKEN MATCH_GIT_BASIC_AUTHORIZATION MATCH_GIT_PRIVATE_KEY
    MATCH_KEYCHAIN_PASSWORD MATCH_APP_CLIENT_ID MATCH_APP_PRIVATE_KEY
  ].freeze
  SCRUBBED_PREFIXES = %w[ASC_ APP_STORE_CONNECT_API_KEY_].freeze

  module_function

  # ブロックの間だけ資格情報を外し、例外でも元の値へ厳密に戻す。元から無い変数は無いままにする。
  def without_credentials(env = ENV)
    saved = env.keys.select do |name|
      SCRUBBED_EXACT.include?(name) || SCRUBBED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
    end.to_h { |name| [name, env[name]] }
    saved.each_key { |name| env.delete(name) }
    begin
      yield
    ensure
      saved.each { |name, value| env[name] = value }
    end
  end

  # Actions のマスクは元の値しか隠さないので、token から作った base64 も登録する。
  def mask_lines(env)
    authorization = env["MATCH_GIT_BASIC_AUTHORIZATION"].to_s
    authorization.empty? ? [] : ["::add-mask::#{authorization}"]
  end

  # 署名リポジトリへの読み取り権限だけを持つ短命 token で配信する。
  # ssh: true はローカルでの互換用 (deploy key)。CI の beta は ssh: false で token だけを許す。
  def signing_environment!(env:, ssh: true)
    token = env["MATCH_GIT_TOKEN"].to_s.strip
    has_token = !token.empty?
    has_key = !env["MATCH_GIT_PRIVATE_KEY"].to_s.strip.empty?
    raise Error, "CI の署名には短命の MATCH_GIT_TOKEN だけを使います。" if has_key && !ssh
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
    unless env["GITHUB_ACTIONS"] == "true" && env["GITHUB_EVENT_NAME"] == "push"
      raise Error, "配信は develop または master へのマージ push 時の GitHub CI だけで実行できます。"
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
    unless env["GITHUB_SHA"].to_s.match?(SHA_PATTERN) && env[VERIFIED_SHA] == env["GITHUB_SHA"] &&
           env[VERIFIED_PR].to_s.match?(/\A[1-9]\d{0,9}\z/)
      raise Error, "マージ検証ジョブの結果が無い、または CI の SHA と一致しません。"
    end
    branch
  end

  # 検証済みの SHA を返し、push の before を first parent との照合用に返す。
  def context!(lane:, env:, event:)
    branch = environment!(lane: lane, env: env)
    sha = env["GITHUB_SHA"]
    unless event.is_a?(Hash) && event["ref"] == "refs/heads/#{branch}" &&
           event.dig("repository", "full_name") == REPOSITORY &&
           event["created"] == false && event["deleted"] == false && event["forced"] == false &&
           event["after"] == sha && event["before"].is_a?(String) &&
           event["before"].match?(SHA_PATTERN) && !event["before"].match?(/\A0+\z/)
      raise Error, "新規作成・削除・強制 push ではない、マージ push だけ配信できます。"
    end
    [sha, event["before"]]
  rescue TypeError, NoMethodError
    raise Error, "CI の push イベントが不正です。"
  end

  def current!(sha:, head_sha:, branch_sha:, dirty_count:)
    unless head_sha == sha && branch_sha == sha
      raise Error, "配信対象は最新のマージ先ブランチと一致するマージ SHA である必要があります。"
    end
    raise Error, "未コミットの変更がある、または Git の状態を確認できないため配信しません。" unless dirty_count == 0
  end

  def validate!(lane:, env:, event:, head_sha:, branch_sha:, dirty_count:, first_parent:, changed_paths:)
    sha, before = context!(lane: lane, env: env, event: event)
    current!(sha: sha, head_sha: head_sha, branch_sha: branch_sha, dirty_count: dirty_count)
    raise Error, "直接 push など、first parent が push の before と一致しないため配信しません。" unless first_parent == before
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

  def read_event(env)
    JSON.parse(File.read(env.fetch("GITHUB_EVENT_PATH")))
  rescue JSON::ParserError, KeyError, SystemCallError, IOError
    raise Error, "CI の push イベントを読み取れないため配信しません。"
  end

  def authorize!(lane:, repo_root:, env: ENV)
    # ローカルではイベントファイルや認証情報へ進む前に必ず止める。
    branch = environment!(lane: lane, env: env)
    event = read_event(env)
    sha, = context!(lane: lane, env: env, event: event)
    parent = git_output(repo_root, "rev-parse", "--verify", "#{sha}^1^{commit}").strip
    paths = git_output(repo_root, "diff", "--name-only", "-z", "#{sha}^1", sha, "--").split("\0")
    validate!(
      lane: lane, env: env, event: event,
      head_sha: TestflightNotes.head_sha(repo_root),
      branch_sha: branch_sha(repo_root, branch: branch),
      dirty_count: TestflightNotes.dirty_count(repo_root),
      first_parent: parent,
      changed_paths: paths
    )
  end

  # アーカイブ中にマージ先が進んだ場合も、古いビルドを許可しない。
  def verify_current!(repo_root:, sha:, env: ENV)
    branch = environment!(lane: :beta, env: env)
    event = read_event(env)
    unless context!(lane: :beta, env: env, event: event).first == sha
      raise Error, "アーカイブ開始時と CI のマージ SHA が一致しません。"
    end
    current!(
      sha: sha,
      head_sha: TestflightNotes.head_sha(repo_root),
      branch_sha: branch_sha(repo_root, branch: branch),
      dirty_count: TestflightNotes.dirty_count(repo_root)
    )
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
