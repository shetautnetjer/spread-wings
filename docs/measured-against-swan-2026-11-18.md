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

# Second pass, same day: definitions by node kind, and the type a call names

What changed: TypeScript, TSX, JavaScript and Rust definitions are read from
the syntax tree by the kind of each node (src/treedefs.goose) in place of a
list of shapes; calls are cut and tied by what their own form says
(src/graph.goose); and the comparison above is a command,
`spread-wings score <graph.db> <swan.db>`, so it can be run on any repo and
language Swan maps. Same repos, same Swan maps, same judge. "Before" is
609cecb scored by the new command; its links match the first pass above
within a few (the first pass's script also counted uses on import lines).

## Definitions the graph has, of those Swan has (same file, name and line)

| Repo, language | Kind | In Swan | Before | After |
|---|---|---|---|---|
| rea, TypeScript | method | 4,188 | 0 | 4,188 |
| | interface | 3,221 | 2,971 (92%) | 3,221 |
| | type | 3,181 | 0 | 3,181 |
| | class | 798 | 770 (96%) | 798 |
| | constructor | 637 | 0 | 637 |
| | function | 411 | 175 (43%) | 411 |
| | getter | 215 | 0 | 215 |
| Understand-Anything, TypeScript | function | 411 | 400 (97%) | 411 |
| | method | 241 | 0 | 241 |
| | interface | 134 | 123 (92%) | 134 |
| | type | 48 | 0 | 48 |
| relate, Rust | function | 18,785 | 17,835 (95%) | 18,627 (99%) |
| | method | 6,145 | 5,693 (93%) | 6,133 |
| | struct | 1,671 | 1,327 (79%) | 1,670 |
| | enum | 892 | 796 (89%) | 890 |
| | type | 230 | 0 | 218 (95%) |
| | trait | 49 | 32 (65%) | 49 |

Python was 100% on all four repos before and is unchanged.

And of the definitions each repo's own call sites reach (any kind):

| Repo, language | Kind in Swan | Reached | Before | After |
|---|---|---|---|---|
| rea, TypeScript | variable (a constant holding a function) | 20,192 | 4,213 (21%) | 20,163 |
| | method | 3,856 | 0 | 3,856 |
| | property | 710 | 0 | 456 (64%) |
| | function | 400 | 170 (42%) | 400 |
| | parameter | 146 | 0 | 1 |
| relate, Rust | function | 8,460 | 7,742 (92%) | 8,460 |
| | method | 4,787 | 4,448 (93%) | 4,783 |
| | enum_member | 942 | 0 | 0 |
| | field | 126 | 0 | 0 |

## Links

All rules together, per language of the calling file. "Right" is of the
links Swan can judge. A call whose candidates share its weight has one link
per candidate, so the last column counts calls: how many of the judged
calls have the right link among theirs.

| Repo, language | | Links | Judged | Right | Wrong | Calls with the right link |
|---|---|---|---|---|---|---|
| rea, TypeScript/JS | before | 172,407 | 82,788 | 35,990 (43%) | 46,798 | 35,556 of 55,961 (64%) |
| | after | 276,371 | 206,297 | 180,763 (88%) | 25,534 | 176,714 of 181,546 (97%) |
| | after `compiler` | 274,448 | 204,374 | 180,750 (88%) | 23,624 | 176,716 of 181,365 (97%) |
| Understand-Anything, TypeScript/JS | before | 4,291 | 2,022 | 1,977 (98%) | 45 | 1,955 of 1,979 (99%) |
| | after | 6,510 | 3,815 | 3,231 (85%) | 584 | 3,204 of 3,210 (100%) |
| relate, Rust | before | 129,565 | 102,734 | 49,051 (48%) | 53,683 | 46,899 of 61,012 (77%) |
| | after | 98,744 | 89,275 | 56,250 (63%) | 33,025 | 54,992 of 64,872 (85%) |
| | after `compiler` | 70,762 | 61,293 | 55,954 (91%) | 5,339 | 54,992 of 58,394 (94%) |
| relate, Python | before | 3,813 | 2,946 | 2,880 (98%) | 66 | 2,753 of 2,786 (99%) |
| | after | 3,377 | 2,897 | 2,875 (99%) | 22 | 2,754 of 2,776 (99%) |
| Agent-Reach, Python | before | 3,231 | 3,019 | 2,771 (92%) | 248 | 2,729 of 2,873 (95%) |
| | after | 3,221 | 3,013 | 2,773 (92%) | 240 | 2,733 of 2,869 (95%) |

(Understand-Anything's 584 wrong links are 578 `imported_file` links from
one test file that imports ten parsers and calls `parser.analyzeFile(...)`:
each call is linked to all ten `analyzeFile` methods, one of them right,
for every one of the 712 calls.)

By rule, after (links: right of judged):

| Rule | rea, TypeScript | relate, Rust |
|---|---|---|
| own_type | 3,881: 3,854 of 3,854 (100%) | 5,072: 5,011 of 5,033 (100%) |
| type_name | 611: 604 of 609 (99%) | 7,699: 7,439 of 7,613 (98%) |
| same_file | 100,236: 66,006 of 67,019 (98%) | 21,738: 20,051 of 21,491 (93%) |
| imported_name | 86,761: 85,593 of 86,711 (99%) | 2,681: 2,645 of 2,653 (100%) |
| module_alias | 38: 38 of 38 | 81: 81 of 81 |
| imported_file | 52,295: 21,930 of 43,319 (51%); the right link is among a call's for 19,712 of 22,311 calls (88%) | 6,510: 3,355 of 6,197 (54%); 3,189 of 5,038 calls (63%) |
| by_name | 21,891: 2,738 of 4,747 (58%); 2,723 of 2,963 calls (92%) | 54,963: 17,668 of 46,207 (38%); 17,362 of 24,268 calls (72%) |

## What the call's own form rules out (measured before each rule went in)

| Rule | Links it removed | Of them right |
|---|---|---|
| A call on an object does not reach a plain function (Rust; TypeScript and JavaScript unless the object is the imported module) | rea 19,901; relate 9,381 | 471; 14 |
| A bare call does not reach a method | relate 2,309 | 150, most to a function nested in a method, which is no longer counted a method |
| A type is named and no candidate is that type's (`Vec::new()`, `Promise.all()`) | relate 5,211; rea 1,277 | 248; 3 |
| `self.f()` whose own type has no f here: not tied by name | relate 911 | 0 |
| A call does not reach a definition of another language | relate: Python by_name 26% to 100% right, JavaScript 356 links to 58 | |

## Time

The link step reads more definitions now. rea: index 10.1 s before, 17.3 s
after (parse 2.3 to 2.8 s, link 7.8 to 14.5 s); relate 5.3 s and 5.1 s. One
index was removed on the way (`defs(name)` beside `defs(name, sfile)`: with
both, SQLite read every definition of a common method name for each import
of each call, 13 s of a 29 s link step on rea).

## Still open

- **A call on an object whose type the code does not name** (`x.f()`) is
  the bulk of what is left: `imported_file` and `by_name` for methods. The
  `compiler` step settles only `by_name` calls; on rea most of the unsure
  ones are `imported_file`, which it leaves alone. Letting Swan's answer
  replace any guessed link, and add the links the rules could not make, is
  the next step.
- Rust enum variants (`Mode::On(x)`, 942 reached on relate) and TypeScript
  parameters and non-function properties that are called are not
  definitions.
- relate's JavaScript: `imported_file` 130 right of 330.
- Not read: keys of an object literal that hold a function, namespaces,
  JSX element use (`<Panel />` is a use of Panel, and no call).
- Java, Kotlin, C, C++, C#, PHP and Lua have grammars in goose-treesitter
  and no reader here yet; Go has no grammar. `score` already lists what
  Swan has for them (rea: 204 C++ functions, 62 Java methods; relate: 257
  Go functions, 345 Java methods), all at 0.

# Third pass, same day: the compiler's answer for every call site

`compiler` put only the calls tied by name to Swan. The second pass showed
that most of what was still wrong was tied some other way (`imported_file`
on TypeScript), and that calls no rule could tie had answers waiting. It
now takes Swan's answer for every call site the map covers: one repo
definition becomes the site's only link; outside the repo, no link; a
value the graph does not hold as a definition, no link into other files
than the one Swan names.

| Repo | Call sites | Swan covers | Tied to one definition | of them: as they were / narrowed from several / corrected / new | Outside (guessed links removed) | Values | Left unclear | Time |
|---|---|---|---|---|---|---|---|---|
| rea | 739,448 | 264,739 | 181,860 | 167,563 / 8,422 / 2,669 / 2,315 | 80,282 (2,096) | 2,156 | 441 | 3.4 s |
| relate | 180,610 | 154,695 | 63,830 | 51,921 / 5,477 / 1,050 / 5,077 | 85,205 (8,604) | 4,839 | 821 | 1.1 s |
| Understand-Anything | 28,096 | 7,111 | 3,494 | 3,397 / 61 / 6 / 0 | 3,592 (0) | 14 | 11 | 0.07 s |
| Agent-Reach | 6,963 | 5,347 | 2,788 | 2,647 / 64 / 16 / 43 | 2,522 (108) | 14 | 23 | 0.03 s |

Links right, of those Swan judges, after `compiler` (before this change in
brackets): rea TypeScript 181,806 of 182,253, 99.8% (88.4%); relate Rust
60,880 of 61,116, 99.6% (91.3%); Understand-Anything TypeScript 3,210 of
3,210 (84.7%); relate Python 2,829 of 2,829 (99.2%); Agent-Reach Python
2,793 of 2,812, 99.3% (92.7%). These are the map's own answers put into the
graph, so they say how much of the graph the map now speaks for, not how
good the rules are: the rules' own numbers are the second pass's.

What stays a guess: every call site Swan's map does not cover (rea: 474,709
of 739,448, mostly calls into libraries, which have no link anyway, and
files of languages Swan did not index), and the 441 it covers unclearly.
