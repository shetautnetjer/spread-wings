#!/usr/bin/env bash
# Runs this checkout's build and tests in a throwaway microVM, not on this
# machine: a fork of the test checkpoint that Swan's scripts/space-base.sh
# makes (a clean Ubuntu `cua` Space on Firecracker, with cargo and both
# checkouts in place). A fork starts in about a second; it is
# deleted when the run ends.
#
#   scripts/space-test.sh                 build, `cargo test`, then tests/test.sh
#   scripts/space-test.sh 'bin/spread-wings index /home/cua/Work/Swan /tmp/s.db'
#   SW_SPACE_KEEP=1 scripts/space-test.sh      keep the fork to look around
#
# What runs there is the working tree as it is now (tracked and new files).
# Needs the `cua` CLI and its daemon. The exit status is the command's own.
set -euo pipefail
cd "$(dirname "$0")/.."
checkpoint=${SW_SPACE_CHECKPOINT:-swan-test-v1}
guest=/home/cua/Work/spread-wings
name="wings-test-$(date +%H%M%S)-$$"

command -v cua >/dev/null 2>&1 || { echo "space-test: the cua CLI is not installed" >&2; exit 2; }
cua sb checkpoints 2>/dev/null | grep -qw "$checkpoint" || {
  echo "space-test: no checkpoint '$checkpoint'; make it with scripts/space-base.sh in the Swan checkout" >&2; exit 2; }

work=$(mktemp -d)
cleanup() {
  rm -rf "$work"
  if [ -n "${SW_SPACE_KEEP:-}" ]; then echo "space-test: kept $name (delete it with: cua sb rm -f $name)" >&2
  else cua sb rm -f "$name" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

t0=$(date +%s)
cua sb fork "$checkpoint" "$name" >/dev/null
{ git ls-files -z; git ls-files -z -o --exclude-standard; } |
  while IFS= read -r -d '' f; do if [ -e "$f" ]; then printf '%s\0' "$f"; fi; done |
  tar --null -T - -czf "$work/src.tgz"
cua sb cp "$work/src.tgz" "$name:/tmp/src.tgz" >/dev/null
# Out with the checkpoint's tracked files (so a file deleted here is gone
# there), in with this tree.
cua sb exec "$name" --timeout 300 -- \
  "cd $guest && git ls-files -z | xargs -0 rm -f && tar -xzf /tmp/src.tgz && rm /tmp/src.tgz"
echo "space-test: $name ready in $(( $(date +%s) - t0 )) s (fork of $checkpoint, tree synced)" >&2

if [ $# -eq 0 ]; then
  set -- "scripts/build.sh >/tmp/build.log 2>&1 || { tail -30 /tmp/build.log; exit 1; }; cargo test --release --locked >/tmp/cargo-test.log 2>&1 || { tail -30 /tmp/cargo-test.log; exit 1; }; grep '^test result' /tmp/cargo-test.log; tests/test.sh"
fi
cua sb exec "$name" --cwd "$guest" --timeout 0 -- "$*"
