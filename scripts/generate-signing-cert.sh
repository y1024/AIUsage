#!/usr/bin/env bash

# Generate a STABLE self-signed code signing certificate for release builds.
#
# Why: release builds used ad-hoc signing (`codesign -s -`), whose signature
# fingerprint changes on every build. The macOS Keychain records the previous
# fingerprint in each item's ACL, so a user's "Always Allow" grant is voided on
# every update and they get re-prompted (issue #35). Signing every release with
# the SAME certificate keeps the designated requirement constant, so the grant
# survives updates.
#
# This is NOT an Apple Developer ID certificate (no paid account, still
# unnotarized — Gatekeeper behavior is unchanged vs ad-hoc). Its only job is to
# stay identical across builds.
#
# Run ONCE, then keep the certificate stable forever:
#   ./scripts/generate-signing-cert.sh
# Add the two printed values as GitHub Actions repository secrets:
#   MACOS_CERT_P12_BASE64   (contents of the generated dist/aiusage-signing.p12.base64)
#   MACOS_CERT_PASSWORD     (the printed password)
#
# IMPORTANT: do not regenerate later. A new certificate = a new fingerprint =
# users get prompted one more time. Keep the .p12 / secret values safe.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CN="${1:-AIUsage Self-Signed}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
PASSWORD="${MACOS_CERT_PASSWORD:-$(openssl rand -base64 18)}"

mkdir -p "$OUT_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-cert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Generating self-signed code signing certificate (CN=$CN)..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" \
  -out "$WORK/cert.pem" \
  -days 3650 \
  -subj "/CN=$CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"

P12_PATH="$OUT_DIR/aiusage-signing.p12"
B64_PATH="$OUT_DIR/aiusage-signing.p12.base64"

openssl pkcs12 -export \
  -out "$P12_PATH" \
  -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" \
  -name "$CN" \
  -passout "pass:$PASSWORD"

base64 < "$P12_PATH" > "$B64_PATH"

echo
echo "Done."
echo "  Certificate (.p12): $P12_PATH"
echo "  Base64 for secret:  $B64_PATH"
echo
echo "==== Add these as GitHub Actions repository secrets ===="
echo "  MACOS_CERT_PASSWORD   = $PASSWORD"
echo "  MACOS_CERT_P12_BASE64 = (paste the full contents of $B64_PATH)"
echo
echo "Keep $P12_PATH and the password safe; reuse the same certificate for every"
echo "release so the Keychain 'Always Allow' grant keeps working across updates."
