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

import std;
import dictionary;
import treesitter;

// A symbol's name in its grammar ("method_definition"); the tree must be of
// that language. From goose-treesitter's ts_shim.c.
extern fn swan_ts_kind(h: i64, sym: i64, buf: u8[:]) -> i64;

// What a kind of node is to this reader. 0 is "not looked up yet".
let KD_OTHER = 1;
let KD_FUNC = 2;          // a function with a body
let KD_FSIG = 3;          // a function's signature alone
let KD_METHOD = 4;        // a method with a body
let KD_MSIG = 5;          // a method's signature alone
let KD_CLASS = 6;
let KD_IFACE = 7;
let KD_ENUM = 8;
let KD_TYPE = 9;
let KD_STRUCT = 10;
let KD_TRAIT = 11;
let KD_IMPL = 12;
let KD_VAR = 13;          // one `name = value` of a const/let/var statement
let KD_FIELD = 14;        // a class field
let KD_PROP = 15;         // a property of an interface or object type
let KD_MOD = 16;          // Rust `mod name;` / `mod name { }`
let KD_NAME = 20;         // an identifier that can name a definition
let KD_FN_VALUE = 21;     // an arrow function or function expression
let KD_CLASS_VALUE = 22;  // a class expression
let KD_CALL = 23;
let KD_ARGS = 24;
let KD_WRAP = 25;         // `(x)`, `x as T`, `x satisfies T`, `x!`
let KD_FN_TYPE = 26;      // `(a: T) => R` as a type
let KD_TYPE_ANN = 27;     // `: T`
let KD_EXPORT = 28;       // `export ...`, `declare ...`
let KD_DECL = 29;         // a const/let/var statement
let KD_BODY = 30;         // a braced body or member list
let KD_DECORATOR = 31;
let KD_TYPE_PARAMS = 32;

fn kind_class(rust: bool, name: const u8[:], named: bool) -> i64 {
    guard named else { return KD_OTHER; }
    if rust {
        if name == "function_item" { return KD_FUNC; }
        if name == "function_signature_item" { return KD_FSIG; }
        if name == "struct_item" || name == "union_item" { return KD_STRUCT; }
        if name == "enum_item" { return KD_ENUM; }
        if name == "trait_item" { return KD_TRAIT; }
        if name == "type_item" { return KD_TYPE; }
        if name == "impl_item" { return KD_IMPL; }
        if name == "mod_item" { return KD_MOD; }
        if name == "identifier" || name == "type_identifier" { return KD_NAME; }
        if name == "type_parameters" { return KD_TYPE_PARAMS; }
        if name == "block" || name == "declaration_list" || name == "field_declaration_list" ||
           name == "ordered_field_declaration_list" || name == "enum_variant_list" { return KD_BODY; }
        return KD_OTHER;
    }
    if name == "function_declaration" || name == "generator_function_declaration" { return KD_FUNC; }
    if name == "function_signature" { return KD_FSIG; }
    if name == "method_definition" { return KD_METHOD; }
    if name == "method_signature" || name == "abstract_method_signature" { return KD_MSIG; }
    if name == "class_declaration" || name == "abstract_class_declaration" { return KD_CLASS; }
    if name == "interface_declaration" { return KD_IFACE; }
    if name == "enum_declaration" { return KD_ENUM; }
    if name == "type_alias_declaration" { return KD_TYPE; }
    if name == "variable_declarator" { return KD_VAR; }
    if name == "public_field_definition" || name == "field_definition" { return KD_FIELD; }
    if name == "property_signature" { return KD_PROP; }
    if name == "identifier" || name == "type_identifier" || name == "property_identifier" ||
       name == "private_property_identifier" { return KD_NAME; }
    if name == "arrow_function" || name == "function_expression" || name == "generator_function" ||
       name == "function" { return KD_FN_VALUE; }
    if name == "class" { return KD_CLASS_VALUE; }
    if name == "call_expression" { return KD_CALL; }
    if name == "arguments" { return KD_ARGS; }
    if name == "parenthesized_expression" || name == "as_expression" || name == "satisfies_expression" ||
       name == "non_null_expression" || name == "type_assertion" { return KD_WRAP; }
    if name == "function_type" { return KD_FN_TYPE; }
    if name == "type_annotation" { return KD_TYPE_ANN; }
    if name == "export_statement" || name == "ambient_declaration" { return KD_EXPORT; }
    if name == "lexical_declaration" || name == "variable_declaration" { return KD_DECL; }
    if name == "statement_block" || name == "class_body" || name == "interface_body" || name == "enum_body" ||
       name == "object_type" { return KD_BODY; }
    if name == "decorator" { return KD_DECORATOR; }
    return KD_OTHER;
}

// Whether definitions of this language are read by kind (the rest by shape).
fn reads_by_kind(lang: const u8[:]) -> bool {
    return lang == "typescript" || lang == "tsx" || lang == "javascript" || lang == "rust";
}

// s on one line: runs of white space become one space, record separators
// go, at most n bytes.
fn flat(s: const u8[:], n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    var prev_space = true;
    for c in s {
        if out.len >= n { break; }
        let ch = if c == '\n' || c == '\t' || c == '\r' || c == 0x1e || c == 0x1f { ' ' } else { c };
        if !(ch == ' ' && prev_space) { out.push(ch); }
        prev_space = ch == ' ';
    }
    while out.len > 0 && out[out.len - 1] == ' ' { out.pop(); }
    return out;
}

// Writes the definitions of the tree the worker has loaded (treesitter's
// t_nodes over t_text) to `out` as extract's records. `h` is any tree of
// this language (it gives the kinds their names) and `cls` what was learned
// from it so far: symbol -> KD_*, filled as symbols are met.
fn tree_definitions(lang: const u8[:], h: i64, cls: i64[>..]&, out: u8[>..]&) {
    let n = treesitter::t_nodes.len / treesitter::R;
    guard n > 0 else { return; }
    let rust = lang == "rust";
    var kb: u8[>..] = [];
    kb.resize(96, 0);
    fn first(i: i64) -> i64 { return treesitter::first(treesitter::t_nodes, i); }
    fn next(i: i64) -> i64 { return treesitter::next(treesitter::t_nodes, i); }
    fn named(i: i64) -> bool { return (treesitter::flags(treesitter::t_nodes, i) & treesitter::F_NAMED) != 0; }
    fn extra(i: i64) -> bool { return (treesitter::flags(treesitter::t_nodes, i) & treesitter::F_EXTRA) != 0; }
    fn class_at(i: i64) -> i64 {
        let s = treesitter::sym(treesitter::t_nodes, i);
        if s >= cls.len { cls.resize(s + 1, 0); }
        if cls[s] == 0 {
            let k = swan_ts_kind(h, s, kb[..]);
            cls[s] = kind_class(rust, kb[..k], named(i));
        }
        return cls[s];
    }

    // Each node's parent and the sibling before it.
    var par: i64[>..] = [];
    var prev: i64[>..] = [];
    par.resize(n, -1);
    prev.resize(n, -1);
    // The names this file calls bare (`run(...)`), for constants that hold
    // the result of a call.
    var called = dictionary<u64, bool> {};
    for i in 0..n {
        var c = first(i);
        var last = -1;
        while c >= 0 { par[c] = i; prev[c] = last; last = c; c = next(c); }
        if !rust && class_at(i) == KD_CALL {
            let f = first(i);
            if f >= 0 && class_at(f) == KD_NAME { called.insert(hash(treesitter::match_text(f)), true); }
        }
    }

    // The first direct child of that class, or -1.
    fn child_of(i: i64, want: i64) -> i64 {
        var c = first(i);
        while c >= 0 {
            if class_at(c) == want { return c; }
            c = next(c);
        }
        return -1;
    }
    // The last child that is not a comment, or -1.
    fn last_child(i: i64) -> i64 {
        var c = first(i);
        var last = -1;
        while c >= 0 {
            if !extra(c) { last = c; }
            c = next(c);
        }
        return last;
    }
    // What stands after the `=` of a declarator or field, unwrapped from
    // parentheses and `as`; -1 when there is no value.
    fn value_of(i: i64) -> i64 {
        var c = first(i);
        var eq = false;
        var v = -1;
        while c >= 0 {
            if eq && !extra(c) { v = c; break; }
            if !named(c) && treesitter::match_text(c) == "=" { eq = true; }
            c = next(c);
        }
        var hops = 0;
        while v >= 0 && class_at(v) == KD_WRAP && hops < 4 {
            var inner = first(v);
            while inner >= 0 && (!named(inner) || extra(inner)) { inner = next(inner); }
            v = inner;
            hops++;
        }
        return v;
    }
    // Whether a call is handed a function among its arguments.
    fn takes_function(call: i64) -> bool {
        let args = child_of(call, KD_ARGS);
        guard args >= 0 else { return false; }
        return child_of(args, KD_FN_VALUE) >= 0;
    }
    // Whether a property's or field's type is a function type.
    fn function_typed(i: i64) -> bool {
        let ann = child_of(i, KD_TYPE_ANN);
        guard ann >= 0 else { return false; }
        return child_of(ann, KD_FN_TYPE) >= 0;
    }

    // One definition over bytes from..to, which starts on row from_row
    // (0-based); its signature is the text up to head_end; its name is
    // `name`, on row name_row (0-based).
    fn emit(kind: const u8[:], name: const u8[:], name_row: i64, from: i64, to: i64, from_row: i64, head_end: i64) {
        // (A name a call could not spell, such as one outside ASCII, is left out.)
        guard name.len > 0 && callee_name(name) == name else { return; }
        let header = flat(treesitter::t_text[from..max(from, min(head_end, to))], 600);
        let end_row = from_row + 1 + count_newlines(treesitter::t_text[from..to]);
        record(out, kind, name, str(end_row, " ", header), from, to, name_row + 1);
    }
    // Where a signature without a body stops: its first line.
    fn first_line(from: i64, to: i64) -> i64 {
        let nl = find(treesitter::t_text[from..to], "\n");
        return if nl >= 0 { from + nl } else { to };
    }
    // A node with a name child and maybe a body: the whole node.
    fn plain(kind: const u8[:], i: i64) {
        let nm = child_of(i, KD_NAME);
        guard nm >= 0 else { return; }
        let from = treesitter::match_start(i);
        let to = treesitter::match_end(i);
        let body = child_of(i, KD_BODY);
        let head_end = if body >= 0 { treesitter::match_start(body) } else { first_line(from, to) };
        emit(kind, treesitter::match_text(nm), treesitter::match_row(nm), from, to, treesitter::match_row(i), head_end);
    }

    // Overloads. A statement is a declaration or the `export`/`declare`
    // around it; a run is the same-named signatures in a row and the
    // implementation after them.
    fn fn_like(c: i64) -> bool { return c == KD_FUNC || c == KD_FSIG || c == KD_METHOD || c == KD_MSIG; }
    fn statement_of(i: i64) -> i64 {
        var u = i;
        while par[u] >= 0 && class_at(par[u]) == KD_EXPORT { u = par[u]; }
        return u;
    }
    fn held(u: i64) -> i64 {
        var k = u;
        var hops = 0;
        while k >= 0 && class_at(k) == KD_EXPORT && hops < 3 {
            var c = first(k);
            var found = -1;
            while c >= 0 {
                let cc = class_at(c);
                if cc == KD_EXPORT || fn_like(cc) { found = c; break; }
                c = next(c);
            }
            k = found;
            hops++;
        }
        return k;
    }
    fn before(u: i64) -> i64 {
        var p = prev[u];
        while p >= 0 && (extra(p) || !named(p) || class_at(p) == KD_DECORATOR) { p = prev[p]; }
        return p;
    }
    fn after(u: i64) -> i64 {
        var p = next(u);
        while p >= 0 && (extra(p) || !named(p) || class_at(p) == KD_DECORATOR) { p = next(p); }
        return p;
    }
    fn called_as(d: i64, name: const u8[:]) -> bool {
        guard d >= 0 && fn_like(class_at(d)) else { return false; }
        let nm = child_of(d, KD_NAME);
        return nm >= 0 && treesitter::match_text(nm) == name;
    }
    fn function(i: i64) {
        let nm = child_of(i, KD_NAME);
        guard nm >= 0 else { return; }
        let name = treesitter::match_text(nm);
        let c = class_at(i);
        let sig = c == KD_FSIG || c == KD_MSIG;
        let from = treesitter::match_start(i);
        var to = treesitter::match_end(i);
        var impl = if sig { -1 } else { i };
        if !rust {
            let u = statement_of(i);
            let p = held(before(u));
            // Inside a run that its first signature already covered.
            if p >= 0 && (class_at(p) == KD_FSIG || class_at(p) == KD_MSIG) && called_as(p, name) { return; }
            if sig {
                var q = after(u);
                while q >= 0 {
                    let d = held(q);
                    guard called_as(d, name) else { break; }
                    to = treesitter::match_end(d);
                    if class_at(d) == KD_FUNC || class_at(d) == KD_METHOD { impl = d; break; }
                    q = after(q);
                }
            }
        }
        // The signature: a declaration's text up to its body; the first
        // signature of a run, whole.
        let body = if impl == i { child_of(i, KD_BODY) } else { -1 };
        let head_end = if body >= 0 { treesitter::match_start(body) } else { treesitter::match_end(i) };
        emit("function", name, treesitter::match_row(nm), from, to, treesitter::match_row(i), head_end);
    }

    for i in 0..n {
        guard named(i) else { continue; }
        let c = class_at(i);
        if c == KD_OTHER || c == KD_NAME { continue; }
        if fn_like(c) { function(i); }
        else if c == KD_CLASS { plain("class", i); }
        else if c == KD_IFACE { plain("interface", i); }
        else if c == KD_ENUM { plain("enum", i); }
        else if c == KD_TYPE { plain("type", i); }
        else if c == KD_STRUCT { plain("struct", i); }
        else if c == KD_TRAIT { plain("trait", i); }
        else if c == KD_IMPL {
            // `impl<T> Trait for Type<T>`: the type after `for`, else the
            // first type; named by its last path segment, as a call names it.
            var ty = -1;
            var after_for = false;
            var k = first(i);
            while k >= 0 {
                if !named(k) { if treesitter::match_text(k) == "for" { after_for = true; ty = -1; } }
                else if !extra(k) && class_at(k) != KD_TYPE_PARAMS && class_at(k) != KD_BODY && ty < 0 { ty = k; }
                k = next(k);
            }
            if ty >= 0 {
                let body = child_of(i, KD_BODY);
                let from = treesitter::match_start(i);
                let to = treesitter::match_end(i);
                emit("impl", callee_name(treesitter::match_text(ty)), treesitter::match_row(ty), from, to, treesitter::match_row(i),
                     if body >= 0 { treesitter::match_start(body) } else { first_line(from, to) });
            }
        }
        else if c == KD_MOD {
            // `mod name;` is the file name.rs (or name/mod.rs) beside this one.
            let nm = child_of(i, KD_NAME);
            if nm >= 0 && child_of(i, KD_BODY) < 0 {
                record(out, "import", str("mod::", treesitter::match_text(nm)), "", treesitter::match_start(i), treesitter::match_end(i),
                       treesitter::match_row(i) + 1);
            }
        }
        else if c == KD_VAR {
            var nm = first(i);
            while nm >= 0 && extra(nm) { nm = next(nm); }
            guard nm >= 0 && class_at(nm) == KD_NAME else { continue; }
            let v = value_of(i);
            guard v >= 0 else { continue; }
            let vc = class_at(v);
            let name = treesitter::match_text(nm);
            var kind: const u8[:] = "";
            if vc == KD_FN_VALUE { kind = "function"; }
            else if vc == KD_CLASS_VALUE { kind = "class"; }
            else if vc == KD_CALL && (takes_function(v) || called.contains(hash(name))) { kind = "function"; }
            guard kind.len > 0 else { continue; }
            // The statement, when this is its first name; else the name's own part.
            let p = par[i];
            let whole = p >= 0 && class_at(p) == KD_DECL && child_of(p, KD_VAR) == i;
            let span = if whole { p } else { i };
            let from = treesitter::match_start(span);
            let to = treesitter::match_end(span);
            // A function's signature runs up to its body; a class's to its
            // members; a call's to its arguments (they are not parameters).
            var head_end = first_line(from, to);
            if vc == KD_CALL {
                let args = child_of(v, KD_ARGS);
                if args >= 0 { head_end = min(head_end, treesitter::match_start(args)); }
            } else if vc == KD_FN_VALUE {
                let body = last_child(v);
                if body >= 0 { head_end = treesitter::match_start(body); }
            } else if vc == KD_CLASS_VALUE {
                let body = child_of(v, KD_BODY);
                if body >= 0 { head_end = treesitter::match_start(body); }
            }
            emit(kind, name, treesitter::match_row(nm), from, to, treesitter::match_row(span), head_end);
        }
        else if c == KD_FIELD || c == KD_PROP {
            let nm = child_of(i, KD_NAME);
            guard nm >= 0 else { continue; }
            let from = treesitter::match_start(i);
            let to = treesitter::match_end(i);
            let v = if c == KD_FIELD { value_of(i) } else { -1 };
            if v >= 0 && class_at(v) == KD_FN_VALUE {
                let body = last_child(v);
                emit("function", treesitter::match_text(nm), treesitter::match_row(nm), from, to, treesitter::match_row(i),
                     if body >= 0 { treesitter::match_start(body) } else { to });
            } else if function_typed(i) {
                emit("function", treesitter::match_text(nm), treesitter::match_row(nm), from, to, treesitter::match_row(i), to);
            }
        }
    }
}
