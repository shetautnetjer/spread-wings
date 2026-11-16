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
   - Each call is tied to definitions by the first rule that applies:
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
- Incremental re-indexing by file content hash.
- Links to Swan: from a Spread-Wings community to Swan's precise map.
