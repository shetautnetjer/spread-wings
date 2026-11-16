# Spread-Wings

A broad code graph for agents, built from syntax alone, in
[Goose](https://github.com/aardappel/goose).

Point it at any repository and it maps the whole thing in about a second:
which files belong together, what each one defines, what imports and calls
what. Agents use it to get the shape of an unfamiliar codebase before they
read any code. It is a take on [Graphify](https://github.com/Graphify-Labs/graphify),
rebuilt to be fast, local and honest about what it knows.

> **Status: 0.1.** Python, TypeScript/TSX, JavaScript and Rust. Links are
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
  probabilities, never free text. On Graphify's repo it removed 11,980 false
  links (`dict.get` linked to httpx's `Client.get`) and tied 1,631 calls to
  one definition, for $0.16 (see [the design](docs/DESIGN.md)).

## What it builds

- **Files, definitions, imports and call sites**, from
  [goose-treesitter](https://github.com/shetautnetjer/goose-treesitter)
  patterns run on every core.
- **Links**: imports resolved to files (relative TS/JS paths, Python modules,
  Rust `mod`, `crate::`, `self::`, `super::` and workspace crates), and each
  call tied to a definition by the strongest evidence the code gives, first
  match wins: **same_file**; **imported_name** (the caller's file imports
  that name from a file defining it); **imported_file** (it imports a file
  defining it); else **by_name** (any definition with that name, for names
  defined in at most 8 places). Every link stores which rule decided it.
- **Communities**: groups of code files that import and call each other,
  found with Louvain clustering (deterministic, resolution 1.5 by default,
  `--resolution N` to change). Test files don't form groups of their own:
  each joins the community of the code it uses most. Each community is named
  after its most linked code file and lists its code files, test files, main
  files and most-called definitions.
- Stored in one SQLite file through
  [goose-sqlite](https://github.com/shetautnetjer/goose-sqlite).

## Use

```bash
scripts/build.sh                      # needs the Goose compiler (GOOSE=/path/to/goose)
bin/spread-wings index ~/code/myrepo myrepo.db              # --resolution 2 for smaller communities
bin/spread-wings overview myrepo.db   # communities, main files, most-called names
bin/spread-wings find myrepo.db parse_config
bin/spread-wings neighbors myrepo.db src/config.py
bin/spread-wings callers myrepo.db parse_config
bin/spread-wings serve myrepo.db      # the same four tools over MCP (stdio)
OPENROUTER_API_KEY=... bin/spread-wings decide myrepo.db   # optional: Span-02 decisions for calls still by_name
```

Register it with Claude Code:

```bash
claude mcp add spread-wings -s user -- /path/to/bin/spread-wings serve /path/to/myrepo.db
```

All output is JSON.

## Known limits (0.1)

- Four languages. Goose-treesitter parses more (Java, Kotlin, C/C++, C#,
  PHP, Lua, GDScript, shaders); their patterns come next.
- Patterns match fixed shapes, so unusual definitions can be missed (for
  example a Python function inside a decorator factory's return).
- Without `decide`, method calls on objects (`x.get()`) stay `by_name`.
  Calls through module aliases and re-exported names aren't resolved by the
  import rules yet (`decide` handles most of them).

## Documents

- [Design](docs/DESIGN.md)
- [Status](STATUS.md)
- [Notes for agents working on this repo](AGENTS.md)

## License

MIT. See [LICENSE](LICENSE).
