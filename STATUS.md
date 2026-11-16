# Status

## 0.1.0

- Languages: Python, TypeScript, TSX, JavaScript, Rust.
- `index`, `overview`, `find`, `neighbors`, `callers`, and `serve` (MCP over
  stdio with the same four tools).
- Louvain communities, deterministic.
- `tests/test.sh`: 17 checks on a mixed-language fixture (definitions,
  imports per language, calls by name, determinism, MCP framing and errors),
  all passing.
- Measured: 0.13 s for a 20-file Rust workspace, 2.1 s for Graphify's own
  repo (701 files, 13,383 definitions, 87,628 call sites).

Not done: Span-02 decisions (0.2), more languages, `from . import x` in
Python, incremental re-indexing.
