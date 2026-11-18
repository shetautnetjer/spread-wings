# Spread-Wings design

## Goal

Give an agent the shape of a whole repository, fast enough to rebuild after
every change, with nothing to approve and no invented facts.

## Where it sits

| | Spread-Wings | Swan | Graphify |
|---|---|---|---|
| Question it answers | "What is this codebase, what goes with what?" | "Exactly who calls this, what breaks?" | Both, broadly |
| Source of facts | tree-sitter parses | compilers' SCIP indexers, language servers | tree-sitter, plus an LLM layer for docs and similarity |
| Runs repo code | never | sealed (eggshell) | never for the graph |
| Precision | matched by name or path | compiler-resolved | mixed; LLM edges marked `INFERRED` |
| Speed | ~1 s per 1,000 files | seconds to minutes (indexers) | Python; slower |

Spread-Wings is the broad view, Swan the precise one. They can be used
together: Spread-Wings to find the area, Swan to answer inside it.

## Pipeline

1. **Walk** the repo, skipping hidden folders and dependency/build folders
   (`node_modules`, `target`, `dist`, `build`, virtualenvs, caches).
   Symlinked folders are not entered.
2. **Extract** (`src/extract.goose`). For each language, a short list of
   goose-treesitter patterns (`def $NAME($$$A) -> $R: $$$B`,
   `pub fn $NAME($$$A) { $$$B }`, `$F($$$A)`, ...). Files go to a pool of
   Goose worker threads, one per hardware thread, pulling from one queue, so
   a big file doesn't hold the others up. A worker parses its file once and
   matches every pattern against that tree (`search_loaded`), instead of
   parsing it again per pattern; this halved to thirded parse time. Results
   come back to the main thread, which writes them in file order, so the
   graph is identical every run. Each match becomes a fact: a definition (name, kind, line, byte
   span), an import (module text) or a call site (callee name). ES `import`
   and `export ... from` lines are read from the text, since a pattern can't
   hold the module string.
3. **Resolve** (`src/graph.goose`):
   - Imports to files by path rules per language. Rust also handles `mod x;`,
     `crate::`, `self::`, `super::` and workspace crates by name (`foo_bar`
     is a `foo-bar/src/lib.rs`).
   - Each call site is placed in the innermost definition that spans it.
   - Candidates are cut first by what the call's own form rules out: a
     definition in another language; a method, for a bare call; a plain
     function, for a call on an object (Rust, TypeScript, JavaScript; not
     when the object is the imported module); and, when the call names a
     type none of the candidates belongs to (`Vec::new()`), the methods of
     other types.
   - Each call is tied to definitions by the first rule that applies:
     `own_type` (`this.f()`, `self.f()`, `Self::f()`: the f of the type the
     calling method belongs to); `type_name` (`Type::f()`, `Type.f()`);
     `same_file`; `imported_name` (the caller's file imports that name, as
     `from m import f`, `import { f } from "./m"` or `use m::{F}`, from a file
     defining it); `imported_file` (it imports a file defining it);
     `by_name` (any definition of that name, only for names with at most 8
     definitions). Definitions at one level share the call's weight. The
     rule is stored on the link and shown per call site.
4. **File graph.** An import is weight 1. A call link counts 0.3 times its
   weight, and only for names defined in at most 3 files, so generic names
   (`new`, `parse`) don't glue unrelated files together.
5. **Communities.** Louvain clustering over the **code files only**: local
   moving to the best modularity gain (resolution γ, 1.5 by default), then
   each community becomes one node, until nothing moves. It runs on flat CSR
   arrays in Goose; SQLite merges the levels. Deterministic. Test files are
   then attached, each to the code community it links to most; tests linked
   to no code share one community. On a test-heavy repo (Graphify: 118 code
   files, 571 test files) clustering everything together made each community
   "a module and its hundreds of tests"; clustering code first gives the
   modules themselves (extractors, CLI and serve, extraction core, cache and
   install, watch, LLM). γ = 1 left 3 large groups there, γ = 2 started
   merging unrelated files; 1.5 was the clearest.
6. **Serve.** CLI and MCP tools read the SQLite file.
7. **Update** (`src/update.goose`), in place of 1 to 5 once a graph is
   there. See below.

Label propagation was tried first and dropped: one hub file imported
everywhere (a crate's `lib.rs`) pulled every file into its community.
Louvain handles hubs.

## Update

`update` walks the repo as `index` does and compares each file with its
stamp (size, modification time, inode change time, a hash of the content).
A file whose size and times are as stamped is not read. Any other is read
and its hash compared, so a touched file costs a read and nothing more. A
file written within three seconds of the run keeps no times in its stamp
and is read again next time: file times move in steps, and a second write
inside one step would otherwise look unchanged. The inode change time is
there because a file put back with its old modification time and size
(`cp -p`, a restore) has still changed.

A changed file's rows are dropped and written again. Its imports are tied
again; when a file was added or removed, every file's are, since which
file an import names hangs on which files there are.

The costly part of `index` is tying calls to definitions, and `update`
runs the same script (`LINK_CALLS_SQL`) on a list of calls instead of all
of them: comments of the form `/*dirty: ... */` in the script are opened
into filters when it runs for `update`. The list holds every call whose
links could differ, by what a call's links hang on:

- its own file's definitions, imports and variables: every call of a file
  read again, of a file whose imports now name other files, and of a file
  that binds a variable from a call of a changed name, when a definition
  of the name says what it returns (`-> Type`): that is what is read off it;
- the definitions of the name it calls: every call, anywhere, of a name
  whose definitions in a changed file are not what they were (by kind, the
  type they belong to, and signature line). A function whose body alone
  changed keeps its callers' links, which are moved to its new row. A name
  defined in more than 50 places is only ever tied within the caller's own
  file and the files it imports, so a change to one is redone only in the
  files that import the changed file;
- names passed on by a file (`from .base import f`), names called under
  another name, and what a function says it returns, each when the import
  lines of a changed file are not what they were;
- the repo's top-level names: when a file added or removed changes them,
  every call.

Past two calls in five the list is dropped and every call is tied, as
`index` does: the script run on a list pays for the list at each statement.

File links out of the files concerned are summed again, and the groups are
found again unless the files and every link between them are as they were.

Three things keep the result the graph `index` builds, whatever order the
rows were written in: a file's node number in the clustering is its place
in the walk (kept in its stamp), not its row number; weights are summed
smallest first, so the sum does not hang on the order of the rows; and
where one of several equally good files is taken, the choice is spelled
out. `tests/graph_dump.py` prints a graph without row numbers, and the
checks compare an updated graph with a fresh one after each kind of change.

### Watch

`watch` is `update` in a loop. It asks the system for file events on every
folder of the walk (inotify, one watch a folder) and sleeps. An event wakes
it; it waits until 200 ms pass with no further event (two seconds at
most), adds watches for folders made since, and runs `update`. Each update
that changed the graph is one line on standard output.

The events only wake it. What changed is found by `update`, which looks at
every file, so an event lost, or one for a file that does not matter, costs
a look and no more. A look every 30 seconds (`--every`) covers anything
missed. Without events (not Linux, or the limit on watches reached) it
looks every two seconds.

Each line carries what the change reaches: the files, not changed
themselves, that import or call into a file that changed, was added or is
gone, counted before the change and after, and the tests among them. That
is where a precise tool has to look again.

The watcher opens the graph for each update and closes it after, so a
reader always finds the last finished state, and `compiler --into` can copy
it at any time. It ends with the process that started it.

`RULES_NUMBER` (`src/store.goose`) numbers what `index` writes for a repo.
A graph written under another number is built whole: half of it under old
rules and half under new would be neither.

Measured on morluto/rea (7,784 files, 744,582 call sites; `index` 17 s):
nothing changed 0.02 s; one file edited 0.3 s; a file added or removed
1.2 s; a folder of 149 test files moved 5.6 s.

## Evidence model

Every fact is one of:

- **parsed**: a definition, import or call site as the parse found it;
- **matched by path**: an import linked to a file by path rules;
- **matched by name**: a call linked to definitions with that name.

Tools say which. Nothing is compiler-resolved, and in 0.1 nothing comes from
a model.

## Decisions with Span-02 (built)

`spread-wings decide <graph.db> [--max N]` asks
[Span-02](https://www.respan.ai/models/span-02) (`respan/span-02`, through
OpenRouter's System One endpoint, `/api/v1/systemone`) about every call
still `by_name` after the import rules: a typed **choice** among the
candidate definitions plus **outside** ("a library, a builtin or another
type"), with a probability per option.

- **Small states, questions per call.** The model bills the state once
  *per question* (measured: 1, 10 and 100 questions on one state cost 1x,
  10x and 100x the tokens), while a request with 100 questions takes about
  as long as one with 1 (1.1 s). So a state is a window, not a whole
  function: the file's path and imports, the function's first line, any
  import inside the function, and 4 lines around each ambiguous call. Calls
  close together (at most 9 lines apart) share one state and one request,
  at most 8 per request. Lines are numbered from the function's first line.
  About 510 input tokens per question, down from about 1,000 for whole
  functions.
- **Parallel.** Requests run on 32 worker threads (`--workers N`, at most
  128), retrying 429 and 5xx with backoff. The HTTP call is a small libcurl
  helper that reads the key from the environment by name, so the key never
  enters the graph or logs.
- **Cached by content** (model + state + question) in
  `~/.cache/spread-wings/decisions.db`: an unchanged function is never asked
  again.
- **Applied conservatively.** A definition chosen with p >= 0.6 becomes the
  call's only link (`resolution = decided`, weight p). "Outside" with
  p >= 0.6 removes the guessed links. Anything less certain stays `by_name`.
  File links and communities are then recomputed.

Measured on Graphify's repo (`52cb282`): 13,712 questions in 5,122
requests, none failed, **$0.157** in total, 206 s of waiting on the network.

- 11,980 calls were **outside** the repo: `dict.get`, `set()`, `set.add`,
  `Path.resolve`, `mock.patch`, networkx's `G.edges`. Each had been linked
  by name to a same-named repo method (httpx's `Client.get`, `Cookies.set`),
  so these were false edges, now removed.
- 1,631 calls were tied to **one repo definition**, mostly calls through
  module aliases (`llm.extract_files_direct`, `sc.sanitize_semantic_fragment`,
  `mainmod.main`, where `main` is defined 73 times). All 14 sampled were
  right.
- 101 stayed `by_name` (p < 0.6).
- One sampled mistake: a name imported from a module that only re-exports
  it (`from graphify.extract import _make_id`, defined in
  `extractors/base.py`) was called "outside" at p = 0.64. Following
  re-exports is a deterministic fix for the import rules.

### Rules learned from the answers

Span-02's answers showed where deterministic rules were missing, and each
rule was checked against those cached answers before replacing them:

| Rule | Settles | Agreement with Span-02 |
|---|---|---|
| `module_alias`: `llm.f()` after `from graphify import llm`, `import a.b as x`, `import * as x`, Rust `use crate::m;` | 894 links | 675 agree, 4 differ |
| `imported_name` through one re-export (`from graphify.__main__ import install`, defined in `install.py`) | part of 9,761 | 690 agree, 26 differ |
| `imported_name` through up to three re-exports (`_file_stem`: test → `extract.py` → `extractors/base.py` → `ids.py`) and `module_alias` through a re-export (`extract._cpp_preprocess`, defined in `extractors/fortran.py`), plus `from pkg import mod as x` | 295 more links | 4 differ, Span-02 wrong in all 4 |
| `external`: a call through a name bound by an import from outside the repo (`shutil.rmtree`, `nx.Graph`, a bare `patch(...)` from `unittest.mock`) | 875 calls | 715 agree, 0 differ |
| `builtin`: a bare call to a Python builtin (`set()`, `len()`, `sorted()`) the file neither defines nor imports | 1,107 calls | 1,107 agree, 0 differ |
| `outside_object`: a method call on a variable every assignment of which in that scope comes from an outside module, name, builtin or such variable (`G = nx.Graph()`, `m = PAT.match(...)`, `with open(p) as f`), or on a parameter typed with an outside name (`G: nx.Graph`). Modules from `importlib` don't count: they can be the repo's own | 766 calls | 117 agree, 0 differ, 2 Span-02 unsure (4 differed until `importlib` was excluded) |
| `builtin_method`: a builtin method name (`get`, `items`, `join`, `resolve`, `push`, `unwrap`, ...) called on an object, with no candidate in a file the caller imports: not linked | 9,271 calls | 9,258 agree, 2 differ, 11 Span-02 unsure |

Every difference sampled for the first two rules was Span-02 calling a
re-exported or aliased repo function "outside"; the rule was right. With
these rules, by-name call links on Graphify's repo dropped from 78,761 to
33,007 and the questions needed from 12,816 to 2,489.

### Corrections from review (2026-11-17)

A review bot's unverified notes were checked with fixtures; these held and
were fixed, each with a test that fails on the code before:

- **Common names.** A name defined in more than 50 places had no
  candidates at all, so `helper()` beside `def helper` went unlinked. Such
  names now keep the candidates in the caller's own file and in files it
  imports (Graphify's repo: 17,530 → 20,380 `same_file` links).
- **ES imports over several lines** (`import {` … `} from "./m"`) were not
  read, and `./m.js` naming a real `m.js` was not linked.
- **Python packages below another folder** (`python/mypkg/…`): `import
  mypkg.core` now finds the file by its path below any folder that is not
  itself a package; before, such calls were marked `external`.
- **`outside_object` was too trusting.** It saw only `x = f(...)`. Every
  other binding of the name (`x = other`, a tuple target, `for x in`,
  `with e as x`) is now recorded with an unknown value, which is never
  outside; a module-level variable is judged over the whole file (a function
  can rebind it with `global`) and is hidden by a parameter of the same
  name; a typed parameter must name the type exactly (`g: GraphView` is not
  `Graph`); `importlib` is excluded under any name it was imported as. On
  Graphify's repo this cost 4 of 762 notes.
- **`decide`** no longer uses an answer that names a definition it was not
  offered, nor two differing answers for two calls of one name on a line
  (links are kept per line and name); with questions to ask and no key it
  stops at once.
- **A graph written by another version** is refused with "rebuild it"
  (a layout number in `meta`), not a raw SQL error.

Not covered: comprehension variables, `match` captures and walrus targets
are not recorded as bindings.

### Rules checked against PyCharm (2026-11-17)

PyCharm, asked through its own MCP server what each call resolves to, was
the judge on Graphify's repo: 1,225 call sites in 62 seconds, at no cost
(all 325 calls then tied only by name, and 300-site samples of the linked,
outside and unlinked ones). It replaces the model's opinion as the score
for a rule.

| Rule | What it settles | PyCharm's verdict |
|---|---|---|
| A method call on a local object (`seen.add(x)`, `G.add_edge(...)` on a variable or parameter) is not a call of a module-level function of that name | 436 links removed | of 300 sampled, 290 had been wrong links, 2 real losses (a variable holding a module) |
| `local_value`: a bare call of a parameter or of a variable the function binds (`compute(...)`, `install, uninstall = PAIR[k]`), unless the function also defines it | 71 calls, never asked | 71 of 71 are the local binding |
| A loop variable over a library object's call (`for m in PAT.finditer(s)`, `for node in g.nodes()`); not over a builtin container, whose items can be anything | most of the gain below | no disagreement |
| A variable assigned from a repo function whose return annotation is an outside type (`-> nx.Graph`) | | no disagreement |
| A function imported under another name (`import global_add as _global_add`) | linked as `imported_name` | agrees |
| A typed parameter written `g: "nx.Graph"` or `Optional[nx.Graph]`; parameters read from the whole header, however many lines | | agrees |
| `imported_name` only for a bare call of a module-level definition; `imported_file` after the outside rules (it is the weaker evidence) | | agrees |

Calls still tied only by name on Graphify's repo: **325 → 98**. PyCharm
cannot resolve 30 of those either (untyped parameters, `with ... as x`,
test-client calls). Linking takes 1.2 s there (was 0.8 s), parsing 1.65 s
(was 1.3 s): seven more patterns and the full header of every definition.

### What it costs

The state is numbered from the function's first line, not the file's, so a
function that only moved (lines added above it) reads exactly the same and
keeps its cached answers. The state also lists the file's imports, which
helps tell repo calls from library ones.

| Run on Graphify's repo | Questions asked | Cost |
|---|---|---|
| First run, whole-function states, before the rules above | 13,712 | $0.157 |
| First run, whole-function states, with them | 2,408 | $0.0177 |
| First run, small windowed states, re-export rules (fresh cache) | 2,249 | $0.0106 (1.15 M tokens, 37 s on 32 workers) |
| First run, plus `external`, `builtin`, `outside_object` (fresh cache) | 353 | **$0.0021** (227 k tokens, 6 s) |
| After a one-line edit in one function | ~24 | ~$0.0002 |
| Unchanged | 0 | $0 |

Answers from small states against the first whole-function run (2,494
sites): 2,452 the same (2,214 asked again, 238 now settled by the new
rules), 8 unsure, 8 different. Of the 8: four are re-exports the rules now
follow (Span-02 had said "outside"), one is now right (`graph.query()` on a
FalkorDB client, not a test helper), and three are calls through a local
variable or a sample corpus file, where neither answer is exact.

What is still asked is mostly method calls on variables whose type only a
type checker knows: `G = build_from_json(...)` (a repo function returning a
networkx graph, often without a return annotation), `client.get(...)` on a
test client from a fixture. That is the boundary of syntax-only rules; the
answer past it is a compiler-level map (Swan's SCIP indexes), not more
rules.

### Compiler answers from Swan (built)

`spread-wings compiler <graph.db> <swan.db>` reads a Swan map (read only).
For each call still tied only by name, it looks at the compiler's
resolution of that name on the same line: all outside the repo removes the
guessed links; exactly one repo definition becomes the only link
(`resolution = compiler`, weight 1). Anything else stays for `decide`. Run
it before `decide`, so the model is only asked what the compiler can't say.

A `compiler` link is the strongest claim in the graph, so the map has to be
of this code. The step refuses a map whose root is another folder. It skips
every file changed after the map's SCIP run (Swan's own "stale" rule; the
match is by line, and lines move), and says how many calls that left out.
On a line with several calls of one name it takes the answer only when the
compiler answered at least as many uses as there are calls. "Left (unclear)"
in its output also counts names the compiler ties to a parameter or a local
variable holding a function: the real callee is whatever was passed in.

| Repo | By-name calls | Swan covers | Tied to one definition | Outside |
|---|---|---|---|---|
| PITL (Rust, TS) | 118 | 110 | 61 | 49 |
| Graphify (Python), after all rules | 351 | 120 | 0 | 106 (all 118 Span-02 had answered agree) |

On Graphify the rest is what Pyright can't type either (`G` passed in
untyped, test-client fixtures). A first `decide` run after `compiler` asks
246 questions for **$0.0014**.

The cache folder can be moved with `SPREAD_WINGS_CACHE=<dir>`; an empty one
measures a first run without touching the real cache.

## Further decision questions (planned)

[Span-02](https://www.respan.ai/models/span-02) (Respan, through OpenRouter as
`respan/span-02`) is a decision model: it answers typed questions (a choice,
yes/no, a score) about text and returns a probability for each answer. It
can't write free text, so it can't invent a concept or an edge. It only picks
among options Spread-Wings gives it. It is cheap enough to ask thousands of
small questions per repo.

Planned questions, each stored with its probability as the confidence and
marked **decided**:

- **Layer of a file**: a choice among `api`, `domain`, `data`, `ui`, `infra`,
  `test`, `tooling`, `docs`, from its path, imports and definitions.
- **Name ambiguity**: for calls still `by_name` after the import rules
  (mostly method calls on objects), which definition is most likely meant
  (a choice among them), from the call's line and the candidates'
  signatures. This replaces the shared weight with a probability.
- **Doc to code**: does this README or doc section describe this module
  (yes/no), for links from docs to code.
- **Community name**: a choice among labels built from the community's own
  identifiers and paths.
- **Entry points**: is this function an entry point (a CLI command, an HTTP
  handler, a job).

Rules: decisions are cached by content hash, so an unchanged file is never
asked again; decisions never replace parsed facts, only add to them; the API
key comes from the environment at run time (for example through
`pitl-op-env run`), never from a file in the repo.

## Later

- More languages (Java, Kotlin, C/C++, C#, PHP, Lua, Go).
- A resolution setting for Louvain, and splitting test files apart from the
  code they test.
- Swan reading the watcher's lines: its broad-map answers from a graph
  that follows the files, and its own map pointed at what a change reaches.
- `compiler` answers put again only where the graph or the map changed
  (the copy is made whole today).
- Links to Swan: from a Spread-Wings community to Swan's precise map.
