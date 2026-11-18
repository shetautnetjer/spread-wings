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

## 2026-11-18: `survey`, the projects a repo holds

Agreed with the owner the same day (Swan's docs/wings-and-swan.md): what
can be learned by only reading files belongs here. First piece: a repo is
rarely one project at its top, and Swan's bugs of the week were each that
assumption (a nested cargo crate with no rows, a package with its own
tsconfig losing its imports, Go below the top run from the top).

- `spread-wings survey <repo>` (src/survey.goose): one entry per project,
  in path order. node (`package.json`), python (`pyproject.toml`,
  `setup.py`, `setup.cfg`, `requirements.txt`), rust (`Cargo.toml`), go
  (`go.mod`), java (Maven, Gradle), deno. For each: name, package manager
  and the file that says so (`packageManager`, else the lock file here or
  above), the versions it wants (`.nvmrc`, `.node-version`, volta,
  `.python-version`, `.bun-version`, `rust-toolchain[.toml]`, `go.mod`,
  `mise.toml`, `.tool-versions`) with ranges kept beside pins
  (`node.requires` from engines, `python.requires`, `rust.requires`), the
  workspace above it and whether that workspace lists it, whether
  `node_modules` or a virtualenv is there, the test script, TypeScript
  version and tsconfig files.
- A value set in a folder holds for the folders below until one says
  otherwise.
- It only reads: no package manager, interpreter or build file runs.
- On the four test repos: Understand-Anything 9 node projects under two
  pnpm workspaces (3 ms); relate 45 cargo, 7 node, 3 go, 2 java, 1 python
  (6 ms); rea 5 node, 2 python (11 ms); Agent-Reach 1 python (2 ms).
- Tests: tests/fixtures/survey and 13 checks; 94 pass in the microVM.

Limits:
- It does not check that a wanted version is installed on this machine.
- It does not read .gitignore: only the folders every walk skips
  (node_modules, target, dist, build, hidden ones) are left out.
- Workspace membership is by the workspace's own globs; a cargo path
  dependency outside them is not counted a member.
- Nothing uses it yet: Swan reading it in place of its own guesses is the
  next step there.

## 2026-11-18: `compiler` takes Swan's answer for every call site

`compiler` put only the calls tied by name to Swan. Most of what was still
wrong after the definitions change was tied another way (rea: 21,389 wrong
`imported_file` links), and calls no rule could tie had answers waiting.

- Every call site the map covers now gets Swan's answer: one repo
  definition becomes its only link (`compiler`), whatever rule had tied it
  and to however many candidates; outside the repo, no link
  (`compiler_outside`); a value the graph does not hold as a definition (a
  parameter, a variable), no link into other files than the one Swan names
  (`compiler_value`). Sites the map does not cover, or covers unclearly,
  stay as the rules left them.
- It says what it did: tied (as they were, narrowed from several,
  corrected, new), outside, values, left.
- After it, of the links Swan can judge: rea TypeScript 99.8% right (88.4%
  before), relate Rust 99.6% (91.3%), Understand-Anything 100% (84.7%),
  Python 99.3 to 100%. rea: 8,422 calls narrowed from several candidates
  to one, 2,669 corrected, 2,315 linked that no rule could tie.
- Time: rea 3.4 s for 739,448 call sites (1.2 s before, for the 10,496 tied by name); relate
  1.1 s.
- Tests: 8 checks on the kinds fixture with a hand-made map (a same-file
  link corrected, a shared call narrowed, an untied call linked, an
  outside call unlinked, a value call unlinked, an uncovered site left);
  the step from before leaves all of them as the rules had them. 102 pass
  in the microVM.

Limits:
- A site is a line and a name: two calls of one name on a line with
  different answers are left alone, as before.
- The graph is as good as the map is fresh: files changed since the map
  was built are skipped and counted.

## 2026-11-18: `update`, the graph from the files that changed

What was wrong: `index` builds the whole graph every time. On morluto/rea
that is 17 s (2.8 s reading files, 14.2 s tying calls to definitions)
for a one-line edit: too slow to run after every change, and the reason
Swan rebuilds its copy of the graph only when its own map is rebuilt.

- `spread-wings update <repo> <graph.db>` (src/update.goose) brings a
  graph up to date. It compares each file with a stamp `index` and
  `update` now keep (size, modification time, inode change time, content
  hash; table `stamps`), reads again only the files whose content changed,
  and ties again only the calls a change can reach. One JSON object says
  what it did: files changed, added, removed; calls tied again and the
  files they are in.
- The graph it leaves is the one `index` builds from the same files, row
  numbers apart. tests/graph_dump.py prints a graph without row numbers
  and the two are compared.
- The link script is the one `index` runs (`LINK_CALLS_SQL`), on a list of
  calls: `/*dirty: ... */` comments in it are opened into filters. The
  list (set out at the top of src/update.goose): every call of a file read
  again; every call, anywhere, of a name whose definitions in a changed
  file are not what they were (for a name defined in more than 50 places,
  only in the files that import the changed file: such a name is never
  tied further than that); the names a changed import line passes on;
  everything, when a file added or removed changes the repo's top-level
  names, or when the list would hold more than two calls in five. A
  function whose body alone changed keeps its callers' links, moved to its
  new row.
- `index` writes the same graphs as before (rea, relate,
  Understand-Anything, Agent-Reach: the dumps are identical to those of
  7beddf2, weights to the last digit) in the same time. Three things in it
  no longer hang on the order of rows: a file's node in the clustering is
  its place in the walk, weights are summed smallest first, and a choice
  between two equally short paths is spelled out.
- `RULES_NUMBER` (src/store.goose) numbers what `index` writes for a repo;
  a graph written under another number is built whole by `update`. A check
  holds the fixtures' graphs to the number.

| | `index` | `update`, nothing changed | one file edited | a file added or removed |
|---|---|---|---|---|
| rea (7,784 files, 744,582 call sites) | 17.0 s | 0.02 s | 0.26 to 0.29 s | 1.2 s |
| relate (2,078 files, 183,859 call sites) | 5.0 s | 0.01 s | 0.10 to 0.17 s | 1.1 s |
| Understand-Anything (324 files) | 0.24 s | under 0.01 s | 0.02 s | 0.03 s |
| Agent-Reach (87 files) | 0.12 s | under 0.01 s | 0.01 s | 0.04 s |

Checked:
- 55 new checks, 157 pass in the microVM
  (`SW_SPACE_CHECKPOINT=swan-test-v4 scripts/space-test.sh`): a repo made
  of the fixtures, then one change at a time (a line above a file's
  functions, a function renamed, a file added, renamed, removed, lines
  taken out of Rust, TypeScript, JavaScript, Goose and Python files, a new
  folder at the top, a file touched, a file changed and given back its old
  time, a 60th definition of a name and ten of them removed), the updated
  graph compared with a fresh one after each; what the answer lists; the
  graphs it builds whole and why.
- Each check was seen to fail on a build with the fault it is there for:
  the build before this change (no `update`: 49 of the 55 fail, and the
  other six state what holds without it, the rules hash among them);
  imports found through the index they are written to (an import tied
  twice: 4 links where 2 belong); the top-level names read after the new files had rows (a call
  left "outside the repo" that no longer was); inode time not compared (a
  restored file missed); links not moved to a definition's new row (callers
  in other files tied again); the importers of a file left out for a name
  defined in more than 50 places (a link missing); the two-in-five switch
  left out (the answer says a list was tied, not all).
- Random changes on copies of real repos, 1 to 3 at a time out of 20 kinds
  (edits, appended and renamed functions, imports dropped and borrowed,
  files copied, moved, swapped, deleted, folders moved, `__init__.py`
  added and removed, new top-level folders), the updated graph compared
  with a fresh one after every batch (tests/random_changes.py). On the
  final build: Agent-Reach 100 rounds, Understand-Anything 100, this repo
  (Goose) 60, relate 20, rea 8; 1,001 rounds over the day's builds. None
  differed.

Found by measuring, and fixed before this entry:
- An import read through the index on the column being written came round
  twice (the classic update-while-scanning fault). The imports to tie are
  now listed first. `index` was not affected (it reads them in row order).
- A link to a removed definition could come to name a new one that took
  its row number. New rows now never take a number just freed in the same
  update.
- The first version tied again every call of every name a changed file
  defined or imported: 3,399 of 7,200 calls on Agent-Reach for two
  functions appended to a test file. Comparing the definitions and import lines
  before and after brought that to the file's own calls.
- Moving a folder of 149 test files on rea tied again 568,459 of its
  744,581 calls and took 23.6 s, longer than `index`. Two causes: the
  names on the import lines of every moved file were counted as passed on,
  though nothing imports from a test file (now only a file something
  imports from passes names on); and the script run on a list pays for
  the list at every statement (now, past two calls in five, all calls are
  tied the way `index` ties them). With those, and the two narrowings in
  the next point, the same move takes 5.6 s and ties 57,040 calls again.
- Two narrowings that came out of that move: a name defined in more than
  50 places (`it`, `close`, `run`) is redone only in the files that import
  the changed file; and the calls of a file that binds a variable from a
  call of a changed name are redone only when some definition of the name
  says what it returns, since nothing else is read off it.
- A second of every update on rea went to work that did not depend on the
  change: finding the groups again (0.7 s; now skipped when the files and
  the links between them are as they were) and four statements reading
  every call (0.3 s; now only the listed ones).

Found and not done:
- `overview` takes 94 s on rea (93.8 s on the build before this one too):
  its "most called" query joins definitions to call links, which have no
  index on the definition. Swan's `repo_overview` waits on it. Its own
  change.

Limits:
- Swan does not use it yet: it still runs `index` and `compiler` when its
  map is rebuilt. And `update` keeps a graph of the rules alone: one
  holding `compiler` or `decide` answers is built whole, and says so. How
  compiler answers stay on an updated graph is part of the next step (the
  watcher).
- A file added or removed costs about a second on rea and on relate:
  every import is tied again and the groups are found again. When it
  changes the repo's top-level names (a new folder at the top, a Python
  package folder), every call is tied again, which is `index`'s link step
  (14 s on rea). A folder of 149 test files moved: 5.6 s.
- An edit that changes the links between files (a new import, a first
  call into another file) has the groups found again: 0.7 s more on rea.
- A change to an import line that names a file of the repo, in a file
  that other files import from, ties again every call of the names on
  that line, anywhere; so does a change to the definitions of a common
  name. Right, and sometimes wide. Past two calls in five it costs what
  `index`'s link step costs.
- A file edited in the last three seconds is read once more at the next
  update (its times are not trusted yet). That costs a read, not a parse.
- Two updates of one graph at once: the second stops with SQLite's
  "database is locked", and the graph is the first one's.
- Row numbers in an updated graph are not those of a fresh one. Nothing in
  Spread-Wings reads meaning into them; `decide` asks its questions in
  row order, so under `--max` it may ask a different subset.
