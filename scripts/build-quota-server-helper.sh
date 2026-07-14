#!/usr/bin/env bash

set -euo pipefail

: "${SRCROOT:?Missing SRCROOT}"
: "${TARGET_BUILD_DIR:?Missing TARGET_BUILD_DIR}"
: "${CONTENTS_FOLDER_PATH:?Missing CONTENTS_FOLDER_PATH}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Missing UNLOCALIZED_RESOURCES_FOLDER_PATH}"

build_configuration=debug
if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
  build_configuration=release
fi

swift_bin="$(xcrun --find swift)"
arch_flags=()
for architecture in ${ARCHS:-$(uname -m)}; do
  arch_flags+=(--arch "$architecture")
done

# Release builds receive arm64 + x86_64 from Xcode and SwiftPM merges the final
# product. Debug normally receives only the active architecture.
"$swift_bin" build \
  --package-path "$SRCROOT/QuotaBackend" \
  --product QuotaServer \
  -c "$build_configuration" \
  "${arch_flags[@]}"

# --arch changes SwiftPM's product location, so always ask SwiftPM for it.
bin_dir="$(
  "$swift_bin" build \
    --package-path "$SRCROOT/QuotaBackend" \
    --product QuotaServer \
    -c "$build_configuration" \
    "${arch_flags[@]}" \
    --show-bin-path
)"
source_helper="$bin_dir/QuotaServer"
helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
helper_path="$helper_dir/QuotaServer"
legacy_helper_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Helpers"
legacy_helper_path="$legacy_helper_dir/QuotaServer"

if [[ ! -x "$source_helper" ]]; then
  echo "error: QuotaServer build succeeded but executable is missing at $source_helper" >&2
  exit 1
fi

# Incremental DerivedData may retain the pre-migration resource copy. Never
# allow the bundle to contain both the old resource and new nested-code copy.
rm -f "$legacy_helper_path"
rmdir "$legacy_helper_dir" 2>/dev/null || true

mkdir -p "$helper_dir"
rm -f "$helper_path"
cp "$source_helper" "$helper_path"
chmod +x "$helper_path"

# Xcode signs the host after build phases. Sign nested code first with the exact
# same identity. Release packaging disables this step and repeats it in staging.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
  sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  if [[ -z "$sign_identity" ]]; then
    if [[ "${CODE_SIGNING_REQUIRED:-NO}" == "YES" ]]; then
      echo "error: QuotaServer requires signing, but Xcode did not provide a signing identity" >&2
      exit 1
    fi
    sign_identity="-"
  fi

  codesign_args=(--force --sign "$sign_identity")
  if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
    codesign_args+=(--options runtime)
  fi

  /usr/bin/codesign "${codesign_args[@]}" "$helper_path"
  /usr/bin/codesign --verify --strict --verbose=2 "$helper_path"
fi

