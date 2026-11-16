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
   `pub fn $NAME($$$A) { $$$B }`, `$F($$$A)`, ...) runs with
   `treesitter::search_files`, which parses files on every core with Goose
   threads. Each match becomes a fact: a definition (name, kind, line, byte
   span), an import (module text) or a call site (callee name). ES `import`
   and `export ... from` lines are read from the text, since a pattern can't
   hold the module string.
3. **Resolve** (`src/graph.goose`):
   - Imports to files by path rules per language. Rust also handles `mod x;`,
     `crate::`, `self::`, `super::` and workspace crates by name (`foo_bar`
     is a `foo-bar/src/lib.rs`).
   - Each call site is placed in the innermost definition that spans it.
   - Calls are linked to definitions with the callee's name: the same file
     first (weight 1), otherwise every definition of that name, the weight
     shared. Names with more than 8 definitions aren't linked.
4. **File graph.** An import is weight 1. A call link counts 0.3 times its
   weight, and only for names defined in at most 3 files, so generic names
   (`new`, `parse`) don't glue unrelated files together.
5. **Communities.** Louvain clustering: local moving to the best modularity
   gain, then each community becomes one node, until nothing moves. It runs
   on flat CSR arrays in Goose; SQLite merges the levels. Deterministic. Each
   community is named after its most linked file.
6. **Serve.** CLI and MCP tools read the SQLite file.

Label propagation was tried first and dropped: one hub file imported
everywhere (a crate's `lib.rs`) pulled every file into its community.
Louvain handles hubs.

## Evidence model

Every fact is one of:

- **parsed**: a definition, import or call site as the parse found it;
- **matched by path**: an import linked to a file by path rules;
- **matched by name**: a call linked to definitions with that name.

Tools say which. Nothing is compiler-resolved, and in 0.1 nothing comes from
a model.

## 0.2: decisions with Span-02

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
- **Name ambiguity**: when a call's name has several definitions, which one
  is most likely meant (a choice among them), from the call's line and the
  candidates' signatures. This replaces the shared weight with a probability.
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
- Incremental re-indexing by file content hash.
- Links to Swan: from a Spread-Wings community to Swan's precise map.
