# Notes for agents working on this repository

Spread-Wings builds a broad code graph from tree-sitter parses (no repo code
is ever run). Read [docs/DESIGN.md](docs/DESIGN.md) first.

| Path | What |
|---|---|
| `src/main.rs` | the commands and their arguments |
| `src/run.rs` | `index`, `update`, `watch` (which runs `update` on file events), the copy `compiler --into` works on |
| `src/query.rs`, `src/serve.rs` | the questions (overview, find, neighbors, callers, touches); the MCP server |
| `src/extract.rs`, `src/treedefs.rs`, `src/ts.rs` | the walk and what is read from each file: definitions by the kind of node, imports and calls by pattern; the syntax tree as a table and the pattern matcher |
| `src/graph.rs` | import and call linking, Louvain communities |
| `src/update.rs` | `update`: the files that changed, and the calls a change reaches |
| `src/sql.rs` | every script and fixed text (the SQL, the per-language patterns, the usage text, the MCP tools), each with the comment that says what it is for |
| `src/store.rs`, `src/db.rs` | the layout and rules numbers, opening a graph; SQLite |
| `src/compiler.rs`, `src/survey.rs`, `src/decide.rs` | compiler answers from a Swan map, and `score`; the survey; Span-02 decisions |
| `src/sys.rs`, `src/watch.rs`, `src/util.rs` | files and times; file events for `watch`; byte strings and the hash |
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
   that named in the list at the top of `src/update.rs`, and the calls
   it can change added to the ones update ties again.
6. A change to what `index` writes for some repo (a reader, a pattern, a
   link rule) raises `RULES_NUMBER` in `src/store.rs`; a check in
   `tests/test.sh` holds the fixtures' graphs to it.

Build and test:

```bash
scripts/build.sh                 # cargo build --release --locked, then bin/spread-wings
cargo test --release --locked
tests/test.sh
```

Worth knowing:

- Text is bytes throughout (`&[u8]`, helpers in `src/util.rs`): a source
  file need not be UTF-8.
- The order sums are taken in and the way weights are read (thousandths)
  are part of the rules: the groups hang on the last digit of a sum.
- The tree-sitter runtime and the grammar crates are pinned to exact
  versions in `Cargo.toml`. A newer grammar can parse a file into another
  tree, and so into another graph: raising one falls under rule 6.
- `util::hash` makes the files' stamps and the decision cache's keys. It is
  the hash the program used when it was written in Goose, so graphs and
  answers from before still read. Not to be changed without rebuilding both.
- The program was written first in Goose and carried over to Rust on
  2026-11-18 ([docs/rust-port.md](docs/rust-port.md)). The Goose sources, as
  they last were, are at commit `d7a8db1` (`src/*.goose`, `native/`).
