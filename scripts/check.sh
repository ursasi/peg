#!/usr/bin/env bash
# Everything CI runs, in the same order, so a push does not discover the
# failure. `scripts/build-app.sh` also generates the icon and signs the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== swift build"
swift build

echo "== self tests"
PEG_SELFTEST=1 "$(swift build --show-bin-path)/Peg"

echo "== app bundle"
bash scripts/build-app.sh
