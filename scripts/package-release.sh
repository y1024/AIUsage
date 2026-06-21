#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-AIUsage}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AIUsage.xcodeproj}"
SCHEME="${SCHEME:-AIUsage}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$ROOT_DIR/AIUsage/Info.plist}"
VERSION="${1:-${VERSION:-}}"
REQUIRE_SPARKLE_SIGNING="${REQUIRE_SPARKLE_SIGNING:-0}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-release.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

if [[ -z "${VERSION}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"
fi

mkdir -p "$OUTPUT_DIR"

strip_bundle_detritus() {
  local target="$1"
  local pass
  local attrs_pattern='com\.apple\.(FinderInfo|ResourceFork|fileprovider\.fpfs#P)'

  for pass in 1 2 3; do
    for attr in com.apple.FinderInfo com.apple.ResourceFork com.apple.fileprovider.fpfs#P; do
      find "$target" -exec xattr -d "$attr" {} + 2>/dev/null || true
      find -H "$target" -type l -exec xattr -ds "$attr" {} + 2>/dev/null || true
    done

    if ! xattr -lr "$target" 2>/dev/null | rg -q "$attrs_pattern"; then
      return 0
    fi
  done

  echo "Failed to strip all detritus from $target" >&2
  xattr -lr "$target" 2>/dev/null | rg "$attrs_pattern" >&2 || true
  return 1
}

echo "Building ${APP_NAME} ${VERSION}..."

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build

SOURCE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS.zip"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS.dmg"
DMG_STAGING_DIR="$WORK_DIR/dmg-root"
APP_STAGING_ROOT="$WORK_DIR/app-staging"
APP_PATH="$APP_STAGING_ROOT/$APP_NAME.app"

if [[ ! -d "$SOURCE_APP_PATH" ]]; then
  echo "Expected app bundle not found at $SOURCE_APP_PATH" >&2
  exit 1
fi

rm -rf "$APP_STAGING_ROOT"
mkdir -p "$APP_STAGING_ROOT"

echo "Creating sanitized app bundle staging copy..."
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP_PATH" "$APP_PATH"
strip_bundle_detritus "$APP_PATH"

echo "Injecting custom Sparkle localization strings..."
SPARKLE_RES=$(find "$APP_PATH/Contents/Frameworks" -path "*/Sparkle.framework/*/Resources" -type d 2>/dev/null | head -1)
STRINGS_SRC="$ROOT_DIR/AIUsage/Resources"
if [[ -n "$SPARKLE_RES" && -d "$SPARKLE_RES" ]]; then
  for LOCALE in Base.lproj zh_CN.lproj; do
    SRC_FILE="$STRINGS_SRC/$LOCALE/Sparkle.strings"
    if [[ -f "$SRC_FILE" ]]; then
      mkdir -p "$SPARKLE_RES/$LOCALE"
      cp -f "$SRC_FILE" "$SPARKLE_RES/$LOCALE/Sparkle.strings"
      echo "  Injected $LOCALE/Sparkle.strings"
    fi
  done
else
  echo "  WARNING: Sparkle.framework Resources not found, skipping string injection"
fi

strip_bundle_detritus "$APP_PATH"

# Signing identity:
#   - When MACOS_SIGNING_IDENTITY is set (release builds in CI), sign with a
#     STABLE certificate. A stable signature keeps the app's designated
#     requirement constant across versions, so a user's Keychain "Always Allow"
#     grant survives updates instead of re-prompting on every release (issue #35).
#   - Otherwise fall back to ad-hoc (local dev builds, or CI without the secret).
SIGN_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
SIGN_KEYCHAIN="${MACOS_SIGNING_KEYCHAIN:-}"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing ${APP_NAME}.app with stable identity (${SIGN_IDENTITY})..."
  CODESIGN_ARGS=(--force --deep)
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    CODESIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign "${CODESIGN_ARGS[@]}" -s "$SIGN_IDENTITY" "$APP_PATH"
else
  echo "Ad-hoc signing ${APP_NAME}.app (no MACOS_SIGNING_IDENTITY set)..."
  codesign --force --deep -s - "$APP_PATH"
fi
codesign --verify --verbose "$APP_PATH" || true

# Guarantee: when a stable identity was requested, the output MUST be
# certificate-signed (designated requirement pins the cert). If it silently fell
# back to ad-hoc, the Keychain "Always Allow" fix would be lost — so fail loudly
# instead of shipping a build that re-prompts users on every update (issue #35).
if [[ -n "$SIGN_IDENTITY" ]]; then
  DESIGNATED_REQ="$(codesign -d -r- "$APP_PATH" 2>&1 || true)"
  if ! echo "$DESIGNATED_REQ" | grep -qi 'certificate leaf'; then
    echo "ERROR: stable signing was requested but the app is not certificate-signed." >&2
    echo "Designated requirement:" >&2
    echo "$DESIGNATED_REQ" >&2
    exit 1
  fi
  echo "Verified stable certificate-pinned signature."
fi

rm -f "$ZIP_PATH" "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

DMG_RW_PATH="$WORK_DIR/${APP_NAME}-rw.dmg"

DMG_SIZE_KB=$(du -sk "$DMG_STAGING_DIR" | awk '{print $1}')
DMG_SIZE_KB=$(( DMG_SIZE_KB + 10240 ))

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDRW \
  -size "${DMG_SIZE_KB}k" \
  "$DMG_RW_PATH" >/dev/null

MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW_PATH" \
  | grep "/Volumes/$APP_NAME" | awk -F'\t' '{print $NF}')

echo "Configuring DMG window layout..."
osascript <<APPLESCRIPT || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 640, 400}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "${APP_NAME}.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force
hdiutil convert "$DMG_RW_PATH" -format UDZO -o "$DMG_PATH" >/dev/null

echo "Created release artifacts:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"

# --- Sparkle appcast generation ---
SPARKLE_SIGN="${SPARKLE_SIGN_TOOL:-}"
SPARKLE_KEY="${SPARKLE_EDDSA_PRIVATE_KEY:-}"

if [[ -n "$SPARKLE_SIGN" && -n "$SPARKLE_KEY" ]]; then
  echo "Signing .zip for Sparkle..."
  TMPKEY=$(mktemp)
  printf '%s' "$SPARKLE_KEY" > "$TMPKEY"
  SIGN_OUTPUT=$("$SPARKLE_SIGN" "$ZIP_PATH" --ed-key-file "$TMPKEY" 2>&1)
  rm -f "$TMPKEY"
  EDDSA_SIG=$(echo "$SIGN_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | cut -d'"' -f2)
  if [[ -z "$EDDSA_SIG" ]]; then
    echo "Failed to extract Sparkle EdDSA signature from sign_update output" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
  fi
  ZIP_LENGTH=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat --printf="%s" "$ZIP_PATH" 2>/dev/null)

  DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/sylearn/AIUsage/releases/download/v${VERSION}}"
  APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

  PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

  cat > "$APPCAST_PATH" <<APPCAST_EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>AIUsage</title>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL_PREFIX}/${APP_NAME}-${VERSION}-macOS.zip"
        type="application/octet-stream"
        sparkle:edSignature="${EDDSA_SIG}"
        length="${ZIP_LENGTH}"
      />
    </item>
  </channel>
</rss>
APPCAST_EOF

  echo "  $APPCAST_PATH"
else
  if [[ "$REQUIRE_SPARKLE_SIGNING" == "1" ]]; then
    echo "Sparkle signing is required for release builds, but SPARKLE_SIGN_TOOL or SPARKLE_EDDSA_PRIVATE_KEY is missing" >&2
    exit 1
  fi
  echo "Skipping Sparkle signing (SPARKLE_SIGN_TOOL or SPARKLE_EDDSA_PRIVATE_KEY not set)"
fi

# Remove the freshly built app bundle from DerivedData. The shippable artifacts
# already live in dist/, but macOS LaunchServices auto-registers any .app it
# finds — leaving build products around makes Launchpad/Spotlight show several
# duplicate "AIUsage" entries next to the real /Applications copy. Set
# KEEP_BUILD_APP=1 to keep it (e.g. to debug the raw build product).
if [[ "${KEEP_BUILD_APP:-0}" != "1" && -d "$SOURCE_APP_PATH" ]]; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$SOURCE_APP_PATH" 2>/dev/null || true
  rm -rf "$SOURCE_APP_PATH"
  echo "Removed build product app bundle (avoids duplicate LaunchServices registration): $SOURCE_APP_PATH"
fi
