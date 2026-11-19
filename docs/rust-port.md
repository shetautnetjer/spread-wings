# Spread-Wings in Rust: a measured trial

Started 2026-11-18 15:48 PST on the owner's word ("Go rust"), on the branch
`rust`. The Goose program in `src/` stays as it is and stays the one that
ships until this is decided. The Rust program is in `rust/`.

## Why

The owner's question: would this have been better in Rust, with Goose for
the parts it suits? Spread-Wings is the smaller of the two programs, its
rules are SQL that moves over as it is, and its tests drive the program
from outside. So it can be answered here with numbers, before anything is
decided about Swan.

## The pass bar, written before any Rust

1. **The same graph.** `tests/graph_dump.py --hash` prints the same for
   the Rust program's graph and the Goose program's, for `index`, on
   morluto/rea, relatedb/relate, Understand-Anything, Agent-Reach and
   cobra. And `update` leaves the graph `index` builds:
   `tests/random_changes.py` with `--sw` pointing at the Rust program.
2. **The same checks.** All of `tests/test.sh` passes with
   `SPREAD_WINGS=<the Rust program>`, in the cua microVM.
3. **A table.** `index`, `update` and an idle `watch`: time and memory,
   Rust beside Goose, on the same machine and repos.
4. **What it took.** Sessions, hours by the clock, lines of Rust beside
   lines of Goose, and what had to be done by hand that a crate or the
   language gave for nothing (and the other way round).

Not part of the bar: being nicer Rust. The first aim is the same answers;
the code follows the Goose code closely so the two can be read side by
side. Idiom comes after the bar is met, if the trial says go on.

## What is carried over, and how

| Part | Goose | In Rust |
|---|---|---|
| The SQL scripts | constants in `src/*.goose` | taken from those files as they are by `scripts/sql-from-goose.py` into `rust/src/sql.rs`; never retyped |
| SQLite | goose-sqlite (3.54.1, in the program) | `libsqlite3-sys`, bundled |
| tree-sitter | goose-treesitter: runtime 0.25.10, python 0.25.0, javascript 0.25.0, typescript 0.23.2, rust 0.24.0 | the `tree-sitter` crate and the grammar crates at those same versions |
| The pattern matcher (`$X` patterns over a syntax tree) | part of goose-treesitter (`treesitter.goose`, 750 lines) | ported with the rest: `rust/src/ts.rs` |
| File events | C glue (`native/sw_sys.c`) | the `libc` crate |

## Scope found on the first look (15:55 PST)

5,486 lines of Goose in `src/`, 203 of C in `native/`, and about 700 lines
of goose-treesitter that Spread-Wings leans on (the flat node table and
the pattern matcher). About 6,400 lines to carry over. 54 SQL scripts.

## Log

- 2026-11-18 15:55 PST: branch, this file, the inventory.
- 2026-11-18 16:00 PST: the facts. `ts.rs` (node table, pattern matcher),
  `treedefs.rs`, `extract.rs`, `store.rs`, `db.rs`, `sys.rs`, `util.rs`.
  Files, definitions, imports, call sites and bindings are the same rows
  as the Goose build writes on the fixtures and on all five repos, at the
  first build that compiled (scratch check: fact columns, table by table).
- 2026-11-18 16:14 PST: the links and the groups. `graph.rs` (imports,
  calls, file links, Louvain as it is written in Goose), `run.rs` (`index`),
  `query.rs` and `serve.rs` (the questions, MCP). **Bar 1, first half, met:
  `index` gives the same graph as the Goose build** by
  `tests/graph_dump.py --hash` on the fixtures and all five repos:

  | repo | files | graph hash, both builds | Goose index | Rust index |
  |---|---|---|---|---|
  | tests/fixtures | 31 | 3e03d41c52462818 | 0.012 s | 0.006 s |
  | Agent-Reach | 87 | 05340bb8afdf52b9 | 0.113 s | 0.104 s |
  | Understand-Anything | 324 | 409756ea55c3e8b2 | 0.234 s | 0.225 s |
  | relate | 2,078 | 1b349266d0727e18 | 4.97 s | 4.84 s |
  | rea | 7,784 | 6da71eccdb332107 | 16.7 s | 16.4 s |
  | cobra (Go: nothing read) | 0 | 1e135afb54bf948e | 0.004 s | 0.003 s |

  (One run each, this machine, not the microVM: a first look, not the
  table of bar 3.) The time is where it was: on rea, 2.7 s reading files
  (tree-sitter, C in both builds) and 13.6 s in the link scripts (SQLite,
  C in both builds). The language the program is written in is not where
  the time goes.

  Known differences so far: an error ends the run with the message alone
  (Goose adds `goose runtime error:` before it and the source line after);
  the MCP server reads JSON with `serde_json`, so a message that is not
  JSON gets that crate's wording in its error, and of two members of one
  name the last counts (Goose: the first); a pattern holding a string or a
  comment is refused by `ts.rs` (none of the program's patterns has one).

  Still to carry over: `update`, `watch`, `compiler` (`--into`), `survey`,
  `score`, `decide`; then `tests/test.sh` and `tests/random_changes.py`
  with the Rust program, in the microVM.
