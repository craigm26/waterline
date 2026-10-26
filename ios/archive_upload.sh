#!/bin/bash
# Archive Waterline and upload to TestFlight, headless, on the build Mac.
#
# BUDGET, NOT A BUILD STEP. App Store Connect caps uploads per version train
# (CFBundleShortVersionString) at roughly 20 in a rolling 24 hours. Before running
# this, ask what else is queued for this app, and batch every change into ONE build.
# To find out whether something COMPILES, use the CODE_SIGNING_ALLOWED=NO build in README.md — unsigned
# builds are unlimited and catch everything an upload would.
# Same flow as the other apps on team WYGG3JXWMG: login keychain + ASC API key,
# cloud signing. Usage: KEYCHAIN_PASSWORD piped in via the caller.
#   ./archive_upload.sh <KEY_ID> <ISSUER_ID>
set -euo pipefail

KEY_ID="${1:?usage: archive_upload.sh <KEY_ID> <ISSUER_ID>}"
ISSUER_ID="${2:?usage: archive_upload.sh <KEY_ID> <ISSUER_ID>}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
[ -f "$KEY_PATH" ] || { echo "Missing $KEY_PATH"; exit 1; }

cd "$(dirname "$0")"
ARCHIVE="build/Waterline.xcarchive"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# A locked login keychain fails CodeSign with errSecInternalComponent, and each
# ssh connection is a fresh security session — unlock in-process, every run.
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOGIN_KEYCHAIN"
  security set-keychain-settings "$LOGIN_KEYCHAIN"   # never re-lock mid-pipeline
  security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s \
    -k "$KEYCHAIN_PASSWORD" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
    || echo "WARNING: could not set key partition list"
  # ONLY the login keychain: a leftover ci.keychain-db carrying a locked copy of
  # the same identity wins the search-list race and kills the export.
  security list-keychains -d user -s "$LOGIN_KEYCHAIN"
fi

# Sign a throwaway file: the one probe that tells locked from unlocked over ssh.
IDENTITY=$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" \
  | grep -m1 'Apple Distribution' | sed -E 's/.*"(.*)".*/\1/')
[ -n "$IDENTITY" ] || { echo "ERROR: no Apple Distribution identity in login keychain" >&2; exit 1; }
T=$(mktemp); codesign -s "$IDENTITY" -f "$T" || { echo "ERROR: keychain still unusable" >&2; exit 1; }
rm -f "$T"
echo "==> signing as $IDENTITY"

export PATH="$HOME/bin:$PATH"
xcodegen generate

xcodebuild archive \
  -project Waterline.xcodeproj \
  -scheme Waterline \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID"

echo "Uploaded. Watch TestFlight for processing."
rm -rf "$ARCHIVE"
