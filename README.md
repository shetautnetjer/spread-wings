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

  | Repository | Files | Definitions | Call sites | Index time |
  |---|---|---|---|---|
  | a small Rust workspace | 20 | 180 | 1,176 | 0.13 s |
  | Understand-Anything | 324 | 1,048 | 28,413 | 0.4 s |
  | Graphify | 701 | 13,383 | 87,628 | 2.1 s |
  | pydantic/monty | 1,575 | 18,460 | 138,748 | 3.1 s |

  (One Linux machine, 32 threads, warm disk cache.)
- **Nothing to trust.** It never runs a repository's code, builds or package
  managers. It only parses files, so any repository can be indexed by an agent
  with no human approval.
- **Says what kind of fact each answer is.** Every link is marked as matched
  by name or by path. Nothing is invented by a model in 0.1.
- **No LLM needed.** The graph comes from tree-sitter parses and graph
  algorithms. A cheap decision model (Span-02) is planned for 0.2, to answer
  typed questions with probabilities, never to write free text (see
  [the design](docs/DESIGN.md)).

## What it builds

- **Files, definitions, imports and call sites**, from
  [goose-treesitter](https://github.com/shetautnetjer/goose-treesitter)
  patterns run on every core.
- **Links**: imports resolved to files (relative TS/JS paths, Python modules,
  Rust `mod`, `crate::`, `self::`, `super::` and workspace crates), and calls
  linked to definitions with the same name (the same file first; a name with
  several definitions shares its weight; names defined in more than 8 places
  aren't linked).
- **Communities**: groups of files that import and call each other, found
  with Louvain clustering (deterministic), each named after its most linked
  file, with its main files and most-called definitions.
- Stored in one SQLite file through
  [goose-sqlite](https://github.com/shetautnetjer/goose-sqlite).

## Use

```bash
scripts/build.sh                      # needs the Goose compiler (GOOSE=/path/to/goose)
bin/spread-wings index ~/code/myrepo myrepo.db
bin/spread-wings overview myrepo.db   # communities, main files, most-called names
bin/spread-wings find myrepo.db parse_config
bin/spread-wings neighbors myrepo.db src/config.py
bin/spread-wings callers myrepo.db parse_config
bin/spread-wings serve myrepo.db      # the same four tools over MCP (stdio)
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
- `from . import x` in Python isn't linked yet.
- Calls are matched by name: two functions with the same name aren't told
  apart, and method calls aren't tied to their class.
- Large repos can produce one big community where code is densely linked by
  common names. A resolution setting comes next.

## Documents

- [Design](docs/DESIGN.md)
- [Status](STATUS.md)
- [Notes for agents working on this repo](AGENTS.md)

## License

MIT. See [LICENSE](LICENSE).
