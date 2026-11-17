#!/bin/zsh
# Builds an unsigned Release .ipa for SideStore, AltStore or Feather, which sign
# it on install, and points the app source at it.
#
#   scripts/build-ipa.sh            → build/Lily.ipa, and docs/source.json updated
#
# Publish the release as v<version> with Lily.ipa attached before pushing
# docs/source.json, or the stores will find nothing at its download link. Once
# a version is out, bump MARKETING_VERSION before building again: a rebuild
# rewrites that version's entry, which would no longer match the released file.
set -euo pipefail
root=${0:A:h:h}
out=$root/build
derived=$out/DerivedData
app=$derived/Build/Products/Release-iphoneos/Lily.app
source=$root/docs/source.json

rm -rf "$out/Payload" "$out/Lily.ipa"
# Post-processing strips the symbol table, which otherwise names every source
# file and object file by its full path on this Mac.
xcodebuild -project "$root/Lily.xcodeproj" -scheme Lily -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEPLOYMENT_POSTPROCESSING=YES \
  build -quiet

mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
if grep -rqaF -e "$HOME" "$out/Payload"; then
  print -u2 "Lily.app still holds paths under $HOME; not packaging it."
  exit 1
fi
# ditto keeps the bundle's symlinks and permissions as an .ipa needs them.
(cd "$out" && ditto -c -k --norsrc --keepParent Payload Lily.ipa)
rm -rf "$out/Payload"

info() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Info.plist"; }
# Assigned first, as set -e ignores a failing substitution inside an argument list.
version=$(info CFBundleShortVersionString)
build=$(info CFBundleVersion)
min_os=$(info MinimumOSVersion)
size=$(stat -f%z "$out/Lily.ipa")
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
osascript -l JavaScript -e '
ObjC.import("Foundation")
function run([path, version, buildVersion, minOSVersion, size, date]) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  const source = JSON.parse(text.js)
  const versions = source.apps[0].versions
  const releases = "https://github.com/Visxoz/Lily-ios/releases/"
  const entry = { version, buildVersion, date, downloadURL: releases + "download/v" + version + "/Lily.ipa", size: Number(size), minOSVersion }
  if (versions[0]?.version === version) Object.assign(versions[0], entry)
  else versions.unshift({ ...entry, localizedDescription: "Release notes: " + releases + "tag/v" + version })
  if (!$(JSON.stringify(source, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null))
    throw new Error("Could not write " + path)
}' "$source" "$version" "$build" "$min_os" "$size" "$now"

print "Built $out/Lily.ipa ($(du -h "$out/Lily.ipa" | cut -f1)), version $version ($build), in docs/source.json"
