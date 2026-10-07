# 共通の組織 Secret が存在しても、専用 Environment の資格情報だけを参照する。
require "yaml"
workflow = YAML.load_file(File.expand_path("../../.github/workflows/deployment.yaml", __dir__))
def secret_references(value)
  case value
  when Hash then value.values.flat_map { |child| secret_references(child) }
  when Array then value.flat_map { |child| secret_references(child) }
  when String then value.scan(/secrets\.([A-Za-z_][A-Za-z0-9_]*)/).flatten
  else []
  end
end
raise "shared deployment credential fallback" unless secret_references(workflow).all? { |name| name.start_with?("MUSICFIN_") }
deploy = workflow.fetch("jobs").fetch("deploy")
raise "deployment must use testflight" unless deploy["environment"] == "testflight"
step = deploy.fetch("steps").find { |s| s["name"] == "Deploy" }
{
  "ASC_KEY_ID" => "MUSICFIN_ASC_KEY_ID",
  "ASC_ISSUER_ID" => "MUSICFIN_ASC_ISSUER_ID",
  "ASC_KEY_CONTENT" => "MUSICFIN_ASC_KEY_CONTENT",
  "MATCH_PASSWORD" => "MUSICFIN_MATCH_PASSWORD"
}.each do |variable, name|
  raise "#{variable} could fall back to a shared secret" unless step.fetch("env").fetch(variable) == "${{ secrets.#{name} }}"
end
app = deploy.fetch("steps").find { |s| s["uses"].to_s.start_with?("actions/create-github-app-token@") }
raise "shared App ID fallback" unless app.fetch("with").fetch("client-id") == "${{ secrets.MUSICFIN_MATCH_APP_CLIENT_ID }}"
raise "shared App key fallback" unless app.fetch("with").fetch("private-key") == "${{ secrets.MUSICFIN_MATCH_APP_PRIVATE_KEY }}"
puts "Environment-only deployment credential references passed"
