#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/science-auth-regression.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/AIUsage/Services/Science/ScienceAuthProxy+Helpers.swift" \
  "$ROOT_DIR/AIUsage/Services/Science/ScienceManagedDaemonStopper.swift" \
  "$ROOT_DIR/AIUsage/Services/Science/ScienceSelectionNormalizer.swift" \
  "$ROOT_DIR/scripts/ScienceAuthProxyRegression.swift" \
  -lsqlite3 \
  -o "$WORK_DIR/science-auth-regression"

"$WORK_DIR/science-auth-regression"
