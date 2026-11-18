# Status

## 0.1.0

- Languages: Python, TypeScript, TSX, JavaScript, Rust.
- `index`, `overview`, `find`, `neighbors`, `callers`, and `serve` (MCP over
  stdio with the same four tools).
- Calls tied to definitions by evidence: same_file, imported_name,
  imported_file, then by_name; the rule is stored and shown per call site.
- Louvain communities over code files (resolution 1.5, `--resolution`), test
  files attached to the code they use.
- Extraction on a worker pool (one thread per hardware thread, one queue),
  each file parsed once for all patterns.
- `tests/test.sh`: 22 checks on a mixed-language fixture (definitions,
  imports per language, calls by name, determinism, MCP framing and errors),
  all passing.
- Measured: Graphify's repo (701 files) parses in 0.85 s and links in 0.25 s;
  checked against Python's parser, definitions, call sites and importers are
  exact; all 262 `build_from_json` calls resolve to one definition and agree
  with hosted Graphify's 198 shown callers.

Built on branch `span-decisions`: Span-02 decisions (`decide`), rules learned
from its answers, small windowed states, rules for outside-repo calls (about $0.002 for a
first run on Graphify's repo, answers cached by content).

Not done: more languages, incremental re-indexing.

## 2026-11-17: Goose

Spread-Wings reads Goose (`.goose`), the language it and Swan are written
in. There is no tree-sitter grammar for Goose, so `goose_scan`
(src/extract.goose) reads it by line: comments and strings (`"""` blocks
too) blanked, then `fn`/`thread_fn`/`extern fn`/`struct`/`enum`/top-level
`let`, `import .x;` (x.goose beside the importer) and bare calls.

- On Swan's own repo: 43 Goose files, 461 functions, each matching an
  independent count by name and line; indexed with the rest in 0.15 s.
- tests/fixtures/goose and three checks; 52 pass.
- Limit: a call into a file the caller does not import directly stays
  by_name (1,647 of 4,059 linked Goose calls on Swan), though a Goose
  program is one namespace.
