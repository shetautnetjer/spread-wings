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

## Result (2026-11-18)

The bar is met on all four points. Which program ships is not decided
here: that is the owner's, on these numbers.

**1. The same graph: yes.** `index`, by `tests/graph_dump.py --hash`:

| repo | files | graph hash, both programs |
|---|---|---|
| tests/fixtures | 31 | 3e03d41c52462818 |
| Agent-Reach | 87 | 05340bb8afdf52b9 |
| Understand-Anything | 324 | 409756ea55c3e8b2 |
| relatedb/relate | 2,078 | 1b349266d0727e18 |
| morluto/rea | 7,784 | 6da71eccdb332107 |
| cobra (Go: nothing read) | 0 | 1e135afb54bf948e |

`update` against `index` with the Rust program, `tests/random_changes.py`:
Agent-Reach 20 rounds twice (seeds 1 and 7), Understand-Anything 20 rounds
twice (seeds 1 and 3), relate 10 rounds, rea 3 rounds. Every round the
same graph. A file's stamp is the same number in both programs (411 of 411
files compared), so a graph one of them built can be brought up to date by
the other.

**2. The same checks: yes.** In the microVM, with no Goose program in
`bin/`: all 174 of `tests/test.sh` pass with
`SPREAD_WINGS=rust/target/release/spread-wings` (the 173 there were, and one
added here that holds `rust/src/sql.rs` to the Goose sources). The Goose
program passes the same 174. `cargo test`: 5 of 5.

**3. The table.** One machine (16 hardware threads), copies of the repos,
the two programs turn about. Times are medians (index: 4 runs, rea 2;
update with nothing changed: 10; update after one file gained or lost a
function: 8). Memory is the most the program held (peak resident).

| repo | program | index | update, nothing changed | update, one file edited | watch, 20 s idle |
|---|---|---|---|---|---|
| Agent-Reach (87 files) | Goose | 0.114 s, 26.5 MB | 2.1 ms, 8.4 MB | 11.8 ms, 11.7 MB | no CPU, 7.9 MB |
| | Rust | 0.105 s, 29.9 MB | 2.0 ms, 9.6 MB | 11.4 ms, 12.9 MB | no CPU, 9.4 MB |
| Understand-Anything (324) | Goose | 0.234 s, 61.6 MB | 2.9 ms, 8.6 MB | 17.9 ms, 13.9 MB | no CPU, 8.3 MB |
| | Rust | 0.226 s, 53.4 MB | 3.0 ms, 10.2 MB | 16.8 ms, 14.8 MB | no CPU, 9.7 MB |
| relate (2,078) | Goose | 4.95 s, 97.1 MB | 8.6 ms, 10.6 MB | 103.9 ms, 16.2 MB | no CPU, 8.6 MB |
| | Rust | 4.84 s, 83.9 MB | 9.3 ms, 11.7 MB | 102.1 ms, 17.1 MB | no CPU, 10.0 MB |
| rea (7,784) | Goose | 16.62 s, 209.1 MB | 20.5 ms, 12.6 MB | 287.8 ms, 18.7 MB | no CPU, 10.1 MB |
| | Rust | 16.42 s, 182.9 MB | 22.1 ms, 14.2 MB | 282.0 ms, 19.1 MB | no CPU, 12.2 MB |

Read plainly: the same. Rust's `index` is 1% to 8% quicker (about 1% and
2% on the two large repos) and holds 13% less at its peak on the three
larger repos, 13% more on the smallest; an update with nothing changed is
within 2 ms either way, one after an edit within 6 ms (2%); at rest the
Rust program holds 1.4 to 2.1 MB more. Nothing here would be noticed in
use. The time is where it was: on rea, 2.7 s reading files (tree-sitter)
and 13.6 s in the link scripts (SQLite) in the Rust program, 2.8 s and
13.9 s in the Goose one. Both are C, the same versions, in both programs
(SQLite 3.54.1, the same source id).

Besides: the Rust program is 8.2 MB, the Goose one 33.5 MB (goose-treesitter
carries twenty grammars, the Rust build the five that are read). A clean
build in the microVM: 28 s with cargo; 4 s with Goose, its packages
already built.

**4. What it took.**

- One session, by the clock: 26 minutes from the word to `index` writing
  the same graph on every repo; 38 to every command carried over and the
  suite passing in the microVM; 42 to the random changes done. The table,
  the records and one fix the table asked for (below) took it to about an
  hour and a quarter.
- Lines: 4,942 of Rust written by hand (89 of them its own tests), for
  5,121 carried over: 3,900 of Goose in `src/` (its other 1,586 lines are
  scripts and texts, which moved as they are), 203 of C in `native/`, 965
  of goose-treesitter (the pattern matcher and the node table) and 53 of
  goose-sqlite. About the same size.
- Builds that failed for a reason in the language: none. Graph
  differences found at any stage: none; each stage matched at its first
  build. That says less than it seems to: this was finished, tested code
  carried over line by line with its scripts untouched, not new work.
- Builds that failed for another reason: one. The `curl` crate wants
  OpenSSL's development files by default, which the microVM does not have
  (the C helper needs only libcurl's).
- What measuring found: with the `curl` crate, every command, `find`
  included, took half a millisecond and 3.7 MB more than the Goose program,
  because that crate sets libcurl and OpenSSL up when the program starts.
  `decide` now calls libcurl itself (`curl-sys`), on the first request, as
  `native/sw_http.c` does. After that `find` on a small graph takes about
  1.7 ms against the Goose program's 2.3 ms (three single runs).
- What crates gave: SQLite and the five grammars built in with nothing to
  maintain (in place of goose-sqlite, goose-treesitter and their C glue),
  JSON reading, threads that hand their results back, file events and
  `stat` without a C file.
- What had to be made by hand all the same: the pattern matcher (so that
  the same patterns match the same nodes; `ts.rs`, 411 lines with the
  node table), Goose's `hash` (so
  stamps and the decision cache's keys stay readable by both), and byte
  strings with Goose's meanings for `find`, `split` and `trim`.

**What is different, and what is not proven.**

- An error ends the run with its message alone; the Goose program puts
  `goose runtime error:` before it and the source line after.
- The MCP server and `survey` read JSON with `serde_json`: a line that is
  not JSON gets that crate's wording in the error, and of two members with
  one name the last counts (Goose: the first).
- `ts.rs` refuses a pattern that holds a string or a comment. None of the
  program's patterns has one.
- `decide` has not asked the real service from the Rust program: that
  costs money and was not part of this. What is checked: the request as a
  server on the same machine receives it (`cargo test`), the cache keys
  (Goose's hash), and the suite's checks of `decide-apply` and of running
  without a key.
- Kept in step by hand: nothing but the suite and the graph hashes says
  that a later change to the Goose code was carried over. The scripts are
  the exception (`scripts/sql-from-goose.py --check`, in the suite).

**For pricing Swan** (an estimate, not a measurement): Swan is 11,621
lines of Goose in `src/` and 394 of C, a little over twice what was carried
over here, and its checks (`tests/check`, 4,158 lines) drive the program
from outside, so they would stay as they are and judge a port the way
`tests/test.sh` judged this one. At this trial's pace that is two or three
hours of work; the unknown is the part that drives other programs
(language servers, indexers, the sealed runs), where "the same answers"
has no single hash to compare and each look at the suite is four minutes.

## What is carried over, and how

| Part | Goose | In Rust |
|---|---|---|
| The SQL scripts | constants in `src/*.goose` | taken from those files as they are by `scripts/sql-from-goose.py` into `rust/src/sql.rs`; never retyped |
| SQLite | goose-sqlite (3.54.1, in the program) | `libsqlite3-sys`, bundled |
| tree-sitter | goose-treesitter: runtime 0.25.10, python 0.25.0, javascript 0.25.0, typescript 0.23.2, rust 0.24.0 | the `tree-sitter` crate and the grammar crates at those same versions |
| The pattern matcher (`$X` patterns over a syntax tree) | part of goose-treesitter (`treesitter.goose`, 750 lines) | ported with the rest: `rust/src/ts.rs` |
| File events, file times | C glue (`native/sw_sys.c`) | the `libc` crate and `std` |
| HTTPS for `decide` | C glue over libcurl (`native/sw_http.c`) | libcurl through `curl-sys`, set up on the first request |
| JSON | Goose's `json` | written by hand as in Goose; read with `serde_json` |
| A file's stamp, a decision's cache key | Goose's `hash` | the same function, step for step (`util.rs`), checked against values a Goose program printed |
| The numbers (layout 8, rules 1), the version, the decision model | constants in `src/*.goose` | taken with the scripts into `rust/src/sql.rs` |

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
- 2026-11-18 16:26 PST: `update.rs`, `watch.rs`, `compiler.rs` (with
  `score`), `survey.rs`, `decide.rs`. First suite run in the microVM with
  the Rust program: 173 of 173. (The run before it did not build: the
  `curl` crate's default wants OpenSSL's development files.)
- 2026-11-18 16:30 PST: `tests/random_changes.py` with the Rust program on
  four repos, six runs: every round the same graph. Bar 1 met.
- 2026-11-18 16:47 PST: the table, first pass. It showed the Rust program
  holding 3.7 MB more at rest and starting half a millisecond slower: the
  `curl` crate sets libcurl and OpenSSL up at start. `decide` moved to
  `curl-sys`; a check of the request against a server on the same machine;
  Goose's `hash` checked against values a Goose program printed.
- 2026-11-18 16:56 PST: the table again with that build (the one above).
  In the microVM, no `bin/` there: 174 of 174 with the Rust program, 5 of 5
  `cargo test`; then the Goose program, 174 of 174.
