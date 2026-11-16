#!/usr/bin/env bash
# Builds bin/spread-wings with the Goose compiler. GOOSE points at the
# compiler (default: `goose` on PATH); GOOSE_HOME keeps Goose's package and
# build cache (goose-treesitter and goose-sqlite are fetched there once).
set -euo pipefail
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-goose}
command -v "$GOOSE" >/dev/null 2>&1 || { echo "build: Goose compiler not found (set GOOSE=/path/to/goose)" >&2; exit 2; }
mkdir -p bin
"$GOOSE" build src/spread-wings.goose -o bin/spread-wings
