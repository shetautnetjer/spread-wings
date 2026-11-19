// Facts from source, by syntax tree, never by running anything: definitions,
// imports and call sites, found with ast-grep style patterns (ts.rs) on
// every core. A pattern matches one shape of code, so each language has a
// few variants (`fn` and `pub fn`, a return type or not).

use crate::db::{Db, Stmt};
use crate::sql;
use crate::store::open_marks;
use crate::sys;
use crate::treedefs::{reads_by_kind, tree_definitions};
use crate::ts::{self, Matcher, Pattern};
use crate::util::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// The folders a walk never enters: dependencies, caches, build output.
pub const SKIP_DIRS: [&str; 16] = [
    "node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox", ".mypy_cache", ".pytest_cache", "dist",
    "build", ".gradle", "obj", ".next", ".spread-wings", ".swan",
];

/// The languages read.
pub fn supported(lang: &str) -> bool {
    lang == "python" || lang == "typescript" || lang == "tsx" || lang == "javascript" || lang == "rust" || lang == "goose"
}

/// "kind<TAB>capture<TAB>pattern" per line. kind "import" captures the
/// module, "call" the callee, anything else names a definition. (The lists
/// are in sql.rs.)
fn patterns(lang: &str) -> &'static str {
    if lang == "python" { return sql::PATTERNS_PYTHON; }
    if lang == "rust" { return sql::PATTERNS_RUST; }
    sql::PATTERNS_JS
}

struct Compiled { kind: Vec<u8>, capture: Vec<u8>, pattern: Pattern }

fn compiled(lang: &str) -> &'static Vec<Compiled> {
    static ALL: OnceLock<Mutex<HashMap<String, &'static Vec<Compiled>>>> = OnceLock::new();
    let mut all = ALL.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap();
    if let Some(v) = all.get(lang) { return v; }
    let mut list: Vec<Compiled> = Vec::new();
    for line in patterns(lang).as_bytes().split(|&c| c == b'\n') {
        let f = split(line, b'\t');
        if f.len() == 3 {
            if let Ok(p) = Pattern::compile(lang, f[2]) {
                list.push(Compiled { kind: f[0].to_vec(), capture: f[1].to_vec(), pattern: p });
            }
        }
    }
    let leaked: &'static Vec<Compiled> = Box::leak(Box::new(list));
    all.insert(lang.to_string(), leaked);
    leaked
}

pub fn ident_char(c: u8) -> bool { c.is_ascii_alphanumeric() || c == b'_' || c == b'$' }

/// The name a call reaches: the last identifier of `a.b.c`, `a::b`, `x?.y`,
/// dropping generic arguments. "" when the callee isn't a plain name path.
pub fn callee_name(f: &[u8]) -> &[u8] {
    let mut end = f.len();
    if end > 0 && f[end - 1] == b'>' {
        let lt = find(f, b"<");
        if lt > 0 { end = lt as usize; }
    }
    if end >= 2 && f[end - 2] == b':' && f[end - 1] == b':' { end -= 2; } // `f::<T>`
    let mut i = end;
    while i > 0 && ident_char(f[i - 1]) { i -= 1; }
    if !(i < end) { return b""; }
    let c = f[i];
    if c.is_ascii_digit() { return b""; }
    // A JavaScript private name keeps its `#`.
    if i > 0 && f[i - 1] == b'#' && (i == 1 || f[i - 2] == b'.') { i -= 1; }
    &f[i..end]
}

/// The name right before a call's own name: `Pair` of `Pair::<T>::new`,
/// `this` of `this.push`. "" when the call is bare, or what stands there is
/// no plain name.
pub fn qualifier_of(f: &[u8]) -> &[u8] {
    let mut end = f.len();
    if end > 0 && f[end - 1] == b'>' {
        let lt = find(f, b"<");
        if lt > 0 { end = lt as usize; }
    }
    if end >= 2 && f[end - 2] == b':' && f[end - 1] == b':' { end -= 2; }
    let mut q = end;
    while q > 0 && ident_char(f[q - 1]) { q -= 1; }
    if q > 0 && f[q - 1] == b'#' { q -= 1; }
    if q >= 2 && f[q - 1] == b':' && f[q - 2] == b':' { q -= 2; }
    else if q >= 2 && f[q - 1] == b'.' && f[q - 2] == b'?' { q -= 2; }
    else if q >= 1 && f[q - 1] == b'.' { q -= 1; }
    else { return b""; }
    // The qualifier's own generic arguments: `Pair::<T>`, `Pair<T>`.
    if q > 0 && f[q - 1] == b'>' {
        let mut depth = 0;
        let mut k = q;
        while k > 0 {
            k -= 1;
            if f[k] == b'>' { depth += 1; }
            else if f[k] == b'<' {
                depth -= 1;
                if depth == 0 { break; }
            }
        }
        q = k;
        if q >= 2 && f[q - 1] == b':' && f[q - 2] == b':' { q -= 2; }
    }
    let mut s = q;
    while s > 0 && ident_char(f[s - 1]) { s -= 1; }
    if !(s < q) { return b""; }
    &f[s..q]
}

/// The module an import names, quotes and braces trimmed.
fn module_name(m: &[u8]) -> &[u8] {
    let mut s = trim(m);
    if s.len() >= 2 && (s[0] == b'"' || s[0] == b'\'' || s[0] == b'`') { s = &s[1..s.len() - 1]; }
    let brace = find(s, b"::{");
    if brace > 0 { s = &s[..brace as usize]; }
    s
}

/// The walk: every supported file below repo, as absolute paths and their
/// languages, in the order index has always met them (a folder's own files
/// by name, then the folders found, in the order found). `dirs` comes back
/// holding every folder walked, the repo first.
pub fn walk_repo(repo: &[u8], paths: &mut Vec<Vec<u8>>, langs: &mut Vec<&'static str>, dirs: &mut Vec<Vec<u8>>) -> i64 {
    let mut count: i64 = 0;
    dirs.push(repo.to_vec());
    let mut next = 0;
    while next < dirs.len() && count < 200000 {
        let dir = dirs[next].clone();
        next += 1;
        let names = match sys::list_dir(&dir) { Some(n) => n, None => continue };
        for name in names {
            if name.is_empty() { continue; }
            let mut full = dir.clone();
            full.push(b'/');
            full.extend_from_slice(&name);
            if sys::is_dir(&full) {
                // Hidden folders (.git, .tools, .github, .cache) hold tooling, not the code.
                if name[0] != b'.' && !SKIP_DIRS.iter().any(|d| d.as_bytes() == &name[..]) && !sys::is_symlink(&full) { dirs.push(full); }
            } else {
                // Goose has no tree-sitter grammar: goose_scan reads it by line.
                let lang = if ends_with(&full, b".goose") { "goose" } else { ts::language_of_path(&full) };
                if supported(lang) && !sys::is_symlink(&full) {
                    paths.push(full);
                    langs.push(lang);
                    count += 1;
                }
            }
        }
    }
    count
}

/// A file's row. `rel` is its path below the repo.
pub fn insert_file(db: &Db, ins_file: &Stmt, rel: &[u8], lang: &str) -> i64 {
    let slash = rfind(rel, b"/");
    ins_file.reset();
    ins_file.bind_text(1, rel);
    ins_file.bind_text(2, lang.as_bytes());
    ins_file.bind_text(3, if slash >= 0 { &rel[..slash as usize] } else { b"." });
    ins_file.step_done();
    db.last_rowid()
}

/// Size and times of the first n files, taken before any of them is read.
pub fn stat_files(all_paths: &[Vec<u8>], n: usize, sizes: &mut Vec<i64>, mtimes: &mut Vec<i64>, ctimes: &mut Vec<i64>) {
    for p in all_paths.iter().take(n) {
        sizes.push(sys::file_size(p));
        mtimes.push(sys::mtime_ns(p));
        ctimes.push(sys::ctime_ns(p));
    }
}

/// A file's stamp, for `update` to compare with next time. A file written
/// within three seconds of the run keeps no times: the next update reads it
/// and goes by its hash.
pub fn put_stamp(st: &Stmt, fid: i64, ord: i64, size: i64, mtime: i64, ctime: i64, hash: i64, now: i64) {
    let settled = mtime > 0 && ctime > 0 && mtime.max(ctime) < now - 3_000_000_000;
    st.reset();
    st.bind_int(1, fid);
    st.bind_int(2, ord);
    st.bind_int(3, size);
    st.bind_int(4, if settled { mtime } else { 0 });
    st.bind_int(5, if settled { ctime } else { 0 });
    st.bind_int(6, hash);
    st.step_done();
}

/// What parse_files gives for each file: its records, the hash of its
/// content, and whether it was left unread because the hash was the known one.
#[derive(Default, Clone)]
pub struct Parsed { pub data: Vec<u8>, pub hash: i64, pub same: bool }

/// Parses the files numbered in `which` (numbers into all_paths), on every
/// hardware thread. Where old[i] is Some(hash) and the content still has
/// that hash, the file is not parsed and `same` is set. The result has one
/// entry for each of the n files.
pub fn parse_files(all_paths: &[Vec<u8>], all_langs: &[&'static str], n: usize, which: &[usize], old: &[Option<i64>]) -> Vec<Parsed> {
    let mut out: Vec<Parsed> = vec![Parsed::default(); n];
    if which.is_empty() { return out; }
    let workers = sys::hardware_threads().min(which.len()).max(1);
    let next = AtomicUsize::new(0);
    let done: Mutex<Vec<(usize, Parsed)>> = Mutex::new(Vec::with_capacity(which.len()));
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| {
                let mut kinds: HashMap<&'static str, Vec<i64>> = HashMap::new();
                let mut nodes: Vec<i32> = Vec::new();
                loop {
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    if k >= which.len() { break; }
                    let i = which[k];
                    let known = if i < old.len() { old[i] } else { None };
                    let p = extract_file(&all_paths[i], all_langs[i], known, &mut kinds, &mut nodes);
                    done.lock().unwrap().push((i, p));
                }
            });
        }
    });
    for (i, p) in done.into_inner().unwrap() { out[i] = p; }
    out
}

/// Writes the records of the files numbered in `which`, in that order, so
/// the graph is the same every run. pids[i] is file i's row.
pub fn write_facts(db: &Db, pids: &[i64], all_langs: &[&'static str], which: &[usize], parsed: &[Parsed]) {
    let ins_sym = db.prepare_or_die(b"INSERT INTO symbols (file_id, name, kind, row, start, end_, end_row, sig, params) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)");
    let ins_imp = db.prepare_or_die(b"INSERT INTO imports (file_id, module, row, names) VALUES (?1, ?2, ?3, ?4)");
    let ins_call = db.prepare_or_die(b"INSERT INTO calls (file_id, row, start, callee, in_symbol, text, qual) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6)");
    let ins_asg = db.prepare_or_die(b"INSERT INTO assigns (file_id, row, start, name, value, in_symbol) VALUES (?1, ?2, ?3, ?4, ?5, 0)");
    for &i in which {
        let fid = pids[i];
        // Records: kind 0x1f a 0x1f b 0x1f start 0x1f end 0x1f row 0x1e
        for rec in parsed[i].data.split(|&c| c == 0x1e) {
            let f = split(rec, 0x1f);
            if f.len() != 6 { continue; }
            let (st, _en, row) = match (parse_int(f[3]), parse_int(f[4]), parse_int(f[5])) {
                (Some(a), Some(b), Some(c)) => (a, b, c),
                _ => continue,
            };
            let en = _en;
            if f[0] == b"import" {
                ins_imp.reset();
                ins_imp.bind_int(1, fid);
                ins_imp.bind_text(2, f[1]);
                ins_imp.bind_int(3, row);
                ins_imp.bind_text(4, f[2]);
                ins_imp.step_done();
            } else if f[0] == b"assign" {
                ins_asg.reset();
                ins_asg.bind_int(1, fid);
                ins_asg.bind_int(2, row);
                ins_asg.bind_int(3, st);
                ins_asg.bind_text(4, f[1]);
                ins_asg.bind_text(5, f[2]);
                ins_asg.step_done();
            } else if f[0] == b"call" {
                ins_call.reset();
                ins_call.bind_int(1, fid);
                ins_call.bind_int(2, row);
                ins_call.bind_int(3, st);
                ins_call.bind_text(4, f[1]);
                ins_call.bind_text(5, f[2]);
                // (A Goose call's text is the rest of its line, and Goose has no methods.)
                ins_call.bind_text(6, if all_langs[i] == "goose" { b"" } else { qualifier_of(f[2]) });
                ins_call.step_done();
            } else {
                ins_sym.reset();
                ins_sym.bind_int(1, fid);
                ins_sym.bind_text(2, f[1]);
                ins_sym.bind_text(3, f[0]);
                ins_sym.bind_int(4, row);
                ins_sym.bind_int(5, st);
                ins_sym.bind_int(6, en);
                // b is "<end row> <signature line>"
                let sp = find(f[2], b" ");
                let er = parse_int(if sp > 0 { &f[2][..sp as usize] } else { f[2] });
                ins_sym.bind_int(7, er.unwrap_or(row));
                ins_sym.bind_text(8, if sp > 0 { &f[2][sp as usize + 1..] } else { b"" });
                let pn: Vec<u8> = if f[0] == b"function" && sp > 0 { param_names(&f[2][sp as usize + 1..]) } else { Vec::new() };
                ins_sym.bind_text(9, &pn);
                ins_sym.step_done();
            }
        }
    }
}

/// What the records of a file need once they are all written. Each
/// statement looks only within one file, so `update` runs them for the
/// files it read again (temp.u_changed) and index for every file.
pub fn settle_facts(db: &Db, only_changed: bool) {
    db.exec_or_die(&open_marks(sql::SETTLE_SQL.as_bytes(), b"only", only_changed));
}

/// Walks repo, parses every supported file and writes its facts and its
/// stamp. Returns the number of files indexed.
pub fn extract_repo(db: &Db, repo: &[u8]) -> i64 {
    let now = sys::time_ns();
    let mut all_paths: Vec<Vec<u8>> = Vec::new();
    let mut all_langs: Vec<&'static str> = Vec::new();
    let mut walked: Vec<Vec<u8>> = Vec::new();
    let n = walk_repo(repo, &mut all_paths, &mut all_langs, &mut walked) as usize;
    let mut pids: Vec<i64> = Vec::new();
    {
        let ins_file = db.prepare_or_die(b"INSERT INTO files (path, lang, dir) VALUES (?1, ?2, ?3)");
        for i in 0..n { pids.push(insert_file(db, &ins_file, &all_paths[i][repo.len() + 1..], all_langs[i])); }
    }
    let mut sizes: Vec<i64> = Vec::new();
    let mut mtimes: Vec<i64> = Vec::new();
    let mut ctimes: Vec<i64> = Vec::new();
    stat_files(&all_paths, n, &mut sizes, &mut mtimes, &mut ctimes);
    let which: Vec<usize> = (0..n).collect();
    let parsed = parse_files(&all_paths, &all_langs, n, &which, &[]);
    write_facts(db, &pids, &all_langs, &which, &parsed);
    settle_facts(db, false);
    let ins_stamp = db.prepare_or_die(b"INSERT OR REPLACE INTO stamps (file_id, ord, size, mtime, ctime, hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
    for i in 0..n { put_stamp(&ins_stamp, pids[i], i as i64, sizes[i], mtimes[i], ctimes[i], parsed[i].hash, now); }
    n as i64
}

pub fn record(out: &mut Vec<u8>, kind: &[u8], a: &[u8], b: &[u8], start: i64, end: i64, row: i64) {
    out.extend_from_slice(kind);
    out.push(0x1f);
    out.extend_from_slice(a);
    out.push(0x1f);
    out.extend_from_slice(b);
    out.push(0x1f);
    push_int(out, start);
    out.push(0x1f);
    push_int(out, end);
    out.push(0x1f);
    push_int(out, row);
    out.push(0x1e);
}

/// The local names an import statement binds, comma-separated: `a, b as c`
/// gives `a,c`; braces and `*` are skipped.
fn import_names(raw: &[u8], out: &mut Vec<u8>) {
    for part in raw.split(|&c| c == b',') {
        let mut p = trim(part);
        while !p.is_empty() && (p[0] == b'{' || p[0] == b'(') { p = trim(&p[1..]); }
        while !p.is_empty() && (p[p.len() - 1] == b'}' || p[p.len() - 1] == b')') { p = trim(&p[..p.len() - 1]); }
        let as_at = find(p, b" as ");
        let name = if as_at > 0 { trim(&p[as_at as usize + 4..]) } else { p };
        // `a::b::C` binds C
        let last = rfind(name, b"::");
        let n2 = if last >= 0 { &name[last as usize + 2..] } else { name };
        if !n2.is_empty() && n2 != b"*" && n2 != b"self" && callee_name(n2) == n2 {
            if !out.is_empty() { out.push(b','); }
            out.extend_from_slice(n2);
            // `from pkg import mod as x` also records `mod>x`, so the link
            // step can bind x to pkg/mod.
            if as_at > 0 {
                let orig = trim(&p[..as_at as usize]);
                if !orig.is_empty() && callee_name(orig) == orig {
                    out.push(b',');
                    out.extend_from_slice(orig);
                    out.push(b'>');
                    out.extend_from_slice(n2);
                }
            }
        }
    }
}

// Goose (github.com/aardappel/goose) by line, since there is no grammar for
// it: definitions, imports and calls. Comments and strings are blanked
// first. A definition ends at the closing brace on its own indentation.
const GOOSE_WORDS: [&str; 23] = [
    "if", "else", "while", "for", "loop", "guard", "return", "match", "fn", "thread_fn", "let", "var", "in", "as",
    "struct", "enum", "import", "extern", "break", "continue", "and", "or", "not",
];

fn goose_scan(text: &[u8], out: &mut Vec<u8>) {
    // code: text with comments and string contents turned to spaces, newlines kept.
    let mut code: Vec<u8> = Vec::with_capacity(text.len());
    let mut i = 0;
    let mut in_raw = false;
    let mut in_str = false;
    while i < text.len() {
        let c = text[i];
        if in_raw {
            if c == b'"' && i + 2 < text.len() && text[i + 1] == b'"' && text[i + 2] == b'"' { in_raw = false; code.extend_from_slice(b"   "); i += 3; continue; }
            code.push(if c == b'\n' { b'\n' } else { b' ' });
        } else if in_str {
            if c == b'\\' && i + 1 < text.len() { code.extend_from_slice(b"  "); i += 2; continue; }
            if c == b'"' || c == b'\n' { in_str = false; }
            code.push(if c == b'\n' { b'\n' } else { b' ' });
        } else if c == b'"' && i + 2 < text.len() && text[i + 1] == b'"' && text[i + 2] == b'"' {
            in_raw = true; code.extend_from_slice(b"   "); i += 3; continue;
        } else if c == b'"' {
            in_str = true; code.push(b' ');
        } else if c == b'\'' && i + 2 < text.len() && (text[i + 2] == b'\'' || (text[i + 1] == b'\\' && i + 3 < text.len() && text[i + 3] == b'\'')) {
            let n = if text[i + 2] == b'\'' { 3 } else { 4 };
            for _ in 0..n { code.push(b' '); }
            i += n; continue;
        } else if c == b'/' && i + 1 < text.len() && text[i + 1] == b'/' {
            while i < text.len() && text[i] != b'\n' { code.push(b' '); i += 1; }
            continue;
        } else {
            code.push(c);
        }
        i += 1;
    }
    // Line starts, for rows and for finding where a definition ends.
    let mut starts: Vec<usize> = vec![0];
    for k in 0..code.len() { if code[k] == b'\n' { starts.push(k + 1); } }
    fn indent_of(l: &[u8]) -> usize { let mut n = 0; while n < l.len() && l[n] == b' ' { n += 1; } n }
    for r in 0..starts.len() {
        let ls = starts[r];
        let le = if r + 1 < starts.len() { starts[r + 1] - 1 } else { code.len() };
        if !(le > ls) { continue; }
        let line = &code[ls..le];
        let ind = indent_of(line);
        let t = &line[ind..];
        // Imports: the original text holds the package string, the code the name.
        if ind == 0 && starts_with(t, b"import ") {
            let semi = find(t, b";");
            let body = trim(if semi > 0 { &t[7..semi as usize] } else { &t[7..] });
            let sp = find(body, b" ");
            let m = if sp > 0 { &body[..sp as usize] } else { body };
            if !m.is_empty() { record(out, b"import", m, b"", ls as i64, le as i64, r as i64 + 1); }
            continue;
        }
        // Definitions.
        let mut kind: &[u8] = b"";
        let mut skip: i64 = -1;
        if starts_with(t, b"fn ") { kind = b"function"; skip = 3; }
        else if starts_with(t, b"thread_fn ") { kind = b"function"; skip = 10; }
        else if starts_with(t, b"extern ") && find(t, b"fn ") > 0 { kind = b"function"; skip = find(t, b"fn ") + 3; }
        else if starts_with(t, b"struct ") { kind = b"struct"; skip = 7; }
        else if starts_with(t, b"enum ") { kind = b"enum"; skip = 5; }
        else if ind == 0 && (starts_with(t, b"let ") || starts_with(t, b"var ")) { kind = b"variable"; skip = 4; }
        let rest = if skip >= 0 { &t[skip as usize..] } else { &t[..0] };
        let mut def_name_end = 0usize;
        if !kind.is_empty() {
            let mut n = 0;
            while n < rest.len() && ident_char(rest[n]) { n += 1; }
            if n > 0 {
                let name_at = ls + (line.len() - rest.len());
                def_name_end = name_at + n - ls;
                // Ends on this line (a one-liner, an extern, a let), or at the
                // first later line that is `}` at this indentation.
                let mut end_row = r;
                let opens = find(t, b"{") >= 0 && rfind(t, b"}") < rfind(t, b"{");
                if opens {
                    let mut q = r + 1;
                    while q < starts.len() {
                        let qs = starts[q];
                        let qe = if q + 1 < starts.len() { starts[q + 1] - 1 } else { code.len() };
                        let ql = &code[qs..qs.max(qe)];
                        if indent_of(ql) == ind && ql.len() > ind && ql[ind] == b'}' { end_row = q; break; }
                        q += 1;
                    }
                }
                let end_at = if end_row + 1 < starts.len() { starts[end_row + 1] - 1 } else { code.len() };
                let brace = find(&text[ls..le], b"{");
                let sig = trim(if brace > 0 && kind != b"variable" { &text[ls..ls + brace as usize] } else { &text[ls..le.min(ls + 600)] });
                let mut b: Vec<u8> = Vec::new();
                push_int(&mut b, end_row as i64 + 1);
                b.push(b' ');
                b.extend_from_slice(sig);
                record(out, kind, &rest[..n], &b, name_at as i64, end_at as i64, r as i64 + 1);
            }
        }
        // Calls: a bare name directly before `(`, past the definition's own name.
        let mut k = ind.max(def_name_end);
        while k < line.len() {
            if ident_char(line[k]) && (k == 0 || !ident_char(line[k - 1])) {
                let mut e = k;
                while e < line.len() && ident_char(line[e]) { e += 1; }
                let word = &line[k..e];
                let qualified = (k >= 1 && line[k - 1] == b'.') || (k >= 2 && line[k - 1] == b':' && line[k - 2] == b':');
                let generic = e < line.len() && line[e] == b'<';
                let mut p = e;
                if generic { while p < line.len() && line[p] != b'>' { p += 1; } if p < line.len() { p += 1; } }
                if p < line.len() && line[p] == b'(' && !qualified && !GOOSE_WORDS.iter().any(|w| w.as_bytes() == word) && !word[0].is_ascii_digit() {
                    record(out, b"call", word, &one_line(trim(&text[ls + k..le]), 120), (ls + k) as i64, (ls + e) as i64, r as i64 + 1);
                }
                k = e;
            } else { k += 1; }
        }
    }
}

/// One file: its records. What a worker does for each file it takes.
fn extract_file(path: &[u8], lang: &'static str, known: Option<i64>, kinds: &mut HashMap<&'static str, Vec<i64>>, nodes: &mut Vec<i32>) -> Parsed {
    let mut done = Parsed::default();
    let read = sys::read_file(path);
    // (A file that cannot be read has the hash 0 and no facts.)
    if let Some(t) = &read { done.hash = hash(t) as i64; }
    // update: the content index saw last time; nothing to read again.
    if let Some(old) = known {
        if old == done.hash { done.same = true; return done; }
    }
    let text = match read { Some(t) => t, None => return done };
    let text = &text[..];
    if lang == "goose" {
        goose_scan(text, &mut done.data);
        return done;
    }
    if ts::parse(lang, text, nodes) {
        if reads_by_kind(lang) {
            if let Some(language) = ts::language(lang) {
                let cls = kinds.entry(lang).or_default();
                tree_definitions(lang, &language, cls, text, nodes, &mut done.data);
            }
        }
        let python = lang == "python";
        for c in compiled(lang) {
            let mut m = Matcher::new(&c.pattern, text, nodes);
            let n = (nodes.len() / ts::R) as i64;
            for node in 0..n {
                if !m.matches_at(node) { continue; }
                let cap = m.capture(&c.capture);
                let st = ts::start(nodes, node);
                let en = ts::end(nodes, node);
                let row = ts::row(nodes, node) + 1;
                let node_text = &text[st as usize..en as usize];
                if cap.is_empty() { continue; }
                let kind = &c.kind[..];
                if kind == b"mod" {
                    let mut mm: Vec<u8> = b"mod::".to_vec();
                    mm.extend_from_slice(cap);
                    record(&mut done.data, b"import", &mm, b"", st, en, row);
                } else if kind == b"import" {
                    let mut names: Vec<u8> = Vec::new();
                    let t = trim(cap);
                    // The names after `import`, from the statement's own text
                    // (a `$$$X` capture can come back empty here).
                    let imp_at = find(node_text, b" import ");
                    let after: &[u8] = if imp_at >= 0 { &node_text[imp_at as usize + 8..] } else { b"" };
                    if python && t.iter().all(|&c| c == b'.') {
                        // `from . import a, b`: the modules a and b, beside this file.
                        for x in after.split(|&c| c == b',') {
                            names.clear();
                            import_names(x, &mut names);
                            if !names.is_empty() {
                                let mut mm = t.to_vec();
                                mm.extend_from_slice(&names);
                                record(&mut done.data, b"import", &mm, b"", st, en, row);
                            }
                        }
                    } else {
                        if python { import_names(after, &mut names); }
                        if python && imp_at < 0 {
                            // `import a.b as x`: the module a.b, bound to the name x.
                            let as_at = find(t, b" as ");
                            if as_at > 0 {
                                names.clear();
                                names.push(b'@');
                                names.extend_from_slice(trim(&t[as_at as usize + 4..]));
                                record(&mut done.data, b"import", trim(&t[..as_at as usize]), &names, st, en, row);
                                names.clear();
                                names.extend_from_slice(b"-");
                            }
                        }
                        if lang == "rust" {
                            let brace = find(t, b"::{");
                            if brace > 0 { import_names(&t[brace as usize + 3..], &mut names); }
                            else { import_names(t, &mut names); }
                        }
                        let mname = module_name(cap);
                        if !mname.is_empty() && names != b"-" { record(&mut done.data, b"import", mname, &names, st, en, row); }
                    }
                } else if kind == b"assign" {
                    // `x = f(...)`: x holds what f returns.
                    let v = m.capture(b"F");
                    if !v.is_empty() && callee_name(cap) == trim(cap) {
                        record(&mut done.data, b"assign", trim(cap), &one_line(v, 120), st, en, row);
                    }
                } else if kind == b"iter" {
                    // `for m in PAT.finditer(s)`: each name is bound to what
                    // iterating f(...) yields, kept as `iter:f`.
                    let v = m.capture(b"F");
                    if !v.is_empty() {
                        for part in cap.split(|&c| c == b',') {
                            let mut nm = trim(part);
                            while !nm.is_empty() && (nm[0] == b'(' || nm[0] == b'[' || nm[0] == b'*') { nm = trim(&nm[1..]); }
                            while !nm.is_empty() && (nm[nm.len() - 1] == b')' || nm[nm.len() - 1] == b']') { nm = trim(&nm[..nm.len() - 1]); }
                            if !nm.is_empty() && find(nm, b".") < 0 && find(nm, b"[") < 0 && callee_name(nm) == nm {
                                let mut val: Vec<u8> = b"iter:".to_vec();
                                val.extend_from_slice(&one_line(v, 110));
                                record(&mut done.data, b"assign", nm, &val, st, en, row);
                            }
                        }
                    }
                } else if kind == b"bind" {
                    // Any other binding of a plain name: the value is unknown
                    // here. A subscript target binds no name: its parts, up
                    // to the closing bracket, are skipped.
                    let mut in_sub = false;
                    for part in cap.split(|&c| c == b',') {
                        let mut nm = trim(part);
                        if in_sub {
                            if find(nm, b"]") >= 0 { in_sub = false; }
                        } else {
                            while !nm.is_empty() && (nm[0] == b'(' || nm[0] == b'[' || nm[0] == b'*') { nm = trim(&nm[1..]); }
                            if find(nm, b"[") > 0 {
                                if find(nm, b"]") < 0 { in_sub = true; }
                            } else {
                                while !nm.is_empty() && (nm[nm.len() - 1] == b')' || nm[nm.len() - 1] == b']') { nm = trim(&nm[..nm.len() - 1]); }
                                if !nm.is_empty() && find(nm, b".") < 0 && callee_name(nm) == nm { record(&mut done.data, b"assign", nm, b"?", st, en, row); }
                            }
                        }
                    }
                } else if kind == b"call" {
                    let cn = callee_name(cap);
                    if !cn.is_empty() { record(&mut done.data, b"call", cn, &one_line(cap, 120), st, en, row); }
                } else {
                    let name = callee_name(cap);
                    if !name.is_empty() {
                        let end_row = row + count_newlines(node_text);
                        let mut b: Vec<u8> = Vec::new();
                        push_int(&mut b, end_row);
                        b.push(b' ');
                        b.extend_from_slice(&header_line(node_text, python, 600));
                        record(&mut done.data, kind, name, &b, st, en, row);
                    }
                }
            }
        }
    }
    // ES modules: `import ... from "m"`, `import "m"`, `export ... from "m"`,
    // read from the text (a pattern can't hold the module string).
    if lang == "typescript" || lang == "tsx" || lang == "javascript" {
        let mut row: i64 = 0;
        // A statement whose braces close on a later line is read as one
        // line, at the row it starts on.
        let mut pending: Vec<u8> = Vec::new();
        let mut pend_row: i64 = 0;
        let mut stmt: Vec<u8> = Vec::new();
        let mut stmt_row: i64 = 0;
        for raw in text.split(|&c| c == b'\n') {
            row += 1;
            let t = trim(raw);
            let mut have = false;
            if !pending.is_empty() {
                pending.push(b' ');
                pending.extend_from_slice(t);
                if find(t, b"}") >= 0 || row - pend_row >= 400 {
                    stmt.clear(); stmt.extend_from_slice(&pending); stmt_row = pend_row; pending.clear(); have = true;
                }
            } else if starts_with(t, b"import ") || starts_with(t, b"import\"") || starts_with(t, b"import'") || starts_with(t, b"export ") {
                let opens = (starts_with(t, b"import ") || starts_with(t, b"export {") || starts_with(t, b"export type {"))
                    && find(t, b"{") >= 0 && find(t, b"}") < 0 && find(t, b"(") < 0 && find(t, b"=") < 0;
                if opens { pending.extend_from_slice(t); pend_row = row; }
                else { stmt.clear(); stmt.extend_from_slice(t); stmt_row = row; have = true; }
            }
            if have {
                let line = &stmt[..];
                let mut at = find(line, b" from ");
                if at >= 0 { at += 6; } else if starts_with(line, b"import") { at = 6; } else { at = -1; }
                if at >= 0 {
                    let rest = trim(&line[at as usize..]);
                    if rest.len() >= 2 && (rest[0] == b'"' || rest[0] == b'\'') {
                        let close = find(&rest[1..], &rest[..1]);
                        if close > 0 {
                            // The names: `import a, { b, c as d } from` gives a,b,d.
                            let mut names: Vec<u8> = Vec::new();
                            let head_end = find(line, b" from ");
                            if head_end > 7 && starts_with(line, b"import ") {
                                let mut head = trim(&line[7..head_end as usize]);
                                if starts_with(head, b"type ") { head = trim(&head[5..]); }
                                if starts_with(head, b"* as ") { names.push(b'@'); names.extend_from_slice(trim(&head[5..])); }
                                else { import_names(head, &mut names); }
                            }
                            record(&mut done.data, b"import", &rest[1..1 + close as usize], &names, 0, 0, stmt_row);
                        }
                    }
                }
            }
        }
    }
    done
}

/// The first line of s, at most n bytes, with no record separators.
pub fn one_line(s: &[u8], n: usize) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    for &c in s {
        if c == b'\n' || out.len() >= n { break; }
        out.push(if c == 0x1e || c == 0x1f || c == b'\r' { b' ' } else { c });
    }
    out
}

const PARAM_WORDS: [&str; 6] = ["mut", "public", "private", "protected", "readonly", "override"];

/// The parameter names of a function header, as ",a,b,c,": the pieces of its
/// first parenthesised list, split at top-level commas, each one's leading
/// name. "" when there are none.
fn param_names(header: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    // Rust's `pub(crate) fn f(a)`: the visibility's parentheses are not the list.
    let mut skip = 0usize;
    if starts_with(header, b"pub(") {
        let close = find(header, b")");
        if close > 0 { skip = close as usize + 1; }
    }
    let at = find(&header[skip..], b"(");
    if at < 0 { return out; }
    let open = skip + at as usize;
    let mut depth = 0;
    let mut piece: Vec<u8> = Vec::new();
    fn take(piece: &mut Vec<u8>, out: &mut Vec<u8>) {
        let mut p = trim(piece);
        while !p.is_empty() && (p[0] == b'*' || p[0] == b'&') { p = trim(&p[1..]); }
        // Rust's `mut x`, and a TypeScript constructor's `private readonly x`.
        let mut again = true;
        while again {
            again = false;
            for w in PARAM_WORDS {
                let w = w.as_bytes();
                if p.len() > w.len() && starts_with(p, w) && p[w.len()] == b' ' { p = trim(&p[w.len()..]); again = true; }
            }
        }
        let mut n = 0;
        while n < p.len() && (p[n].is_ascii_alphanumeric() || p[n] == b'_' || p[n] == b'$') { n += 1; }
        if n > 0 && !p[0].is_ascii_digit() {
            if out.is_empty() { out.push(b','); }
            out.extend_from_slice(&p[..n]);
            out.push(b',');
        }
        piece.clear();
    }
    for i in open + 1..header.len() {
        let c = header[i];
        if c == b'(' || c == b'[' || c == b'{' || c == b'<' { depth += 1; piece.push(c); }
        else if c == b')' || c == b']' || c == b'}' || c == b'>' {
            if depth == 0 { break; }
            depth -= 1;
            piece.push(c);
        }
        else if c == b',' && depth == 0 { take(&mut piece, &mut out); }
        else { piece.push(c); }
    }
    take(&mut piece, &mut out);
    out
}

/// A definition's header on one line: through the parameter list, however
/// many lines it runs over, to the `:` (Python) or `{` that opens the body.
/// The first line alone when there is no parameter list.
fn header_line(s: &[u8], python: bool, n: usize) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut depth = 0;
    let mut seen_paren = false;
    let mut prev_space = false;
    for &c in s {
        if out.len() >= n { break; }
        if c == b'\n' && !seen_paren { break; }
        if c == b'(' || c == b'[' { depth += 1; if c == b'(' { seen_paren = true; } }
        else if c == b')' || c == b']' { if depth > 0 { depth -= 1; } }
        let end = seen_paren && depth == 0 && ((python && c == b':') || (!python && (c == b'{' || c == b';')));
        let ch = if c == b'\n' || c == b'\t' || c == b'\r' || c == 0x1e || c == 0x1f { b' ' } else { c };
        if !(ch == b' ' && prev_space) { out.push(ch); }
        prev_space = ch == b' ';
        if end { break; }
    }
    out
}

pub fn count_newlines(s: &[u8]) -> i64 { s.iter().filter(|&&c| c == b'\n').count() as i64 }
