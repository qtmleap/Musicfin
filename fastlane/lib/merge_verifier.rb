# 配信ワークフローの verify ジョブ専用。秘密を持たない Linux ジョブで、push が
# 「同じリポジトリの PR を develop / master へマージした新しい 1 回分」であることを確かめ、
# 保護された Environment を使う配信ジョブへ SHA と PR 番号だけを渡す。
# fastlane にも Xcode にも依存しない純 Ruby で、GitHub API と Git は注入できる。
# テストは fastlane/test/merge_verifier_test.rb。
require "json"
require "net/http"
require "open3"
require_relative "deployment_policy"

class MergeVerifier
  class Error < StandardError; end

  REPOSITORY = DeploymentPolicy::REPOSITORY
  BRANCHES = DeploymentPolicy::BRANCHES
  SHA_PATTERN = DeploymentPolicy::SHA_PATTERN
  WORKFLOW = ".github/workflows/deployment.yaml"
  PER_PAGE = 100
  # API が同じ大きさのページを返し続けても、無限に取得しないための上限。
  MAX_PAGES = 10

  # 信頼する PR 検証ワークフローと、その job 名（integration.yaml / release_validation.yaml と一致させる）。
  # 同名の別チェックを許さないよう、名前ではなく実行のパス・イベント・head から特定する。
  REQUIRED = {
    ".github/workflows/integration.yaml" => [
      "Commit Lint", "ShellCheck", "swift-format", "Build", "Unit Tests", "actionlint", "Fastlane Policy and Notes"
    ],
    ".github/workflows/release_validation.yaml" => ["Validate marketing version"]
  }.freeze

  class Api
    def initialize(token:)
      @token = token.to_s
      raise Error, "GITHUB_TOKEN が設定されていません。" if @token.empty?
    end

    def get(path)
      uri = URI("https://api.github.com/#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) { |http| http.request(request) }
      raise Error, "GitHub API #{path.split('?').first} が #{response.code} を返しました。" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end

  class Git
    def initialize(directory)
      @directory = directory
    end

    def call(*args)
      out, status = Open3.capture2("git", "-C", @directory, *args, err: File::NULL)
      raise Error, "git #{args.first} に失敗しました。" unless status.success?

      out
    end
  end

  def self.write_output(path, pr_number:, sha:)
    File.open(path, "a") { |file| file.write("pr_number=#{pr_number}\nsha=#{sha}\n") }
  end

  def initialize(env:, event:, api:, git:, sleeper: ->(seconds) { sleep(seconds) }, attempts: 6, delay: 10)
    @env = env
    @event = event
    @api = api
    @git = git
    @sleeper = sleeper
    @attempts = attempts
    @delay = delay
  end

  def call
    sha = @env.fetch("GITHUB_SHA", "")
    repo = @env.fetch("GITHUB_REPOSITORY", "")
    branch = @env.fetch("GITHUB_REF", "").delete_prefix("refs/heads/")
    verify_push(sha, repo, branch)
    parents = lineage(sha)
    pull = find_pull(repo, sha, branch)
    verify_second_parent(parents, pull)
    verify_checks(repo, pull)
    # 検証に時間がかかる間に次のマージが入っていないことを、最後にもう一度確かめる。
    tip = @api.get("repos/#{repo}/branches/#{branch}").dig("commit", "sha")
    raise Error, "#{branch} の先端が進んでいます。新しいマージが優先されます。" unless tip == sha

    { pr_number: pull.fetch("number"), sha: sha }
  end

  private

  def verify_push(sha, repo, branch)
    unless @env["GITHUB_ACTIONS"] == "true" && @env["RUNNER_ENVIRONMENT"] == "self-hosted"
      raise Error, "self-hosted runner の GitHub CI だけで実行できます。"
    end
    raise Error, "push イベントではありません。" unless @env["GITHUB_EVENT_NAME"] == "push"
    ref = @env["GITHUB_REF"]
    raise Error, "配信できないブランチです: #{branch}" unless ref == "refs/heads/#{branch}" && BRANCHES.include?(branch)
    raise Error, "CI の再実行では配信しません。" unless @env["GITHUB_RUN_ATTEMPT"] == "1"
    raise Error, "リポジトリが一致しません。" unless repo == REPOSITORY
    raise Error, "ワークフローが一致しません。" unless @env["GITHUB_WORKFLOW_REF"] == "#{repo}/#{WORKFLOW}@#{ref}"
    raise Error, "イベントの ref が GITHUB_REF と異なります。" unless @event.is_a?(Hash) && @event["ref"] == ref
    raise Error, "イベントのリポジトリが一致しません。" unless @event.dig("repository", "full_name") == repo
    raise Error, "ブランチの新規作成はマージではありません。" unless @event["created"] == false
    raise Error, "ブランチの削除はマージではありません。" unless @event["deleted"] == false
    raise Error, "強制 push は配信しません。" unless @event["forced"] == false
    raise Error, "GITHUB_SHA が不正です。" unless sha.match?(SHA_PATTERN)
    raise Error, "push の after が GITHUB_SHA と異なります。" unless @event["after"] == sha

    before = @event["before"]
    raise Error, "push の before が不正です。" unless before.is_a?(String) && before.match?(SHA_PATTERN)
    raise Error, "push の before が全てゼロです。" if before.match?(/\A0+\z/)
  rescue TypeError, NoMethodError
    raise Error, "push イベントが不正です。"
  end

  # 複数コミットをまとめた push を、単一のマージとして配信しないために親を照合する。
  # 単一コミットの直接 push は親が一致しうるので、別途マージ済み PR との照合も必要。
  # 配信記録だけの変更や空のマージは、配信の無限連鎖を避けるため配信しない。
  def lineage(sha)
    fields = @git.call("rev-list", "--parents", "-n", "1", sha).split
    raise Error, "マージコミットの親を取得できません。" unless fields.first == sha && fields.drop(1).all? { |p| p.match?(SHA_PATTERN) }

    parents = fields.drop(1)
    raise Error, "親の無いコミットは配信しません。" if parents.empty? || parents.length > 2
    raise Error, "first parent が push の before と一致しません。" unless parents.first == @event["before"]

    paths = @git.call("diff", "--name-only", "-z", "#{sha}^1", sha, "--").split("\0")
    unless paths.any? { |path| path != DeploymentPolicy::SHIPPED_RECORD }
      raise Error, "配信記録だけの変更、または変更の無いマージは配信しません。"
    end
    parents
  end

  # merge commit なら 2 つ目の親が PR の head。squash は親が 1 つだけで、head は別に確認する。
  def verify_second_parent(parents, pull)
    return if parents.length == 1
    raise Error, "2 つ目の親が PR の head と一致しません。" unless parents[1] == pull.dig("head", "sha")
  end

  # commits/:sha/pulls は反映が遅れることがあるので、有限回だけ待つ。
  def find_pull(repo, sha, branch)
    matches = []
    @attempts.times do |index|
      listed = @api.get("repos/#{repo}/commits/#{sha}/pulls?per_page=#{PER_PAGE}")
      matches = listed.map { |entry| entry.fetch("number") }.uniq.filter_map do |number|
        pull = @api.get("repos/#{repo}/pulls/#{number}")
        pull if acceptable_pull?(pull, repo, sha, branch)
      end
      break unless matches.empty?

      @sleeper.call(@delay) if index < @attempts - 1
    end
    raise Error, "#{sha} を生成したマージ済み PR が見つかりません。" if matches.empty?
    raise Error, "#{sha} を生成した PR が複数あり、特定できません。" unless matches.length == 1

    matches.first
  end

  def acceptable_pull?(pull, repo, sha, branch)
    pull["merged"] == true && pull["merge_commit_sha"] == sha && pull.dig("base", "ref") == branch &&
      pull.dig("base", "repo", "full_name") == repo && pull.dig("head", "repo", "full_name") == repo &&
      pull.dig("head", "sha").to_s.match?(SHA_PATTERN) && !pull.dig("head", "ref").to_s.empty?
  end

  # マージ後は PR の紐づく配列が空になるので使わず、実行のパス・イベント・head・元ブランチで信頼を決める。
  def verify_checks(repo, pull)
    head = pull.dig("head", "sha")
    runs = paginate("repos/#{repo}/actions/runs?head_sha=#{head}&per_page=#{PER_PAGE}", "workflow_runs")
    checks = paginate("repos/#{repo}/commits/#{head}/check-runs?per_page=#{PER_PAGE}&filter=latest", "check_runs")
    problems = []
    REQUIRED.each do |path, names|
      trusted = runs.select do |run|
        run["path"] == path && run["event"] == "pull_request" && run["head_sha"] == head &&
          run["head_branch"] == pull.dig("head", "ref") && run.dig("head_repository", "full_name") == repo
      end
      latest = trusted.max_by { |run| [run["run_number"].to_i, run["run_attempt"].to_i, run["id"].to_i] }
      unless latest && latest["status"] == "completed" && latest["conclusion"] == "success"
        problems << path
        next
      end
      names.each do |name|
        candidates = checks.select do |check|
          check["name"] == name && check.dig("app", "slug") == "github-actions" && check["head_sha"] == head &&
            check.dig("check_suite", "id") == latest["check_suite_id"]
        end
        check = candidates.max_by { |entry| entry["id"].to_i }
        problems << name unless check && check["status"] == "completed" && check["conclusion"] == "success"
      end
    end
    raise Error, "PR の head で必須チェックが成功していません: #{problems.join(', ')}" unless problems.empty?
  end

  def paginate(path, key)
    items = []
    (1..MAX_PAGES).each do |page|
      batch = @api.get("#{path}&page=#{page}").fetch(key)
      items.concat(batch)
      return items if batch.length < PER_PAGE
    end
    raise Error, "#{key} が #{MAX_PAGES * PER_PAGE} 件を超えており、確認できません。"
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    result = MergeVerifier.new(
      env: ENV.to_h,
      event: JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH"))),
      api: MergeVerifier::Api.new(token: ENV["GITHUB_TOKEN"]),
      git: MergeVerifier::Git.new(Dir.pwd)
    ).call
    MergeVerifier.write_output(ENV.fetch("GITHUB_OUTPUT"), **result)
    puts "verified: PR ##{result[:pr_number]} -> #{result[:sha]}"
  rescue MergeVerifier::Error, JSON::ParserError, KeyError, SystemCallError => error
    warn "::error::#{error.message}"
    exit 1
  end
end
