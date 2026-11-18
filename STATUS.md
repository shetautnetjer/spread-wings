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

## 2026-11-18: measured against Swan; the compiler step in under a second

- `docs/measured-against-swan-2026-11-18.md`: every call link on three
  repos put beside Swan's compiler-resolved references. `same_file`,
  `imported_name` and `module_alias` hold (89 to 100% right). `by_name` is
  most of the links on a large repo and mostly wrong (32% right on relate,
  about 0% on rea); `imported_file` is weak too (36% and 8%). On
  TypeScript, constants holding a function with any type annotation, and
  all class methods, are not definitions in the graph, so Swan's answers
  for them have nothing to attach to.
- `compiler`: three indexes on its working tables. relate 77 s to 0.5 s,
  rea 30 s to 1.2 s, with the same links, calls, communities and file
  edges as before on both.
- Not fixed here: the TypeScript definitions, what `callers`, `touches` and
  the communities do with by-name links, folders git ignores, one graph
  per server, no installer.


## 2026-11-18: definitions by node kind; the type a call names; `score`

What was wrong (docs/measured-against-swan-2026-11-18.md, first pass):
definitions were found by a list of shapes per language, so on TypeScript
a class method was never a definition and a constant holding a function
only when it carried no type; on Rust `pub(crate) struct`, tuple structs
with generics, `unsafe trait`, `const fn` were missed. Calls to them were
then tied by name to something else or to nothing.

- **src/treedefs.goose**: TypeScript, TSX, JavaScript and Rust definitions
  are read from the syntax tree by the kind of each node. morluto/rea:
  15,109 definitions to 56,141; of Swan's 4,188 TypeScript methods the
  graph had 0 and has 4,188; of the 20,192 function-holding constants its
  calls reach, 4,213 and now 20,163. relatedb/relate: structs 79% to 100%,
  traits 65% to 100%. Python is unchanged (100%).
- **Links** (src/graph.goose): two rules ahead of the others, `own_type`
  (`this.f()`, `self.f()`) and `type_name` (`Type::f()`, `Type.f()`), 98 to
  100% right; and candidates the call's form rules out are dropped (a
  method for a bare call, a plain function for a call on an object, the
  methods of other types when a type is named, another language's
  definitions). A function nested in a function is no longer a method of
  the class around it. Calls keep the name before the callee (`qual`).
- **`spread-wings score <graph.db> <swan.db>`** (src/score.goose): the
  comparison with a Swan map as a command, per language: links by rule
  (judged, right, other file, outside; and per call), definitions by kind,
  and the definitions the repo's calls reach.

| | Links right, of those Swan judges | Calls with the right link among theirs |
|---|---|---|
| rea, TypeScript | 35,990 of 82,788 (43%) to 180,763 of 206,297 (88%) | 64% to 97% |
| relate, Rust | 49,051 of 102,734 (48%) to 56,250 of 89,275 (63%); after `compiler` 55,954 of 61,293 (91%) | 77% to 85%; 94% |
| Understand-Anything, TypeScript | 1,977 of 2,022 to 3,231 of 3,815 | 99% to 100% |
| Agent-Reach, Python | 2,771 of 3,019 to 2,773 of 3,013 | 95% both |

- `compiler` on rea ties 2,721 calls to one definition (26 before: the
  definitions it names now exist).
- Tests: tests/fixtures/kinds (TypeScript, JavaScript, Rust; 0.1.0 found 18
  of its 57 definitions) and 29 checks; 81 pass in the microVM
  (`SW_SPACE_CHECKPOINT=swan-test-v4 scripts/space-test.sh`).
- The graph's layout number is 8 (calls gained `qual`): an older graph is
  refused with the command that rebuilds it.
- Slower on a large repo: rea's link step 7.8 s to 14.5 s (four times the
  definitions); relate unchanged.

Limits:
- A call on an object whose type the code does not name is still a guess
  shared among the methods of that name: `imported_file` 51% of links
  right on rea TypeScript (the right one is among a call's links for 88%
  of calls), `by_name` 38% on relate Rust (72% of calls). `compiler`
  settles only `by_name`; it should take Swan's answer for any guessed
  link.
- Rust enum variants, TypeScript object-literal keys holding a function,
  namespaces and JSX element use are not read.
- Java, Kotlin, C, C++, C#, PHP, Lua: no reader yet (`score` shows them at
  0 beside what Swan has).
