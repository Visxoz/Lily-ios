#!/bin/zsh
# Builds an unsigned Release .ipa for SideStore, which signs it with the
# user's own Apple ID on install.
#
#   scripts/build-ipa.sh            → build/Lily.ipa
set -euo pipefail
root=${0:A:h:h}
out=$root/build
derived=$out/DerivedData
app=$derived/Build/Products/Release-iphoneos/Lily.app

rm -rf "$out/Payload" "$out/Lily.ipa"
xcodebuild -project "$root/Lily.xcodeproj" -scheme Lily -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build -quiet

mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
# ditto keeps the bundle's symlinks and permissions as an .ipa needs them.
(cd "$out" && ditto -c -k --norsrc --keepParent Payload Lily.ipa)
rm -rf "$out/Payload"
print "Built $out/Lily.ipa ($(du -h "$out/Lily.ipa" | cut -f1))"
