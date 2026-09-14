#!/bin/sh
#
# Install the Agents extension into this VS Code server.
#
# The extension is three files and has no dependencies, so it is packaged here
# with zip rather than through vsce: a .vsix is an OPC zip holding the manifest
# pair plus an extension/ directory, and building it in place keeps container
# attach offline and keeps a build toolchain out of the repository.
#
# Musicfin has no devcontainer, so start-agents.sh runs this on every launch
# instead of a postAttachCommand hook; it exits early when the installed version
# already matches. Bump "version" in package.json after changing extension.js,
# or the new code will not be picked up.
#
# Installing does not load the extension: VS Code reads the extensions directory
# when a window opens, so the commands appear after the next reload.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
ID=local.agents

command -v code >/dev/null 2>&1 || exit 0
command -v zip >/dev/null 2>&1 || exit 0

VERSION=$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$DIR/package.json")
[ -n "$VERSION" ] || exit 0

code --list-extensions --show-versions 2>/dev/null | grep -qx "$ID@$VERSION" && exit 0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/extension"
cp "$DIR/package.json" "$DIR/extension.js" "$WORK/extension/"

cat > "$WORK/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
XML

cat > "$WORK/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="agents" Version="$VERSION" Publisher="local"/>
    <DisplayName>Agents</DisplayName>
    <Description xml:space="preserve">Command palette entries for the tmux agent session.</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.75.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
XML

(cd "$WORK" && zip -q -r agents.vsix '[Content_Types].xml' extension.vsixmanifest extension)
code --install-extension "$WORK/agents.vsix" --force
