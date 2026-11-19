// Definitions read from the syntax tree, by the kind of each node.
//
// Spread-Wings found definitions with a list of shapes per language
// (`const $NAME = ($$$A) => $B`, `pub fn $NAME($$$A) -> $R { $$$B }`). A
// shape matches one spelling: a return type, a type on the constant, type
// parameters, `pub(crate)`, `const fn` or `where` each need another line in
// the list, and a class method had no shape at all. Measured against Swan's
// compiler-resolved map on 2026-11-18 (docs/measured-against-swan-2026-11-18.md):
// of the definitions that morluto/rea's own calls reach, the graph was
// missing 19,606 of 23,991: 15,980 constants holding a function (97% of a
// sample were `const f = (a: T): R => ...`), 2,570 methods, 675 properties
// with a function type and 230 functions (generators, overloads). On
// relatedb/relate it had 79% of the structs and 65% of the traits.
//
// A grammar names every kind of node, so a definition is recognised by what
// it is, however it is spelled. This reader does that for TypeScript, TSX,
// JavaScript and Rust. Python's shapes cover its definitions (100% on three
// repos) and stay as they were; imports, calls and bindings are still read
// by shape for every language.
//
// What becomes a definition:
//   function   a function declaration or generator; a method, getter or
//              setter; a `declare`d function; a method or function-typed
//              property of an interface, class or object type; a constant
//              whose value is a function, a call that is handed a function
//              (`memo(() => ...)`, `create<S>((set) => ...)`), or a call
//              whose result this file itself calls (`const run =
//              promisify(execFile); run(...)`); Rust: `fn`, with or without
//              a body
//   class, interface, enum, type, struct (and union), trait, impl
// The overloads of one TypeScript function (its signatures, then the
// implementation) are one definition, from the first signature to the end
// of the body.
//
// Not read: a key of an object literal whose value is a function (`{ k: () =>
// 1 }`; a method written in one, `{ m() {} }`, is read), namespaces, enum
// members, Rust macros and consts.

use crate::extract::{callee_name, count_newlines, record};
use crate::ts::{self, F_EXTRA, F_NAMED, R};
use crate::util::*;
use std::collections::HashSet;
use tree_sitter::Language;

// What a kind of node is to this reader. 0 is "not looked up yet".
const KD_OTHER: i64 = 1;
const KD_FUNC: i64 = 2; // a function with a body
const KD_FSIG: i64 = 3; // a function's signature alone
const KD_METHOD: i64 = 4; // a method with a body
const KD_MSIG: i64 = 5; // a method's signature alone
const KD_CLASS: i64 = 6;
const KD_IFACE: i64 = 7;
const KD_ENUM: i64 = 8;
const KD_TYPE: i64 = 9;
const KD_STRUCT: i64 = 10;
const KD_TRAIT: i64 = 11;
const KD_IMPL: i64 = 12;
const KD_VAR: i64 = 13; // one `name = value` of a const/let/var statement
const KD_FIELD: i64 = 14; // a class field
const KD_PROP: i64 = 15; // a property of an interface or object type
const KD_MOD: i64 = 16; // Rust `mod name;` / `mod name { }`
const KD_NAME: i64 = 20; // an identifier that can name a definition
const KD_FN_VALUE: i64 = 21; // an arrow function or function expression
const KD_CLASS_VALUE: i64 = 22; // a class expression
const KD_CALL: i64 = 23;
const KD_ARGS: i64 = 24;
const KD_WRAP: i64 = 25; // `(x)`, `x as T`, `x satisfies T`, `x!`
const KD_FN_TYPE: i64 = 26; // `(a: T) => R` as a type
const KD_TYPE_ANN: i64 = 27; // `: T`
const KD_EXPORT: i64 = 28; // `export ...`, `declare ...`
const KD_DECL: i64 = 29; // a const/let/var statement
const KD_BODY: i64 = 30; // a braced body or member list
const KD_DECORATOR: i64 = 31;
const KD_TYPE_PARAMS: i64 = 32;

fn kind_class(rust: bool, name: &str, named: bool) -> i64 {
    if !named { return KD_OTHER; }
    if rust {
        return match name {
            "function_item" => KD_FUNC,
            "function_signature_item" => KD_FSIG,
            "struct_item" | "union_item" => KD_STRUCT,
            "enum_item" => KD_ENUM,
            "trait_item" => KD_TRAIT,
            "type_item" => KD_TYPE,
            "impl_item" => KD_IMPL,
            "mod_item" => KD_MOD,
            "identifier" | "type_identifier" => KD_NAME,
            "type_parameters" => KD_TYPE_PARAMS,
            "block" | "declaration_list" | "field_declaration_list" | "ordered_field_declaration_list" | "enum_variant_list" => KD_BODY,
            _ => KD_OTHER,
        };
    }
    match name {
        "function_declaration" | "generator_function_declaration" => KD_FUNC,
        "function_signature" => KD_FSIG,
        "method_definition" => KD_METHOD,
        "method_signature" | "abstract_method_signature" => KD_MSIG,
        "class_declaration" | "abstract_class_declaration" => KD_CLASS,
        "interface_declaration" => KD_IFACE,
        "enum_declaration" => KD_ENUM,
        "type_alias_declaration" => KD_TYPE,
        "variable_declarator" => KD_VAR,
        "public_field_definition" | "field_definition" => KD_FIELD,
        "property_signature" => KD_PROP,
        "identifier" | "type_identifier" | "property_identifier" | "private_property_identifier" => KD_NAME,
        "arrow_function" | "function_expression" | "generator_function" | "function" => KD_FN_VALUE,
        "class" => KD_CLASS_VALUE,
        "call_expression" => KD_CALL,
        "arguments" => KD_ARGS,
        "parenthesized_expression" | "as_expression" | "satisfies_expression" | "non_null_expression" | "type_assertion" => KD_WRAP,
        "function_type" => KD_FN_TYPE,
        "type_annotation" => KD_TYPE_ANN,
        "export_statement" | "ambient_declaration" => KD_EXPORT,
        "lexical_declaration" | "variable_declaration" => KD_DECL,
        "statement_block" | "class_body" | "interface_body" | "enum_body" | "object_type" => KD_BODY,
        "decorator" => KD_DECORATOR,
        _ => KD_OTHER,
    }
}

/// Whether definitions of this language are read by kind (the rest by shape).
pub fn reads_by_kind(lang: &str) -> bool {
    lang == "typescript" || lang == "tsx" || lang == "javascript" || lang == "rust"
}

/// s on one line: runs of white space become one space, record separators
/// go, at most n bytes.
pub fn flat(s: &[u8], n: usize) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut prev_space = true;
    for &c in s {
        if out.len() >= n { break; }
        let ch = if c == b'\n' || c == b'\t' || c == b'\r' || c == 0x1e || c == 0x1f { b' ' } else { c };
        if !(ch == b' ' && prev_space) { out.push(ch); }
        prev_space = ch == b' ';
    }
    while !out.is_empty() && out[out.len() - 1] == b' ' { out.pop(); }
    out
}

struct Defs<'a> {
    rust: bool,
    language: &'a Language,
    cls: &'a mut Vec<i64>,
    text: &'a [u8],
    nodes: &'a [i32],
    par: Vec<i64>,
    prev: Vec<i64>,
    called: HashSet<&'a [u8]>,
    out: &'a mut Vec<u8>,
}

impl<'a> Defs<'a> {
    fn first(&self, i: i64) -> i64 { ts::first(self.nodes, i) }
    fn next(&self, i: i64) -> i64 { ts::next(self.nodes, i) }
    fn named(&self, i: i64) -> bool { (ts::flags(self.nodes, i) & F_NAMED) != 0 }
    fn extra(&self, i: i64) -> bool { (ts::flags(self.nodes, i) & F_EXTRA) != 0 }
    fn start(&self, i: i64) -> i64 { ts::start(self.nodes, i) }
    fn end(&self, i: i64) -> i64 { ts::end(self.nodes, i) }
    fn row(&self, i: i64) -> i64 { ts::row(self.nodes, i) }
    fn txt(&self, i: i64) -> &'a [u8] { &self.text[self.start(i) as usize..self.end(i) as usize] }

    fn class_at(&mut self, i: i64) -> i64 {
        let s = ts::sym(self.nodes, i) as usize;
        if s >= self.cls.len() { self.cls.resize(s + 1, 0); }
        if self.cls[s] == 0 {
            let name = self.language.node_kind_for_id(s as u16).unwrap_or("");
            self.cls[s] = kind_class(self.rust, name, self.named(i));
        }
        self.cls[s]
    }

    /// The first direct child of that class, or -1.
    fn child_of(&mut self, i: i64, want: i64) -> i64 {
        let mut c = self.first(i);
        while c >= 0 {
            if self.class_at(c) == want { return c; }
            c = self.next(c);
        }
        -1
    }

    /// The last child that is not a comment, or -1.
    fn last_child(&self, i: i64) -> i64 {
        let mut c = self.first(i);
        let mut last = -1;
        while c >= 0 {
            if !self.extra(c) { last = c; }
            c = self.next(c);
        }
        last
    }

    /// What stands after the `=` of a declarator or field, unwrapped from
    /// parentheses and `as`; -1 when there is no value.
    fn value_of(&mut self, i: i64) -> i64 {
        let mut c = self.first(i);
        let mut eq = false;
        let mut v = -1;
        while c >= 0 {
            if eq && !self.extra(c) { v = c; break; }
            if !self.named(c) && self.txt(c) == b"=" { eq = true; }
            c = self.next(c);
        }
        let mut hops = 0;
        while v >= 0 && self.class_at(v) == KD_WRAP && hops < 4 {
            let mut inner = self.first(v);
            while inner >= 0 && (!self.named(inner) || self.extra(inner)) { inner = self.next(inner); }
            v = inner;
            hops += 1;
        }
        v
    }

    /// Whether a call is handed a function among its arguments.
    fn takes_function(&mut self, call: i64) -> bool {
        let args = self.child_of(call, KD_ARGS);
        if args < 0 { return false; }
        self.child_of(args, KD_FN_VALUE) >= 0
    }

    /// Whether a property's or field's type is a function type.
    fn function_typed(&mut self, i: i64) -> bool {
        let ann = self.child_of(i, KD_TYPE_ANN);
        if ann < 0 { return false; }
        self.child_of(ann, KD_FN_TYPE) >= 0
    }

    /// One definition over bytes from..to, which starts on row from_row
    /// (0-based); its signature is the text up to head_end; its name is
    /// `name`, on row name_row (0-based).
    fn emit(&mut self, kind: &[u8], name: &[u8], name_row: i64, from: i64, to: i64, from_row: i64, head_end: i64) {
        // (A name a call could not spell, such as one outside ASCII, is left out.)
        if !(!name.is_empty() && callee_name(name) == name) { return; }
        let header = flat(&self.text[from as usize..from.max(head_end.min(to)) as usize], 600);
        let end_row = from_row + 1 + count_newlines(&self.text[from as usize..to as usize]);
        let mut b: Vec<u8> = Vec::new();
        push_int(&mut b, end_row);
        b.push(b' ');
        b.extend_from_slice(&header);
        record(self.out, kind, name, &b, from, to, name_row + 1);
    }

    /// Where a signature without a body stops: its first line.
    fn first_line(&self, from: i64, to: i64) -> i64 {
        let nl = find(&self.text[from as usize..to as usize], b"\n");
        if nl >= 0 { from + nl } else { to }
    }

    /// A node with a name child and maybe a body: the whole node.
    fn plain(&mut self, kind: &[u8], i: i64) {
        let nm = self.child_of(i, KD_NAME);
        if nm < 0 { return; }
        let from = self.start(i);
        let to = self.end(i);
        let body = self.child_of(i, KD_BODY);
        let head_end = if body >= 0 { self.start(body) } else { self.first_line(from, to) };
        self.emit(kind, self.txt(nm), self.row(nm), from, to, self.row(i), head_end);
    }

    fn fn_like(c: i64) -> bool { c == KD_FUNC || c == KD_FSIG || c == KD_METHOD || c == KD_MSIG }

    fn statement_of(&mut self, i: i64) -> i64 {
        let mut u = i;
        while self.par[u as usize] >= 0 && self.class_at(self.par[u as usize]) == KD_EXPORT { u = self.par[u as usize]; }
        u
    }

    fn held(&mut self, u: i64) -> i64 {
        let mut k = u;
        let mut hops = 0;
        while k >= 0 && self.class_at(k) == KD_EXPORT && hops < 3 {
            let mut c = self.first(k);
            let mut found = -1;
            while c >= 0 {
                let cc = self.class_at(c);
                if cc == KD_EXPORT || Self::fn_like(cc) { found = c; break; }
                c = self.next(c);
            }
            k = found;
            hops += 1;
        }
        k
    }

    fn before(&mut self, u: i64) -> i64 {
        let mut p = self.prev[u as usize];
        while p >= 0 && (self.extra(p) || !self.named(p) || self.class_at(p) == KD_DECORATOR) { p = self.prev[p as usize]; }
        p
    }

    fn after(&mut self, u: i64) -> i64 {
        let mut p = self.next(u);
        while p >= 0 && (self.extra(p) || !self.named(p) || self.class_at(p) == KD_DECORATOR) { p = self.next(p); }
        p
    }

    fn called_as(&mut self, d: i64, name: &[u8]) -> bool {
        if !(d >= 0 && Self::fn_like(self.class_at(d))) { return false; }
        let nm = self.child_of(d, KD_NAME);
        nm >= 0 && self.txt(nm) == name
    }

    fn function(&mut self, i: i64) {
        let nm = self.child_of(i, KD_NAME);
        if nm < 0 { return; }
        let name = self.txt(nm);
        let c = self.class_at(i);
        let sig = c == KD_FSIG || c == KD_MSIG;
        let from = self.start(i);
        let mut to = self.end(i);
        let mut imp = if sig { -1 } else { i };
        if !self.rust {
            let u = self.statement_of(i);
            let b = self.before(u);
            let p = self.held(b);
            // Inside a run that its first signature already covered.
            if p >= 0 && (self.class_at(p) == KD_FSIG || self.class_at(p) == KD_MSIG) && self.called_as(p, name) { return; }
            if sig {
                let mut q = self.after(u);
                while q >= 0 {
                    let d = self.held(q);
                    if !self.called_as(d, name) { break; }
                    to = self.end(d);
                    if self.class_at(d) == KD_FUNC || self.class_at(d) == KD_METHOD { imp = d; break; }
                    q = self.after(q);
                }
            }
        }
        // The signature: a declaration's text up to its body; the first
        // signature of a run, whole.
        let body = if imp == i { self.child_of(i, KD_BODY) } else { -1 };
        let head_end = if body >= 0 { self.start(body) } else { self.end(i) };
        self.emit(b"function", name, self.row(nm), from, to, self.row(i), head_end);
    }

    fn run(&mut self) {
        let n = (self.nodes.len() / R) as i64;
        // Each node's parent and the sibling before it; and the names this
        // file calls bare (`run(...)`), for constants that hold the result
        // of a call.
        for i in 0..n {
            let mut c = self.first(i);
            let mut last = -1;
            while c >= 0 {
                self.par[c as usize] = i;
                self.prev[c as usize] = last;
                last = c;
                c = self.next(c);
            }
            if !self.rust && self.class_at(i) == KD_CALL {
                let f = self.first(i);
                if f >= 0 && self.class_at(f) == KD_NAME { self.called.insert(self.txt(f)); }
            }
        }
        for i in 0..n {
            if !self.named(i) { continue; }
            let c = self.class_at(i);
            if c == KD_OTHER || c == KD_NAME { continue; }
            if Self::fn_like(c) { self.function(i); }
            else if c == KD_CLASS { self.plain(b"class", i); }
            else if c == KD_IFACE { self.plain(b"interface", i); }
            else if c == KD_ENUM { self.plain(b"enum", i); }
            else if c == KD_TYPE { self.plain(b"type", i); }
            else if c == KD_STRUCT { self.plain(b"struct", i); }
            else if c == KD_TRAIT { self.plain(b"trait", i); }
            else if c == KD_IMPL {
                // `impl<T> Trait for Type<T>`: the type after `for`, else the
                // first type; named by its last path segment, as a call names it.
                let mut ty = -1;
                let mut k = self.first(i);
                while k >= 0 {
                    if !self.named(k) { if self.txt(k) == b"for" { ty = -1; } }
                    else if !self.extra(k) && self.class_at(k) != KD_TYPE_PARAMS && self.class_at(k) != KD_BODY && ty < 0 { ty = k; }
                    k = self.next(k);
                }
                if ty >= 0 {
                    let body = self.child_of(i, KD_BODY);
                    let from = self.start(i);
                    let to = self.end(i);
                    let he = if body >= 0 { self.start(body) } else { self.first_line(from, to) };
                    self.emit(b"impl", callee_name(self.txt(ty)), self.row(ty), from, to, self.row(i), he);
                }
            }
            else if c == KD_MOD {
                // `mod name;` is the file name.rs (or name/mod.rs) beside this one.
                let nm = self.child_of(i, KD_NAME);
                if nm >= 0 && self.child_of(i, KD_BODY) < 0 {
                    let mut m: Vec<u8> = b"mod::".to_vec();
                    m.extend_from_slice(self.txt(nm));
                    record(self.out, b"import", &m, b"", self.start(i), self.end(i), self.row(i) + 1);
                }
            }
            else if c == KD_VAR {
                let mut nm = self.first(i);
                while nm >= 0 && self.extra(nm) { nm = self.next(nm); }
                if !(nm >= 0 && self.class_at(nm) == KD_NAME) { continue; }
                let v = self.value_of(i);
                if v < 0 { continue; }
                let vc = self.class_at(v);
                let name = self.txt(nm);
                let mut kind: &[u8] = b"";
                if vc == KD_FN_VALUE { kind = b"function"; }
                else if vc == KD_CLASS_VALUE { kind = b"class"; }
                else if vc == KD_CALL && (self.takes_function(v) || self.called.contains(name)) { kind = b"function"; }
                if kind.is_empty() { continue; }
                // The statement, when this is its first name; else the name's own part.
                let p = self.par[i as usize];
                let whole = p >= 0 && self.class_at(p) == KD_DECL && self.child_of(p, KD_VAR) == i;
                let span = if whole { p } else { i };
                let from = self.start(span);
                let to = self.end(span);
                // A function's signature runs up to its body; a class's to its
                // members; a call's to its arguments (they are not parameters).
                let mut head_end = self.first_line(from, to);
                if vc == KD_CALL {
                    let args = self.child_of(v, KD_ARGS);
                    if args >= 0 { head_end = head_end.min(self.start(args)); }
                } else if vc == KD_FN_VALUE {
                    let body = self.last_child(v);
                    if body >= 0 { head_end = self.start(body); }
                } else if vc == KD_CLASS_VALUE {
                    let body = self.child_of(v, KD_BODY);
                    if body >= 0 { head_end = self.start(body); }
                }
                self.emit(kind, name, self.row(nm), from, to, self.row(span), head_end);
            }
            else if c == KD_FIELD || c == KD_PROP {
                let nm = self.child_of(i, KD_NAME);
                if nm < 0 { continue; }
                let from = self.start(i);
                let to = self.end(i);
                let v = if c == KD_FIELD { self.value_of(i) } else { -1 };
                if v >= 0 && self.class_at(v) == KD_FN_VALUE {
                    let body = self.last_child(v);
                    let he = if body >= 0 { self.start(body) } else { to };
                    self.emit(b"function", self.txt(nm), self.row(nm), from, to, self.row(i), he);
                } else if self.function_typed(i) {
                    self.emit(b"function", self.txt(nm), self.row(nm), from, to, self.row(i), to);
                }
            }
        }
    }
}

/// Writes the definitions of a parsed file (nodes over text) to `out` as
/// extract's records. `cls` is what was learned of this language's kinds so
/// far: symbol -> KD_*, filled as symbols are met.
pub fn tree_definitions(lang: &str, language: &Language, cls: &mut Vec<i64>, text: &[u8], nodes: &[i32], out: &mut Vec<u8>) {
    let n = nodes.len() / R;
    if n == 0 { return; }
    let mut d = Defs {
        rust: lang == "rust", language, cls, text, nodes,
        par: vec![-1; n], prev: vec![-1; n], called: HashSet::new(), out,
    };
    d.run();
}
