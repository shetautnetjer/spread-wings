# Spread-Wings

A broad code graph for agents, built from syntax alone, in
[Goose](https://github.com/aardappel/goose).

Point it at any repository and it maps the whole thing in about a second:
which files belong together, what each one defines, what imports and calls
what. Agents use it to get the shape of an unfamiliar codebase before they
read any code. It is a take on [Graphify](https://github.com/Graphify-Labs/graphify),
rebuilt to be fast, local and honest about what it knows.

> **Status: 0.1.** Python, TypeScript/TSX, JavaScript, Rust and Goose. Links are
> matched by name or path, not resolved by a compiler, and every answer says
> so. For exact answers (this call reaches that exact function), use
> [Swan](https://github.com/shetautnetjer/Swan), its precise counterpart.

## Why

- **Fast.** Goose compiles to C. Spread-Wings starts instantly and parses on
  every core, so re-indexing after every change is cheap:

  | Repository | Files | Definitions | Call sites | Parse | Link + communities |
  |---|---|---|---|---|---|
  | a small Rust workspace | 20 | 180 | 1,176 | 0.07 s | 0.01 s |
  | Understand-Anything | 324 | 1,254 | 28,413 | 0.12 s | 0.02 s |
  | Graphify | 701 | 13,383 | 87,628 | 0.85 s | 0.25 s |
  | pydantic/monty | 1,574 | 23,009 | 138,682 | 0.89 s | 0.86 s |

  (One Linux machine, 32 hardware threads, warm disk cache.) Files go to a
  pool of worker threads, one per hardware thread, taking work from one
  queue; each file is parsed once and every pattern runs on that tree.
- **Accurate on what it claims.** On Graphify's own repo (commit `52cb282`),
  checked against Python's own parser: 13,127 of 13,127 functions, 206 of
  206 classes, every call site of six test names, and all 107 files that
  import `graphify/build.py`. All 262 calls of `build_from_json`, a name
  defined in six places, resolve to exactly one definition; the 198 callers
  hosted Graphify shows agree with every one of them.
- **Nothing to trust.** It never runs a repository's code, builds or package
  managers. It only parses files, so any repository can be indexed by an agent
  with no human approval.
- **Says what kind of fact each answer is.** Every link is marked as matched
  by name or by path. Nothing is invented by a model in 0.1.
- **No LLM needed, one cheap one optional.** The graph comes from tree-sitter
  parses and graph algorithms. `spread-wings decide` then asks Span-02, a
  decision model, typed questions about the calls the code alone can't tie
  down: which candidate definition, or "outside this repo", with
  probabilities, never free text. Rules learned from its answers settle most
  calls first; on Graphify's repo a first run costs about a fifth of a cent ($0.002), a
  re-index after a one-line edit $0.0002, and an unchanged one nothing (answers are cached
  by content; see [the design](docs/DESIGN.md)).

## What it builds

- **Files, definitions, imports and call sites**, from
  [goose-treesitter](https://github.com/shetautnetjer/goose-treesitter)
  parses on every core. TypeScript, TSX, JavaScript and Rust definitions
  are read from the syntax tree by the kind of each node (a method, a
  constant holding a function, a `pub(crate) const fn` are definitions
  however they are spelled); Python's, and every language's imports and
  calls, by pattern.
- **Links**: imports resolved to files (relative TS/JS paths, Python modules,
  Rust `mod`, `crate::`, `self::`, `super::` and workspace crates), and each
  call tied to a definition by the strongest evidence the code gives, first
  match wins: **own_type** (`this.f()`, `self.f()`: the f of the calling
  method's own type); **type_name** (`Type::f()`, `Type.f()`: the f of the
  type named); **same_file**; **imported_name** (the caller's file imports
  that name from a file defining it); **imported_file** (it imports a file
  defining it); else **by_name** (any definition with that name, for names
  defined in at most 8 places). A bare call never reaches a method, a call
  on an object never a plain function, and no call a definition in another
  language. Every link stores which rule decided it.
- **The survey** (`survey <repo>`, no graph needed): one entry per project in
  the repo (a `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, a
  Maven or Gradle build, `deno.json`), with its package manager, the
  versions it wants and the file that says so, its workspace and whether
  the workspace lists it, and whether its dependencies are installed. Read
  from manifest, lock and version files only; milliseconds.
- **Communities**: groups of code files that import and call each other,
  found with Louvain clustering (deterministic, resolution 1.5 by default,
  `--resolution N` to change). Test files don't form groups of their own:
  each joins the community of the code it uses most. Each community is named
  after its most linked code file and lists its code files, test files, main
  files and most-called definitions.
- Stored in one SQLite file through
  [goose-sqlite](https://github.com/shetautnetjer/goose-sqlite).

## Keeping it up to date

`spread-wings update <repo> <graph.db>` brings a graph up to date with its
repo without building it again. It finds the files that changed (by size
and times first; a file that might have changed is read and its content
compared), reads only those again, and ties again only the calls the change
can reach: the changed file's own, and the calls elsewhere of a name whose
definitions are no longer what they were. The graph it leaves is the one
`index` builds from the same files; the tests compare the two after every
kind of change (`tests/graph_dump.py` prints a graph without its row
numbers).

| morluto/rea: 7,784 files, 744,582 call sites | |
|---|---|
| `index` | 17 s |
| `update`, nothing changed | 0.02 s |
| `update`, one file edited | 0.3 s |
| `update`, a file added or removed | 1.2 s (every import is tied again: which file an import names hangs on which files there are) |
| `update`, a folder of 149 test files moved | 5.6 s |

It answers with one JSON object: the files changed, added and removed, how
many calls were tied again and the files they are in, and what the change
reaches: the files that import or call into a changed file, and the tests
among them. With no graph there it builds one. A graph it cannot bring up
to date (written by another version; one holding answers from `compiler` or
`decide`, which sit on links it would redo) is built whole, and the answer
says why.

`spread-wings watch <repo> <graph.db>` stays awake and does this whenever
files change. It sleeps on file events from the repo's folders, lets the
writing settle, runs `update`, and prints one line (update's answer) for
each change. On rea a line follows an edit by half a second; asleep, the
watcher holds 10 MB and uses a thousandth of a processor (one look every
30 seconds, in case an event was missed). It ends when the process that
started it ends.

A watched graph is one of the rules alone. `spread-wings compiler <graph.db>
<swan.db> --into <copy.db>` puts Swan's answers into a copy and leaves the
graph as it is, so the two go together: the watcher keeps the graph, and the
copy is made again when the graph or the map has changed.

## With Swan

Spread-Wings ships inside [Swan](https://github.com/shetautnetjer/Swan) as a
pinned submodule, and the two split the work on one line: what can be
learned by only reading files is Spread-Wings (the survey of a repo's
projects, the broad map, watching for changes, bringing the map up to date
from the files that changed and saying what a change reaches, which is where
Swan needs a precise look); what needs a compiler-grade tool to run
is Swan (exact references, renames, errors, edits, tests). Swan's answers
come back into the graph through `compiler`, and `score` grades the graph
against them. The agreed order of work is in Swan's `docs/wings-and-swan.md`.

## Use

```bash
scripts/build.sh                      # needs the Goose compiler (GOOSE=/path/to/goose)
bin/spread-wings index ~/code/myrepo myrepo.db              # --resolution 2 for smaller communities
bin/spread-wings update ~/code/myrepo myrepo.db             # after edits: the same graph, from the files that changed
bin/spread-wings watch ~/code/myrepo myrepo.db              # stay awake: update on every change, one line each
bin/spread-wings overview myrepo.db   # communities, main files, most-called names
bin/spread-wings find myrepo.db parse_config
bin/spread-wings neighbors myrepo.db src/config.py
bin/spread-wings callers myrepo.db parse_config
bin/spread-wings touches myrepo.db parse_config   # before an edit: the files, tests and groups it reaches
bin/spread-wings survey ~/code/myrepo             # the projects it holds: where, which package manager, which versions each wants
bin/spread-wings serve myrepo.db      # the same four tools over MCP (stdio)
bin/spread-wings compiler myrepo.db ~/.local/share/swan/maps/myrepo/swan.db   # optional: Swan's answer for every call site its map covers
bin/spread-wings compiler myrepo.db ~/.local/share/swan/maps/myrepo/swan.db --into answered.db   # the same, into a copy
bin/spread-wings score myrepo.db ~/.local/share/swan/maps/myrepo/swan.db      # what the definitions and links are worth, per language and rule, against that map
OPENROUTER_API_KEY=... bin/spread-wings decide myrepo.db   # optional: Span-02 decisions for calls still by_name
```

Register it with Claude Code:

```bash
claude mcp add spread-wings -s user -- /path/to/bin/spread-wings serve /path/to/myrepo.db
```

All output is JSON.

## Known limits (0.1)

- Goose is read by line, not from a syntax tree (goose-treesitter has no
  Goose grammar): definitions, `import .x;` and bare calls. A call into a
  file the caller does not import itself is matched by name, though Goose
  programs share one namespace across their imports.
- Five languages. Goose-treesitter parses more (Java, Kotlin, C/C++, C#,
  PHP, Lua, GDScript, shaders); their patterns come next.
- Python definitions, and all imports and calls, are matched as fixed
  shapes, so unusual ones can be missed (for example a Python function
  inside a decorator factory's return).
- A call on an object whose type the code does not name (`x.f()`) is tied
  to the methods called f in the caller's file, then in the files it
  imports, then anywhere: each candidate gets a link and a share of the
  weight. Against Swan (2026-11-18) the right one is among them for 88% of
  such TypeScript calls through an imported file and 72% of such Rust calls
  by name. `compiler` settles every call site a Swan map covers, whatever
  rule tied it (afterwards 99.6 to 100% of the links Swan can judge are
  right on the four test repos); `decide` asks a model about the rest.
- TypeScript: keys of an object literal that hold a function, namespaces
  and JSX element use (`<Panel />`) are not read.
- `update` and `watch` keep a graph of the rules alone. Answers from
  `compiler` go into a copy (`--into`), made again whole after a change
  (1.1 s on relate); `decide` has no such copy yet, and a graph it has
  written to is built whole.
- `watch` wakes on file events on Linux. Elsewhere, or past the system's
  limit on watched folders, it looks every two seconds.

## Documents

- [Design](docs/DESIGN.md)
- [Status](STATUS.md)
- [Notes for agents working on this repo](AGENTS.md)

## License

MIT. See [LICENSE](LICENSE).
