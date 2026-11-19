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

## 2026-11-18: `watch`, what a change reaches, and compiler answers into a copy

`update` made a graph cheap to bring up to date; something still had to run
it, and Swan's graph could not use it, since Swan's answers (`compiler`)
were written into the graph `update` would have to redo.

- `spread-wings watch <repo> <graph.db>` stays awake. It sleeps on file
  events from every folder of the walk, waits for the writing to settle
  (200 ms with no event, two seconds at most), runs `update`, and prints
  one line for each update that changed the graph. The events only wake
  it: what changed is found by `update`, which looks at every file, so a
  lost event delays a change until the next look (every 30 seconds,
  `--every`) and never loses it. A folder made later is watched from the
  next round. It ends when the process that started it ends.
- `update`'s answer, and so each line of `watch`, says what the change
  reaches: the files, not changed themselves, that import or call into a
  file that changed, was added or is gone (`reaches`, at most 200 named,
  `reaches_files` counts them), and the tests among them and among the
  changed files (`tests`).
- `spread-wings compiler <graph.db> <swan.db> --into <copy.db>` puts Swan's
  answers into a copy and leaves the graph as it is. The copy is the graph
  `compiler` leaves when run in place.
- Two updates of one graph at once no longer end in "database is locked":
  the second waits for the first (ten seconds at most) and finds its work
  done.

| rea (7,784 files, 655 folders) | |
|---|---|
| From an edit to the line that reports it | 0.5 s (0.2 s of that is waiting for the writing to settle) |
| Asleep for 30 s | 30 ms of processor time (the one timed look), 10 MB of memory |
| The copy alone (`VACUUM INTO`, 110 MB) | 0.1 s |

| relate | |
|---|---|
| `compiler` in place | 1.3 s |
| `compiler --into` | 1.1 s |

Checked:
- 16 new checks, 173 pass in the microVM
  (`SW_SPACE_CHECKPOINT=swan-test-v4 scripts/space-test.sh`): a watcher on
  a copy of the mini fixture, woken only by events (`--every 600`): its
  first line; a file edited, with what it reaches and the tests; a file in
  a folder made after it started, when made and when edited; a file of no
  known language (no line); a file removed, with the file that imported
  it; the graph it keeps against a fresh one; that it ends with the
  process that started it. `--into`: the graph untouched, the copy equal to
  compiler run in place, the graph still updatable and the copy not. Two
  updates at once: both end well, one did the work.
- Seen failing on builds with the fault: watches added only at the start
  (the edit in the new folder is missed); the tie to the starting process
  left out (the watcher lives on); `--into` writing to the graph itself;
  the files linking to a removed file not noted before its rows go (the
  removal reaches nothing). On the build before this one 12 of the first
  14 fail; the other two hold without a watcher. The two-at-once check was
  not seen failing: on a small repo the two rarely overlap. The fault it
  is there for was seen by hand on rea ("database is locked").
- `index` writes the graphs it wrote before: relate, Understand-Anything
  and Agent-Reach against the build of 7beddf2, by dump.
- `tests/random_changes.py`, since `update` was touched: 116 rounds on
  Agent-Reach, Understand-Anything and relate, none differing from
  `index`.

Limits:
- Swan does not read it yet. That is the next change, in Swan: its broad
  map from a graph that follows the files, with `compiler --into` for its
  answers, and what a change reaches passed on.
- The copy with compiler answers is made whole each time, after any
  change, before the first question that needs it: 1.1 s on relate. On
  rea the copy itself is 0.1 s and the compiler step was 3.4 s when last
  measured (the `compiler` entry above); the two were not timed together, as this
  machine holds no Swan map of rea now.
- File events are Linux's (inotify). The system's limit on watches
  (`fs.inotify.max_user_watches`) counts every folder; past it the watcher
  says so on its lines (`"watching":"a look every 2 seconds"`) and looks
  on a timer.
- A storm of writes (a build writing into a watched folder) has it update
  every two seconds for as long as the storm lasts.
- It ends with the process that started it, so it cannot be left running
  from a shell that then closes; under a service manager it lives as long
  as the service.
- `decide` answers have no `--into`.

## 2026-11-18: a trial in Rust: the same graph, the same checks, the same speed

The owner asked whether this would have been better in Rust, with Goose for
the parts it suits. Answered with a port on a branch, held to a bar written
before any Rust was ([docs/rust-port.md](docs/rust-port.md), which has the
tables, the log and what differs). The Goose program in `src/` is still the
one that ships; `rust/` is the trial.

- **The same graph.** `index` with the Rust program writes the graph the
  Goose program writes, by `tests/graph_dump.py --hash`, on the fixtures,
  Agent-Reach, Understand-Anything, relatedb/relate, morluto/rea and cobra:
  6 of 6 the same hash. `update` against `index` under
  `tests/random_changes.py`: six runs on four repos (20, 20, 20, 20, 10 and
  3 rounds), every round the same. A file's stamp is the same number in
  both (Goose's `hash`, carried over step for step), so either program can
  bring the other's graph up to date.
- **The same checks.** In the microVM with no Goose program in `bin/`: 174
  of 174 of `tests/test.sh` with the Rust program, and 5 of 5 `cargo test`.
  The Goose program: 174 of 174. (173 before; the new one holds
  `rust/src/sql.rs` to the Goose sources, and fails when a script there is
  changed by hand.)
- **The same speed.** Medians, one machine, the programs turn about:

  | repo | program | index | update, nothing changed | update, one file edited | watch, idle |
  |---|---|---|---|---|---|
  | relate (2,078 files) | Goose | 4.95 s, 97.1 MB | 8.6 ms | 103.9 ms | no CPU, 8.6 MB |
  | | Rust | 4.84 s, 83.9 MB | 9.3 ms | 102.1 ms | no CPU, 10.0 MB |
  | rea (7,784 files) | Goose | 16.62 s, 209.1 MB | 20.5 ms | 287.8 ms | no CPU, 10.1 MB |
  | | Rust | 16.42 s, 182.9 MB | 22.1 ms | 282.0 ms | no CPU, 12.2 MB |

  The time is in tree-sitter and SQLite, which are the same C code in both
  programs (on rea: 2.7 s reading, 13.6 s linking). The Rust program is
  8.2 MB, the Goose one 33.5 MB.
- **What it took.** One session: 26 minutes to the same graph from `index`,
  38 to every command and the suite, about an hour and a quarter with the
  table and the records. 4,942 lines of Rust for 5,121 carried over (Goose,
  its C glue, and the parts of goose-treesitter and goose-sqlite it leans
  on). The 1,586 lines of scripts are not retyped:
  `scripts/sql-from-goose.py` takes them from `src/*.goose`. No build failed
  for a reason in the language, and no stage wrote a different graph at its
  first build; this was finished code carried over line by line, not new
  work.
- Measuring found one thing: the `curl` crate set libcurl and OpenSSL up
  at every start (half a millisecond and 3.7 MB on every command). `decide`
  calls libcurl itself now, on the first request, as the C helper does.

Not done, and not proven:

- Nothing is decided. By the owner's rule (tools in Goose, and Rust where
  it is measurably better) these numbers do not ask for Rust. The other
  reasons for or against (packages to maintain, who writes the code) are
  not numbers and are the owner's to weigh.
- While both are there, a change to the Goose code has to be carried over
  to `rust/` by hand. Only the scripts are held in step by a check.
- `decide` has not asked the real service from the Rust program (that
  costs money). The request is checked against a server on the same
  machine, and the cache keys against Goose's hash.
- Errors read differently (no `goose runtime error:` before the message, no
  source line after), and JSON that is not JSON gets another wording.
- Swan builds the Goose program from this repository, as before. Nothing in
  Swan changed.

## 2026-11-18: Rust is what is built; the Goose program is retired

After the trial above the owner chose Rust ("I think I will stay rust"), for
reasons beyond its numbers: easier to build on, to carry other tools' ideas
into (he named Graphify) and to add languages to. This change makes it so.

- `scripts/build.sh` builds the program with cargo (`--locked`: the crate
  versions `Cargo.lock` pins) and puts it at `bin/spread-wings`, where
  everything already looks for it.
- The repository is the Rust project: `Cargo.toml` at the top, `src/*.rs`.
  `src/*.goose` and `native/` are gone; as they last were, they are at
  commit `d7a8db1`.
- What was written beside the code came along. Each script in `src/sql.rs`
  stands with the comment that stood above it in the Goose sources, under a
  name that says what it is (39 had been named after a line number). Each
  module opens with the comment its Goose file opened with. The layout and
  rules numbers are in `src/store.rs`.
- `scripts/sql-from-goose.py` and its check went with the sources they
  read. The suite is the 173 checks it was before the trial, and
  `scripts/space-test.sh` runs `cargo test` (5) before it.
- Checked: built this way, the program writes the graph the last Goose
  build writes, by `tests/graph_dump.py --hash`, on the fixtures and the
  five repos (6 of 6). In the microVM: 173 of 173, and 5 of 5.

Not done:

- Swan still builds the Goose program, from the commit its `wings/` points
  at. Its build script has to change together with that pin: the next
  change, in Swan.
- A program already installed is not replaced by this. It stays a Goose
  build until it is built again.
- An error no longer starts with `goose runtime error:` or ends with a
  source line. Nothing in this repository or its checks reads those;
  whatever else does would need a look.
- `decide` has still not asked the real service from the Rust program.
- No Rust version is pinned. Built and checked with cargo 1.98.1 (the
  microVM) and 1.100.0.
