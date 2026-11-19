// Syntax trees as flat tables, and ast-grep style patterns over them.
//
// Carried over from goose-treesitter (ts_shim.c and treesitter.goose), which
// the Goose program leans on: a tree is R ints for each node, in pre-order
// (symbol, flags, start and end byte, start row and column, first child,
// next sibling; -1 for none), and a pattern (`def $NAME($$$A): $$$B`) is
// code of the language with its metavariables renamed to identifiers,
// parsed by the same grammar and matched node against node.
//
// The grammars are the crates of the versions goose-treesitter pins, and the
// runtime is the `tree-sitter` crate of its version (0.25.10).

use crate::util::*;
use tree_sitter::{Language, Parser, Tree};

pub const R: usize = 8;
pub const F_NAMED: i64 = 1;
pub const F_EXTRA: i64 = 2;
pub const F_ERROR: i64 = 4;

pub fn language(lang: &str) -> Option<Language> {
    match lang {
        "typescript" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "tsx" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        "javascript" => Some(tree_sitter_javascript::LANGUAGE.into()),
        "python" => Some(tree_sitter_python::LANGUAGE.into()),
        "rust" => Some(tree_sitter_rust::LANGUAGE.into()),
        _ => None,
    }
}

/// The grammar for a file, by its name; "" when there is none. (The names
/// goose-treesitter gives; Spread-Wings reads the first five.)
pub fn language_of_path(p: &[u8]) -> &'static str {
    let e = |x: &str| ends_with(p, x.as_bytes());
    if e(".ts") || e(".mts") || e(".cts") { return "typescript"; }
    if e(".tsx") { return "tsx"; }
    if e(".js") || e(".jsx") || e(".mjs") || e(".cjs") { return "javascript"; }
    if e(".py") || e(".pyi") { return "python"; }
    if e(".rs") { return "rust"; }
    if e(".java") { return "java"; }
    if e(".c") || e(".h") { return "c"; }
    if e(".cc") || e(".cpp") || e(".cxx") || e(".hpp") || e(".hh") || e(".hxx") { return "cpp"; }
    if e(".cu") || e(".cuh") { return "cuda"; }
    if e(".kt") || e(".kts") { return "kotlin"; }
    if e(".lua") { return "lua"; }
    if e(".glsl") || e(".vert") || e(".frag") || e(".comp") || e(".geom") || e(".tesc") || e(".tese") { return "glsl"; }
    if e(".hlsl") || e(".hlsli") || e(".fx") { return "hlsl"; }
    if e(".wgsl") { return "wgsl"; }
    if e(".gd") { return "gdscript"; }
    if e(".cs") { return "csharp"; }
    if e(".php") { return "php"; }
    ""
}

pub fn parse_tree(lang: &str, src: &[u8]) -> Option<Tree> {
    let l = language(lang)?;
    let mut p = Parser::new();
    p.set_language(&l).ok()?;
    p.parse(src, None)
}

/// The nodes of a tree in pre-order, R ints each.
pub fn fill(tree: &Tree, out: &mut Vec<i32>) {
    out.clear();
    let mut c = tree.walk();
    let mut last: Vec<i32> = vec![-1];
    let mut parent: Vec<i32> = vec![-1];
    let mut depth = 0usize;
    let mut n: i32 = 0;
    loop {
        let node = c.node();
        let fl = (if node.is_named() { F_NAMED } else { 0 })
            | (if node.is_extra() { F_EXTRA } else { 0 })
            | (if node.is_error() || node.is_missing() { F_ERROR } else { 0 });
        let pt = node.start_position();
        out.extend_from_slice(&[
            node.kind_id() as i32, fl as i32, node.start_byte() as i32, node.end_byte() as i32,
            pt.row as i32, pt.column as i32, -1, -1,
        ]);
        if last[depth] >= 0 { out[last[depth] as usize * R + 7] = n; }
        else if parent[depth] >= 0 { out[parent[depth] as usize * R + 6] = n; }
        last[depth] = n;
        let me = n;
        n += 1;
        if c.goto_first_child() {
            depth += 1;
            if depth >= last.len() { last.push(-1); parent.push(-1); }
            last[depth] = -1;
            parent[depth] = me;
            continue;
        }
        let mut done = false;
        while !c.goto_next_sibling() {
            if !c.goto_parent() { done = true; break; }
            depth -= 1;
        }
        if done { break; }
    }
}

/// Parses src into nodes. False when the language has no grammar here.
pub fn parse(lang: &str, src: &[u8], nodes: &mut Vec<i32>) -> bool {
    match parse_tree(lang, src) {
        Some(t) => { fill(&t, nodes); true }
        None => false,
    }
}

#[inline] pub fn sym(n: &[i32], i: i64) -> i64 { n[i as usize * R] as i64 }
#[inline] pub fn flags(n: &[i32], i: i64) -> i64 { n[i as usize * R + 1] as i64 }
#[inline] pub fn start(n: &[i32], i: i64) -> i64 { n[i as usize * R + 2] as i64 }
#[inline] pub fn end(n: &[i32], i: i64) -> i64 { n[i as usize * R + 3] as i64 }
#[inline] pub fn row(n: &[i32], i: i64) -> i64 { n[i as usize * R + 4] as i64 }
#[inline] pub fn first(n: &[i32], i: i64) -> i64 { n[i as usize * R + 6] as i64 }
#[inline] pub fn next(n: &[i32], i: i64) -> i64 { n[i as usize * R + 7] as i64 }

/// Skips comments and other extras (tree-sitter counts error nodes as
/// extras too, but a pattern's metavariable can be one).
pub fn solid(n: &[i32], i: i64) -> i64 {
    let mut k = i;
    while k >= 0 && (flags(n, k) & (F_EXTRA | F_ERROR)) == F_EXTRA { k = next(n, k); }
    k
}

pub fn is_word(s: &[u8]) -> bool {
    s.iter().all(|&c| c.is_ascii_alphanumeric() || c == b'_')
}

const MV: &[u8] = b"zswan_mv_"; // $X becomes zswan_mv_X
const MVM: &[u8] = b"zswan_mvm_"; // $$$X becomes zswan_mvm_X

/// $X and $$$X as identifiers every grammar accepts. goose-treesitter also
/// keeps a `$` that sits in a string or a comment of the pattern as text;
/// none of Spread-Wings' patterns has a string or a comment, so a pattern
/// that has one is refused here instead of being read wrongly.
fn rename_metavars(pattern: &[u8], out: &mut Vec<u8>) -> Result<(), String> {
    if pattern.iter().any(|&c| c == b'"' || c == b'\'' || c == b'`' || c == b'#') || find(pattern, b"//") >= 0 || find(pattern, b"/*") >= 0 {
        return Err("a pattern with a string or a comment is not read by this build".to_string());
    }
    let mut i = 0;
    while i < pattern.len() {
        let c = pattern[i];
        if c != b'$' { out.push(c); i += 1; continue; }
        let mut d = 0;
        while i + d < pattern.len() && pattern[i + d] == b'$' { d += 1; }
        let mut e = i + d;
        while e < pattern.len() && (pattern[e].is_ascii_uppercase() || pattern[e].is_ascii_digit() || pattern[e] == b'_') { e += 1; }
        if d == 3 {
            out.extend_from_slice(MVM);
            out.extend_from_slice(if e > i + d { &pattern[i + d..e] } else { b"_" });
        } else if d == 1 && e > i + 1 {
            out.extend_from_slice(MV);
            out.extend_from_slice(&pattern[i + 1..e]);
        } else {
            out.extend_from_slice(&pattern[i..e]);
        }
        i = e;
    }
    Ok(())
}

/// Contexts a pattern is parsed in, the first that parses: alone (a whole
/// file), as a statement inside a function, as a class member.
fn context(k: i64) -> (&'static [u8], &'static [u8]) {
    match k {
        1 => (b"fn zswan_ctx() {\n", b"\n}"),
        2 => (b"void zswan_ctx() {\n", b";\n}"),
        3 => (b"class ZSwanCtx { void zswan_ctx() {\n", b";\n} }"),
        4 => (b"class ZSwanCtx {\n", b"\n}"),
        5 => (b"<?php\n", b""),
        6 => (b"<?php\nfunction zswan_ctx() {\n", b";\n}"),
        7 => (b"func zswan_ctx():\n\t", b""),
        8 => (b"fn zswan_ctx() {\n", b";\n}"),
        9 => (b"fn zswan_ctx() {\nlet zswan_v = ", b";\n}"),
        _ => (b"", b""),
    }
}

/// A compiled pattern.
pub struct Pattern {
    text: Vec<u8>, // the pattern with metavariables renamed, in its context
    nodes: Vec<i32>,
    root: i64,
    /// The pattern's own words: a file without one of them cannot match.
    pub words: Vec<Vec<u8>>,
}

impl Pattern {
    /// Compiles a pattern for a language. Err when the language has no
    /// grammar or the pattern does not parse as code.
    pub fn compile(lang: &str, pattern: &[u8]) -> Result<Pattern, String> {
        let mut renamed: Vec<u8> = Vec::new();
        rename_metavars(trim(pattern), &mut renamed)?;
        for k in 0..10 {
            if lang == "php" && k < 5 { continue; }
            let (pre, post) = context(k);
            let mut text: Vec<u8> = Vec::new();
            text.extend_from_slice(pre);
            text.extend_from_slice(&renamed);
            text.extend_from_slice(post);
            let mut nodes: Vec<i32> = Vec::new();
            if !parse(lang, &text, &mut nodes) { return Err(format!("no tree-sitter grammar for {}", lang)); }
            let n = (nodes.len() / R) as i64;
            // An error that is only a metavariable is fine: `{ $$$B }` where
            // the grammar wants items, say. It stands for whatever is there.
            let mut bad = false;
            for i in 0..n {
                if (flags(&nodes, i) & F_ERROR) != 0 {
                    let t = trim(&text[start(&nodes, i) as usize..end(&nodes, i) as usize]);
                    if !(starts_with(t, b"zswan_mv") && is_word(t)) { bad = true; }
                }
            }
            // The outermost node that is exactly the pattern (or it and a `;`).
            let mut at: i64 = -1;
            let a = pre.len() as i64;
            let b = a + renamed.len() as i64;
            if !bad {
                for i in 0..n {
                    if at < 0 && start(&nodes, i) == a && (end(&nodes, i) == b || end(&nodes, i) == b + 1) { at = i; }
                }
            }
            if at >= 0 {
                let mut p = Pattern { text, nodes, root: -1, words: Vec::new() };
                // Down through wrappers (an expression statement): one named
                // child, and nothing else but a `;`.
                loop {
                    let w = p.wrapped(at);
                    if w < 0 { break; }
                    at = w;
                }
                p.root = at;
                // The words a file must hold to match: those of the
                // pattern's own leaves, not its comments nor its metavariables.
                for i in 0..n {
                    if first(&p.nodes, i) < 0 && (flags(&p.nodes, i) & (F_EXTRA | F_ERROR)) != F_EXTRA && start(&p.nodes, i) >= a && end(&p.nodes, i) <= b {
                        let leaf = p.text[start(&p.nodes, i) as usize..end(&p.nodes, i) as usize].to_vec();
                        let mut j = 0;
                        while j < leaf.len() {
                            let c = leaf[j];
                            if !(c.is_ascii_alphabetic() || c == b'_') { j += 1; continue; }
                            let mut e = j;
                            while e < leaf.len() && is_word(&leaf[e..e + 1]) { e += 1; }
                            if !starts_with(&leaf[j..e], b"zswan_mv") { p.words.push(leaf[j..e].to_vec()); }
                            j = e;
                        }
                    }
                }
                return Ok(p);
            }
        }
        Err(format!("the pattern does not parse as {}", lang))
    }

    fn ptext(&self, i: i64) -> &[u8] { &self.text[start(&self.nodes, i) as usize..end(&self.nodes, i) as usize] }

    /// The only named child of a wrapper (an expression statement: one named
    /// child, nothing else but a `;`), or -1.
    fn wrapped(&self, p: i64) -> i64 {
        let mut only: i64 = -1;
        let mut named = 0;
        let mut c = first(&self.nodes, p);
        while c >= 0 {
            if (flags(&self.nodes, c) & F_EXTRA) == 0 {
                if (flags(&self.nodes, c) & F_NAMED) != 0 { named += 1; only = c; }
                else if self.ptext(c) != b";" { return -1; }
            }
            c = next(&self.nodes, c);
        }
        if named == 1 { only } else { -1 }
    }

    /// 1 for $X, 3 for $$$X, 0 otherwise, with the name. A metavariable is a
    /// named leaf, an error node holding only one, or a statement wrapping
    /// one (`$$$B` alone in a block is an expression statement).
    fn meta(&self, p: i64) -> (i64, &[u8]) {
        let leaf = first(&self.nodes, p) < 0 && (flags(&self.nodes, p) & F_NAMED) != 0;
        if !leaf && (flags(&self.nodes, p) & F_ERROR) == 0 {
            let w = self.wrapped(p);
            return if w >= 0 { self.meta(w) } else { (0, b"") };
        }
        let s = trim(self.ptext(p));
        if !is_word(s) { return (0, b""); }
        if starts_with(s, MVM) { return (3, &s[MVM.len()..]); }
        if starts_with(s, MV) { return (1, &s[MV.len()..]); }
        (0, b"")
    }

    /// Whether a pattern node holds only punctuation and metavariables, one
    /// of them a $$$ run: `{ $$$B }` say. A grammar can give such a node
    /// another kind than the code it stands for, so it matches by its
    /// punctuation and metavariables alone.
    fn only_holes(&self, p: i64) -> bool {
        let mut c = solid(&self.nodes, first(&self.nodes, p));
        let mut holes = 0;
        while c >= 0 {
            let (m, _) = self.meta(c);
            if m == 3 { holes += 1; }
            else if m == 1 {}
            else if (flags(&self.nodes, c) & F_NAMED) != 0 { return false; }
            c = solid(&self.nodes, next(&self.nodes, c));
        }
        holes > 0
    }

    /// Whether src can hold a match at all: it has every word the pattern has.
    pub fn might_match(&self, src: &[u8]) -> bool {
        self.words.iter().all(|w| w.is_empty() || find(src, w) >= 0)
    }
}

/// One pattern against one parsed file.
pub struct Matcher<'a> {
    p: &'a Pattern,
    t_text: &'a [u8],
    t_nodes: &'a [i32],
    binds: Vec<(&'a [u8], i64, i64)>, // name, target nodes a..b (inclusive); a < 0: none
}

impl<'a> Matcher<'a> {
    pub fn new(p: &'a Pattern, t_text: &'a [u8], t_nodes: &'a [i32]) -> Matcher<'a> {
        Matcher { p, t_text, t_nodes, binds: Vec::new() }
    }

    fn ttext(&self, i: i64) -> &'a [u8] { &self.t_text[start(self.t_nodes, i) as usize..end(self.t_nodes, i) as usize] }

    fn span_text(&self, a: i64, b: i64) -> &'a [u8] {
        if a < 0 { return &self.t_text[0..0]; }
        &self.t_text[start(self.t_nodes, a) as usize..end(self.t_nodes, b) as usize]
    }

    fn bind(&mut self, name: &'a [u8], a: i64, b: i64) -> bool {
        if !name.is_empty() && name[0] == b'_' { return true; } // anonymous
        for k in 0..self.binds.len() {
            if self.binds[k].0 == name { return self.span_text(self.binds[k].1, self.binds[k].2) == self.span_text(a, b); }
        }
        self.binds.push((name, a, b));
        true
    }

    fn match_node(&mut self, p: i64, t: i64) -> bool {
        let pat = self.p;
        let (m, name) = pat.meta(p);
        if m == 1 { return (flags(self.t_nodes, t) & F_NAMED) != 0 && self.bind(name, t, t); } // $X is one named node
        if !(sym(&pat.nodes, p) == sym(self.t_nodes, t)
            || (first(self.t_nodes, t) >= 0 && (flags(self.t_nodes, t) & F_NAMED) != 0 && pat.only_holes(p)))
        {
            return false;
        }
        if first(&pat.nodes, p) < 0 { return pat.ptext(p) == self.ttext(t); }
        self.match_seq(solid(&pat.nodes, first(&pat.nodes, p)), solid(self.t_nodes, first(self.t_nodes, t)))
    }

    fn unnamed(&self, t: i64) -> bool { t >= 0 && (flags(self.t_nodes, t) & F_NAMED) == 0 }

    /// Pattern siblings from p against target siblings from t. As ast-grep's
    /// default does, punctuation in the target that the pattern leaves out
    /// is skipped, and once the pattern's siblings are used up the target's
    /// remaining ones are allowed.
    fn match_seq(&mut self, p: i64, t: i64) -> bool {
        if p < 0 { return true; }
        let pat = self.p;
        let mark = self.binds.len();
        let pn = solid(&pat.nodes, next(&pat.nodes, p));
        let (m, name) = pat.meta(p);
        if m == 3 {
            if self.bind(name, -1, -1) && self.match_seq(pn, t) { return true; }
            self.binds.truncate(mark);
            // An empty list capture has no following separator.
            if pn >= 0 && (flags(&pat.nodes, pn) & F_NAMED) == 0 && pat.ptext(pn) == b"," {
                if self.bind(name, -1, -1) && self.match_seq(solid(&pat.nodes, next(&pat.nodes, pn)), t) { return true; }
                self.binds.truncate(mark);
            }
            let mut last = t;
            while last >= 0 {
                if self.bind(name, t, last) && self.match_seq(pn, solid(self.t_nodes, next(self.t_nodes, last))) { return true; }
                self.binds.truncate(mark);
                last = solid(self.t_nodes, next(self.t_nodes, last));
            }
            return false;
        }
        // Likewise the separator before an empty trailing capture disappears.
        if (flags(&pat.nodes, p) & F_NAMED) == 0 && pat.ptext(p) == b"," && pn >= 0 {
            let (m2, name2) = pat.meta(pn);
            if m2 == 3 {
                if self.bind(name2, -1, -1) && self.match_seq(solid(&pat.nodes, next(&pat.nodes, pn)), t) { return true; }
                self.binds.truncate(mark);
            }
        }
        if t < 0 { return false; }
        if self.match_node(p, t) && self.match_seq(pn, solid(self.t_nodes, next(self.t_nodes, t))) { return true; }
        self.binds.truncate(mark);
        if self.unnamed(t) && self.match_seq(p, solid(self.t_nodes, next(self.t_nodes, t))) { return true; }
        self.binds.truncate(mark);
        false
    }

    /// Whether the pattern matches at node i; the bindings are then set.
    pub fn matches_at(&mut self, i: i64) -> bool {
        self.binds.clear();
        (flags(self.t_nodes, i) & F_EXTRA) == 0 && self.match_node(self.p.root, i)
    }

    /// What the metavariable `name` captured in the current match ("" for none).
    pub fn capture(&self, name: &[u8]) -> &'a [u8] {
        for b in &self.binds {
            if b.0 == name { return self.span_text(b.1, b.2); }
        }
        &self.t_text[0..0]
    }
}
