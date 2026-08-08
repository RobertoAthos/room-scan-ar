#!/bin/bash
#
# Builds RoomScanAR and installs it on the connected iPhone.
#
# Why this exists: the app is signed with a free Apple ID, whose provisioning
# profiles last **7 days**. After that the app refuses to launch and has to be
# reinstalled from a Mac. Nothing about the build changes that — the deadline is
# signed into the binary. This script makes the weekly renewal a single command
# instead of an Xcode session.
#
#   ./Scripts/install.sh            # Release (default)
#   ./Scripts/install.sh Debug      # Debug, if you need the debugger
#
set -euo pipefail

CONFIGURATION="${1:-Release}"
SCHEME="RoomScanAR"
DERIVED_DATA="/tmp/roomscanar-build"

cd "$(dirname "$0")/.."

echo "==> Looking for a paired device"
# Match the identifier by shape rather than filtering on the State column:
# devicectl reports "connected", "available (paired)" and "available", and an
# install succeeds from more than one of those. Let devicectl itself be the
# judge of reachability — its error is clearer than any guess made here.
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
  | head -1)

if [ -z "$DEVICE_ID" ]; then
  echo "No paired device found."
  echo
  echo "Check that:"
  echo "  - the cable carries data (a charge-only USB-C cable will not do);"
  echo "  - the iPhone is unlocked;"
  echo "  - you tapped Trust on the phone."
  exit 1
fi
echo "    $DEVICE_ID"

echo "==> Building ($CONFIGURATION)"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | sort -u || true

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/$SCHEME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Build produced no .app at $APP_PATH"
  exit 1
fi

echo "==> Installing"
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
     | grep -E "App installed|bundleID"; then
  echo
  echo "The Mac could not reach the device. Reconnect the cable with the iPhone"
  echo "unlocked and run this again."
  exit 1
fi

# Report the deadline, which is the whole reason this script exists.
PROFILE=$(ls -t ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision 2>/dev/null | head -1)
if [ -n "$PROFILE" ]; then
  # PlistBuddy cannot read from a pipe, so the decoded profile goes to a file.
  DECODED=$(mktemp -t roomscanar-profile)
  trap 'rm -f "$DECODED"' EXIT
  if security cms -D -i "$PROFILE" -o "$DECODED" 2>/dev/null; then
    EXPIRY=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$DECODED" 2>/dev/null || true)
    [ -n "$EXPIRY" ] && echo "==> Provisioning profile expires: $EXPIRY"
  fi
fi

echo "Done. The app runs standalone — no Mac, no Xcode, no shared network."
