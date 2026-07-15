#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cliproxy-updater-regression.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyGeminiCredentialBridge.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyCredentialAdapter.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyManagementClient.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyReleaseClient.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyBinaryStore.swift" \
  "$ROOT_DIR/scripts/CLIProxyUpdaterRegression.swift" \
  -o "$WORK_DIR/cliproxy-updater-regression"

"$WORK_DIR/cliproxy-updater-regression" "$@"
