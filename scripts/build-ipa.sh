#!/bin/zsh
# Builds an unsigned Release .ipa for SideStore, which signs it with the
# user's own Apple ID on install.
#
#   scripts/build-ipa.sh            → build/YTMusic.ipa
set -euo pipefail
root=${0:A:h:h}
out=$root/build
derived=$out/DerivedData
app=$derived/Build/Products/Release-iphoneos/YTMusic.app

rm -rf "$out/Payload" "$out/YTMusic.ipa"
xcodebuild -project "$root/YTMusic.xcodeproj" -scheme YTMusic -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build -quiet

mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
# ditto keeps the bundle's symlinks and permissions as an .ipa needs them.
(cd "$out" && ditto -c -k --norsrc --keepParent Payload YTMusic.ipa)
rm -rf "$out/Payload"
print "Built $out/YTMusic.ipa ($(du -h "$out/YTMusic.ipa" | cut -f1))"
