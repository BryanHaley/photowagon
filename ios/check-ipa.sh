#!/bin/sh
# Checks a signed .ipa before upload: App Store signing, device-only code, no leaked secrets.
# Usage: ios/check-ipa.sh PhotoWagon.ipa
set -eu
ipa=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
unzip -q "$ipa" -d "$dir"
app=$(echo "$dir"/Payload/*.app)
fail() { echo "check-ipa: $*" >&2; exit 1; }

codesign --verify --deep --strict "$app" || fail "the signature doesn't verify"
codesign -dvv "$app" 2>&1 | grep -q '^Authority=Apple Distribution' || fail "not signed for distribution"

security cms -D -i "$app/embedded.mobileprovision" > "$dir/profile.plist"
/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$dir/profile.plist" >/dev/null 2>&1 && fail "ad hoc or development profile"
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$dir/ent.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$dir/ent.plist" 2>/dev/null)" = true ] && fail "get-task-allow is on"

# Every Mach-O must be for iOS devices (LC_BUILD_VERSION platform 2), not the simulator.
find "$app" -type f | while read -r f; do
  file -b "$f" | grep -q Mach-O || continue
  otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/platform/{print $2; exit}' | grep -qx 2 || fail "not an iOS device binary: ${f#$app/}"
done

/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$app/Info.plist" >/dev/null || fail "ITSAppUsesNonExemptEncryption is missing"

# Keys and tokens that must never ship.
if grep -rlaE 'BEGIN ([A-Z]+ )?PRIVATE KEY|AuthKey_[A-Z0-9]{10}|ghp_[A-Za-z0-9]{36}|github_pat_|hf_[A-Za-z]{34}|sk-[A-Za-z0-9]{32}|AKIA[0-9A-Z]{16}' "$app"; then
  fail "the files above look like they hold a key or token"
fi

echo "check-ipa: $(basename "$ipa") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")) is ready"
