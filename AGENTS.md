# Notes for agents working on this repository

Spread-Wings builds a broad code graph from tree-sitter parses (no repo code
is ever run). Read [docs/DESIGN.md](docs/DESIGN.md) first.

| Path | What |
|---|---|
| `src/spread-wings.goose` | CLI, queries, MCP server |
| `src/extract.goose` | the walk and per-language patterns (goose-treesitter) |
| `src/graph.goose` | import and call linking, Louvain communities |
| `src/store.goose` | SQLite schema (goose-sqlite) |
| `native/sw_sys.c` | `lstat` and `realpath`, which Goose's os module lacks |
| `tests/test.sh` | checks against `tests/fixtures/mini` |

Rules:

1. Never run a repository's code, build files or package managers while
   indexing.
2. Every derived fact says how it was found (parsed, matched by path,
   matched by name, and from 0.2 decided).
3. Indexing stays deterministic: same repo, same graph.
4. Keep machine names, usernames and home paths out of the repository.

Build and test:

```bash
GOOSE=/path/to/goose scripts/build.sh
tests/test.sh
```

Goose specifics worth knowing: a multi-line string's text starts on the
line after `"""` and the closing `"""` stands on its own line; a call that
may shrink a buffer can't run while a slice into it is still used (copy the
slice into an owned buffer first); `std` has no float parser, so SQL reals
are read as scaled integers.
