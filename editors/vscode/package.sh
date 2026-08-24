#!/bin/sh
# Build the .vsix, without vsce.
#
# A .vsix is an OPC zip: the extension under extension/, a manifest beside it, and the content-type
# map OPC insists on. vsce writes those three and zips -- but vsce pulls undici, which wants Node 20,
# and this machine has 18. Twenty lines here instead of a Node upgrade for a zip file.
#
# Usage: editors/vscode/package.sh [output directory]

set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here}
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

command -v zip >/dev/null || { echo "[FAIL] zip is needed to build a .vsix" >&2; exit 2; }
[ -d "$here/node_modules/vscode-languageclient" ] || {
	echo "[FAIL] no node_modules -- run \`npm install\` in editors/vscode first" >&2; exit 2; }

name=$(node -p "require('$here/package.json').name")
version=$(node -p "require('$here/package.json').version")
publisher=$(node -p "require('$here/package.json').publisher")
display=$(node -p "require('$here/package.json').displayName")
summary=$(node -p "require('$here/package.json').description")
engine=$(node -p "require('$here/package.json').engines.vscode")

stage=$(mktemp -d)
mkdir -p "$stage/extension"
cp -r "$here/package.json" "$here/language-configuration.json" "$here/syntaxes" "$here/src" \
      "$here/README.md" "$here/node_modules" "$stage/extension/"

cat > "$stage/[Content_Types].xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
	<Default Extension="json" ContentType="application/json"/>
	<Default Extension="js" ContentType="application/javascript"/>
	<Default Extension="ts" ContentType="text/plain"/>
	<Default Extension="map" ContentType="application/json"/>
	<Default Extension="md" ContentType="text/markdown"/>
	<Default Extension="txt" ContentType="text/plain"/>
	<Default Extension="yml" ContentType="text/plain"/>
	<Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
XML

cat > "$stage/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
	<Metadata>
		<Identity Language="en-US" Id="$name" Version="$version" Publisher="$publisher"/>
		<DisplayName>$display</DisplayName>
		<Description xml:space="preserve">$summary</Description>
		<Tags>oberon,active oberon,a2,lsp</Tags>
		<Categories>Programming Languages</Categories>
		<GalleryFlags>Public</GalleryFlags>
		<Properties>
			<Property Id="Microsoft.VisualStudio.Code.Engine" Value="$engine"/>
			<Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value=""/>
			<Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value=""/>
			<Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
			<Property Id="Microsoft.VisualStudio.Services.Links.Source" Value="https://github.com/active-oberon/minia2"/>
		</Properties>
	</Metadata>
	<Installation>
		<InstallationTarget Id="Microsoft.VisualStudio.Code"/>
	</Installation>
	<Dependencies/>
	<Assets>
		<Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
		<Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true"/>
	</Assets>
</PackageManifest>
XML

vsix="$out/$name-$version.vsix"
rm -f "$vsix"
mkdir -p "$out"
( cd "$stage" && zip -q -r -X "$vsix" '[Content_Types].xml' extension.vsixmanifest extension )
rm -rf "$stage"

echo "$vsix"
