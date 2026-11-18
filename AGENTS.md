# Notes for agents working on this repository

Spread-Wings builds a broad code graph from tree-sitter parses (no repo code
is ever run). Read [docs/DESIGN.md](docs/DESIGN.md) first.

| Path | What |
|---|---|
| `src/spread-wings.goose` | CLI, queries, MCP server |
| `src/extract.goose` | the walk and per-language patterns (goose-treesitter) |
| `src/graph.goose` | import and call linking, Louvain communities |
| `src/update.goose` | `update`: the files that changed, and the calls a change reaches (`watch`, in `src/spread-wings.goose`, runs it on file events) |
| `src/store.goose` | SQLite schema (goose-sqlite) |
| `native/sw_sys.c` | what Goose's os module lacks: `lstat`, `realpath`, file sizes and times, file events for `watch` |
| `tests/test.sh` | checks against `tests/fixtures/mini` |
| `tests/graph_dump.py` | a graph without its row numbers, to compare two graphs of the same files |
| `tests/random_changes.py` | random changes to a copy of a repo, `update` compared with `index` after each batch (not part of `test.sh`: run it on a real repo after changing `update` or a link rule) |

Rules:

1. Never run a repository's code, build files or package managers while
   indexing.
2. Every derived fact says how it was found (parsed, matched by path,
   matched by name, and from 0.2 decided).
3. Indexing stays deterministic: same repo, same graph.
4. Keep machine names, usernames and home paths out of the repository.
5. `update` leaves the graph `index` builds from the same files. A link
   rule that reads something new (another table, another file's rows) needs
   that named in the list at the top of `src/update.goose`, and the calls
   it can change added to the ones update ties again.
6. A change to what `index` writes for some repo (a reader, a pattern, a
   link rule) raises `RULES_NUMBER` in `src/store.goose`; a check in
   `tests/test.sh` holds the fixtures' graphs to it.

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
