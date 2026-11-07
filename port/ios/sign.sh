#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 the OpenRAC contributors
#
# Signs an iOS build's application bundle (cmake/IOS.cmake runs it after every link):
#
#   sign.sh <bundle.app> <identity> <profile> <bundle id>
#
# identity "-" and profile "-": ad hoc, for the simulator, with no entitlements (the Mac refuses
# to start an ad hoc signed program that claims any, get-task-allow included).
# Otherwise the provisioning profile goes into the bundle as embedded.mobileprovision and the
# signature takes the profile's entitlements, its wildcard application identifier made the bundle's.
# The frameworks in the bundle (Python and its modules, ios/python.sh) are signed first, with the
# same identity and no entitlements: the bundle's signature seals theirs.
set -eu

bundle=$1
identity=$2
profile=$3
bundle_id=$4

if [ -d "$bundle/Frameworks" ]; then
  for framework in "$bundle"/Frameworks/*.framework; do
    codesign --force --sign "$identity" --timestamp=none "$framework"
  done
fi

if [ "$profile" = "-" ]; then
  exec codesign --force --sign "$identity" --timestamp=none "$bundle"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
entitlements="$work/entitlements.plist"

cp "$profile" "$bundle/embedded.mobileprovision"
security cms -D -i "$profile" > "$work/profile.plist"
plutil -extract Entitlements xml1 -o "$entitlements" "$work/profile.plist"
team=$(plutil -extract TeamIdentifier.0 raw -o - "$work/profile.plist")
plutil -replace application-identifier -string "$team.$bundle_id" "$entitlements"
# A wildcard profile's keychain group is the team's prefix with a "*": the bundle's own instead.
if plutil -extract keychain-access-groups xml1 -o /dev/null "$entitlements" 2>/dev/null; then
  plutil -replace keychain-access-groups -json "[\"$team.$bundle_id\"]" "$entitlements"
fi

codesign --force --sign "$identity" --timestamp=none --generate-entitlement-der \
  --entitlements "$entitlements" "$bundle"
