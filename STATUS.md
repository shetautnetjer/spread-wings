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
from its answers, small windowed states (about a cent for a first run on
Graphify's repo, answers cached by content).

Not done: more languages, incremental re-indexing.
