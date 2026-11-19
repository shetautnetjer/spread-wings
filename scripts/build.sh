#!/usr/bin/env bash
# Builds bin/spread-wings with cargo, at the crate versions Cargo.lock pins
# (SQLite and the tree-sitter grammars are built in; libcurl's development
# files are needed, for `decide`). CARGO points at cargo (default: `cargo`
# on PATH, else ~/.cargo/bin/cargo).
set -euo pipefail
cd "$(dirname "$0")/.."
CARGO=${CARGO:-cargo}
if ! command -v "$CARGO" >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then CARGO="$HOME/.cargo/bin/cargo"; fi
command -v "$CARGO" >/dev/null 2>&1 || { echo "build: cargo not found (install Rust, or set CARGO=/path/to/cargo)" >&2; exit 2; }
"$CARGO" build --release --locked
mkdir -p bin
# Put in place in one step: a `serve` or `watch` that is running keeps the
# program it started with.
cp target/release/spread-wings bin/spread-wings.new
mv bin/spread-wings.new bin/spread-wings
