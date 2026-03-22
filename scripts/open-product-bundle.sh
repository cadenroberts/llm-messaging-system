#!/usr/bin/env bash
# Opens the pre-built macOS GUI bundle shipped next to the Xcode project (if present).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${REPO_DIR}/iMessageAI.app"
if [ ! -d "$BUNDLE" ]; then
  echo "ERROR: pre-built GUI bundle not found next to the Xcode project." >&2
  echo "Build from source with Option B in README, or build the bundle in Xcode first." >&2
  exit 1
fi
open "$BUNDLE"
