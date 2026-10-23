#!/bin/sh
# Makes an unsigned .ipa from an archive, for sideloading tools that sign it with the user's own
# Apple ID. No profile or signature is left, so nothing names our team or devices.
# Usage: ios/unsigned-ipa.sh PhotoWagon.xcarchive out.ipa
set -eu
archive=$1
out=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/Payload"
cp -R "$archive/Products/Applications/PhotoWagon.app" "$dir/Payload/"
app=$dir/Payload/PhotoWagon.app
rm -f "$app/embedded.mobileprovision"
find "$app" -type f | while read -r f; do
  if file -b "$f" | grep -q Mach-O && codesign -d "$f" 2>/dev/null; then codesign --remove-signature "$f"; fi
done
find "$app" -name _CodeSignature -type d -prune -exec rm -rf {} +
rm -f "$out"
(cd "$dir" && zip -qry "$out" Payload)
echo "unsigned-ipa: $out"
