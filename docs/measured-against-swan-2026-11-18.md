# Spread-Wings' call links, measured against Swan (2026-11-18)

Spread-Wings 0.1.0 at 609cecb indexed three repos as cloned. Each call link
was then put beside Swan's map of the same commit: a link is **right** when
Swan's compiler-resolved reference on that line, for that name, is defined
in the file Spread-Wings linked to; **wrong file** when Swan names another
file of the repo; **outside** when Swan resolves the call to a dependency or
the standard library. Links on lines where Swan has no resolved reference of
that name are not judged. Swan agrees with JetBrains IDEs on 99% of sampled
references on these repos, so it is used as the answer here.

Swan maps: relate and Understand-Anything from Swan dc12ea5 (all cargo
features, each tsconfig project); rea from the same build.

## Index only (no `compiler`, no `decide`)

| Repo | Files | Index time | Call links | Judged | Right |
|---|---|---|---|---|---|
| Egonex-AI/Understand-Anything b861852 (TypeScript) | 324 | 0.2 s | 4,757 | 2,488 | 98% |
| relatedb/relate 2e47f55 (Rust) | 2,078 | 5.3 s | 134,375 | 106,238 | 49% |
| morluto/rea 6752875 (TypeScript) | 7,784 | 9.1 s | 175,025 | 84,874 | 45% |

By the rule that made the link (links, then of those judged: right / wrong
file / outside the repo):

| Rule | Understand-Anything | relate | rea |
|---|---|---|---|
| same_file | 3,595: 1,578 / 0 / 5 | 27,638: 24,000 / 1,163 / 1,870 (89%) | 49,763: 27,626 / 244 / 288 (98%) |
| imported_name | 931: 863 / 0 / 0 | 2,778: 2,751 / 6 / 3 (100%) | 13,225: 10,274 / 0 / 1,118 (90%) |
| module_alias | 81: none judged | 1,213: 1,184 / 8 / 9 (99%) | 13: 2 / 0 / 0 |
| imported_file | 15: 0 / 0 / 1 | 11,204: 3,768 / 2,017 / 4,575 (36%) | 2,091: 59 / 627 / 52 (8%) |
| by_name | 135: 2 / 38 / 1 (5%) | 91,542: 20,499 / 21,943 / 22,442 (32%) | 109,933: 28 / 40,797 / 3,759 (0%) |

What this says:

- `same_file`, `imported_name` and `module_alias` can be relied on.
- **`by_name` is most of the links on a large repo (68% on relate, 63% on
  rea) and is mostly wrong**: a third right on relate, almost none on rea.
  `callers`, `touches` and the communities all take these links in.
- **`imported_file` is weak too** (36% and 8%): a name defined in an
  imported file is taken for the callee although the call is a method on
  something else.
- On Rust, `same_file` links 1,870 calls to a local function that Swan
  resolves to the standard library or a dependency (`new`, `len`, ...).

## After `spread-wings compiler <graph.db> <swan.db>`

| Repo | Calls tied only by name | Swan's map covers | Tied to one definition | Outside | Left unclear | Time | by_name links left |
|---|---|---|---|---|---|---|---|
| relate | 35,474 | 28,659 | 20,235 | 6,697 | 1,727 | 77 s | 31,164 |
| rea | 38,039 | 18,208 | 26 | 2,162 | 16,020 | 30 s | 106,160 |

- **Why rea settles almost nothing.** For 16,191 of the uses Swan resolves
  inside the repo, the definition Swan names is not a definition in
  Spread-Wings' graph: 12,549 are constants holding a function
  (`export const parse = (x: T): R => ...`), 3,236 are class methods, 266
  properties. The TypeScript patterns in `src/extract.goose` are fixed
  shapes (`const $NAME = ($$$A) => $B`): a return type, a type on the
  constant, type parameters or a modifier each make another shape, and
  there is no pattern for a method. rea's graph holds 11,063 functions,
  3,076 interfaces and 970 classes, and nothing else. With no symbol to
  attach to, the compiler's answer is dropped and the call stays tied by
  name to something else of that name.
- **Why the step was slow** (77 s and 30 s, against 5 s and 9 s to index):
  its working tables were joined on (file, row, name) against every edge
  and every call with no index. Fixed with three indexes, same day:
  0.5 s and 1.2 s, with the same links, calls, communities and file edges
  on both repos.

## Other gaps seen

- Not installed anywhere: no `spread-wings` on PATH, so Swan's `touches`
  report (which looks for it there or in `SWAN_SPREAD_WINGS`) is off on this
  machine.
- `serve` answers about one graph file given at start. An agent that works
  in several repos needs a server that takes the repo as it goes
  (as `swan serve --maps` with `use_repo` does) and builds the graph on
  first use; indexing is fast enough for that.
- It walks folders git ignores (Swan stopped doing so in #67).
- Languages: Python, TypeScript, TSX, JavaScript, Rust, Goose. relate's Go
  and Java clients are not in its graph.
- TypeScript path aliases from a package's own tsconfig (`@lib/x`) are not
  followed; only relative imports are.

## How this was measured

Rows in Spread-Wings are 1-based and Swan's are 0-based. For each
`call_edges` row: the caller's file and row, the callee symbol's name and
file; in Swan, `occurrences` joined to `symbols` where `is_def = 0`,
`by_name = 0`, same file, `start_line = row - 1`, same name. The script was
run from a scratch folder and is short enough to rewrite from this
description.
