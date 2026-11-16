// Facts from source, by syntax tree, never by running anything: definitions,
// imports and call sites, found with goose-treesitter's ast-grep style
// patterns on every core. A pattern matches one shape of code, so each
// language has a few variants (`fn` and `pub fn`, a return type or not).

import std;
import sqlite;
import treesitter;

// The folders a walk never enters: dependencies, caches, build output.
let SKIP_DIRS = ["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox",
                 ".mypy_cache", ".pytest_cache", "dist", "build", ".gradle", "obj", ".next",
                 ".spread-wings", ".swan"];

// The languages v0.1 extracts, as goose-treesitter names them.
fn supported(lang: const u8[:]) -> bool {
    return lang == "python" || lang == "typescript" || lang == "tsx" || lang == "javascript" || lang == "rust";
}

// "kind<TAB>capture<TAB>pattern" per line. kind "import" captures the
// module, "call" the callee, anything else names a definition.
fn patterns(lang: const u8[:]) -> const u8[:] {
    if lang == "python" {
        return """
function	NAME	def $NAME($$$A): $$$B
function	NAME	def $NAME($$$A) -> $R: $$$B
function	NAME	async def $NAME($$$A): $$$B
function	NAME	async def $NAME($$$A) -> $R: $$$B
class	NAME	class $NAME($$$A): $$$B
class	NAME	class $NAME: $$$B
import	M	import $M
import	M	from $M import $$$X
call	F	$F($$$A)
""";
    }
    if lang == "rust" {
        return """
function	NAME	fn $NAME($$$A) -> $R { $$$B }
function	NAME	fn $NAME($$$A) { $$$B }
function	NAME	pub fn $NAME($$$A) -> $R { $$$B }
function	NAME	pub fn $NAME($$$A) { $$$B }
function	NAME	pub(crate) fn $NAME($$$A) -> $R { $$$B }
function	NAME	pub(crate) fn $NAME($$$A) { $$$B }
function	NAME	async fn $NAME($$$A) -> $R { $$$B }
function	NAME	async fn $NAME($$$A) { $$$B }
function	NAME	pub async fn $NAME($$$A) -> $R { $$$B }
function	NAME	pub async fn $NAME($$$A) { $$$B }
struct	NAME	struct $NAME { $$$B }
struct	NAME	pub struct $NAME { $$$B }
struct	NAME	struct $NAME($$$B);
struct	NAME	pub struct $NAME($$$B);
enum	NAME	enum $NAME { $$$B }
enum	NAME	pub enum $NAME { $$$B }
trait	NAME	trait $NAME { $$$B }
trait	NAME	pub trait $NAME { $$$B }
impl	T	impl $T { $$$B }
impl	T	impl $TR for $T { $$$B }
mod	NAME	mod $NAME;
mod	NAME	pub mod $NAME;
import	P	use $P;
import	P	pub use $P;
call	F	$F($$$A)
""";
    }
    if lang == "javascript" {
        return """
function	NAME	function $NAME($$$A) { $$$B }
function	NAME	async function $NAME($$$A) { $$$B }
function	NAME	const $NAME = ($$$A) => $B
function	NAME	const $NAME = async ($$$A) => $B
class	NAME	class $NAME { $$$B }
class	NAME	class $NAME extends $S { $$$B }
import	M	require($M)
call	F	$F($$$A)
""";
    }
    // typescript, tsx
    return """
function	NAME	function $NAME($$$A) { $$$B }
function	NAME	function $NAME($$$A): $T { $$$B }
function	NAME	async function $NAME($$$A) { $$$B }
function	NAME	async function $NAME($$$A): $T { $$$B }
function	NAME	const $NAME = ($$$A) => $B
function	NAME	const $NAME = async ($$$A) => $B
class	NAME	class $NAME { $$$B }
class	NAME	class $NAME extends $S { $$$B }
class	NAME	class $NAME implements $$$I { $$$B }
interface	NAME	interface $NAME { $$$B }
import	M	require($M)
call	F	$F($$$A)
""";
}

// The capture named `name` from search_files' captures (name 0x1f text 0x1e).
fn capture(caps: const u8[:], name: const u8[:]) -> const u8[:] {
    var pos = 0;
    while pos < caps.len {
        let sep = find(caps[pos..], "\x1f");
        guard sep >= 0 else { break; }
        let end = find(caps[pos + sep + 1..], "\x1e");
        guard end >= 0 else { break; }
        if caps[pos..pos + sep] == name { return caps[pos + sep + 1..pos + sep + 1 + end]; }
        pos = pos + sep + 1 + end + 1;
    }
    return "";
}

fn ident_char(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
}

// The name a call reaches: the last identifier of `a.b.c`, `a::b`, `x?.y`,
// dropping generic arguments. "" when the callee isn't a plain name path
// (a call on a call, a closure, an index).
fn callee_name(f: const u8[:]) -> const u8[:] {
    var end = f.len;
    if end > 0 && f[end - 1] == '>' {
        let lt = find(f, "<");
        if lt > 0 { end = lt; }
    }
    if end >= 2 && f[end - 2] == ':' && f[end - 1] == ':' { end = end - 2; }   // `f::<T>`
    var i = end;
    while i > 0 && ident_char(f[i - 1]) { i--; }
    guard i < end else { return ""; }
    let c = f[i];
    guard !(c >= '0' && c <= '9') else { return ""; }
    return f[i..end];
}

// The module an import names, quotes and braces trimmed: `"./m"` -> `./m`,
// `crate::state::{A, B}` -> `crate::state`.
fn module_name(m: const u8[:]) -> const u8[:] {
    var s = trim(m);
    if s.len >= 2 && (s[0] == '"' || s[0] == '\'' || s[0] == '`') { s = s[1..s.len - 1]; }
    let brace = find(s, "::{");
    if brace > 0 { s = s[..brace]; }
    return s;
}

struct Def { file: i64, start: i64, end: i64, id: i64 }

extern fn sw_is_symlink(path: const u8[:]) -> bool;

let LANGS = ["python", "typescript", "tsx", "javascript", "rust"];

// Walks repo, parses every supported file and writes its facts. Returns
// the number of files indexed.
fn extract_repo(db: i64, repo: const u8[:]) -> i64 {
    // Every file found: its absolute path and language, one per line each, and its row id.
    var paths: u8[>..] = [];
    var plangs: u8[>..] = [];
    var pids: i64[>..] = [];
    let ins_file = sqlite::prepare_or_die(db, "INSERT INTO files (path, lang, dir) VALUES (?1, ?2, ?3)");
    var dirs: u8[>..] = [];
    dirs.append(repo);
    dirs.push('\n');
    var next = 0;
    while next < dirs.len && pids.len < 200000 {
        let end = next + find(dirs[next..], "\n");
        var dir: u8[>..] = [];
        dir.append(dirs[next..end]);
        next = end + 1;
        var names: u8[>..] = [];
        guard list_dir(dir, names) else { continue; }
        each_split(names, '\n') { name =>
            guard name.len > 0;
            var full: u8[>..] = [];
            format(full, dir, "/", name);
            if is_dir(full) {
                // Hidden folders (.git, .tools, .github, .cache) hold tooling, not the code.
                if name[0] != '.' && !contains(SKIP_DIRS, name) && !sw_is_symlink(full) { dirs.append(full); dirs.push('\n'); }
            } else {
                let lang = treesitter::language_of_path(full);
                if supported(lang) && !sw_is_symlink(full) {
                    let rel = full[repo.len + 1..];
                    let slash = rfind(rel, "/");
                    sqlite::reset(ins_file);
                    sqlite::bind_text(ins_file, 1, rel);
                    sqlite::bind_text(ins_file, 2, lang);
                    sqlite::bind_text(ins_file, 3, if slash >= 0 { rel[..slash] } else { "." });
                    sqlite::step_done(ins_file);
                    pids.push(sqlite::last_rowid(db));
                    paths.append(full);
                    paths.push('\n');
                    plangs.append(lang);
                    plangs.push('\n');
                }
            }
        };
    }
    sqlite::finalize(ins_file);
    let all_paths = split(paths, '\n');
    let all_langs = split(plangs, '\n');

    let ins_sym = sqlite::prepare_or_die(db, "INSERT INTO symbols (file_id, name, kind, row, start, end_) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
    let ins_imp = sqlite::prepare_or_die(db, "INSERT INTO imports (file_id, module, row) VALUES (?1, ?2, ?3)");
    let ins_call = sqlite::prepare_or_die(db, "INSERT INTO calls (file_id, row, start, callee, in_symbol) VALUES (?1, ?2, ?3, ?4, 0)");
    for li in 0..LANGS.len {
        // An owned copy: treesitter::compile reuses its own buffers, which a
        // slice of the language list could otherwise alias.
        var lang: u8[>..] = [];
        lang.append(LANGS[li]);
        // This language's files, as search_files wants them, and their row ids.
        var list: u8[>..] = [];
        var ids: i64[>..] = [];
        for i in 0..pids.len {
            if all_langs[i] == lang { list.append(all_paths[i]); list.push('\n'); ids.push(pids[i]); }
        }
        guard ids.len > 0 else { continue; }
        each_split(patterns(lang), '\n') { line =>
            let f = split(line, '\t');
            guard f.len == 3;
            var why: u8[>..] = [];
            if treesitter::compile(lang, f[2], why) {
            treesitter::search_files(list) { idx, start, end, row, col, caps =>
                let fid = ids[idx];
                let text = capture(caps, f[1]);
                guard text.len > 0;
                if f[0] == "mod" {
                    sqlite::reset(ins_imp);
                    sqlite::bind_int(ins_imp, 1, fid);
                    sqlite::bind_text(ins_imp, 2, str("mod::", text));
                    sqlite::bind_int(ins_imp, 3, row + 1);
                    sqlite::step_done(ins_imp);
                } else if f[0] == "import" && lang == "python" && trim(text).len > 0 && only_dots(trim(text)) {
                    // `from . import a, b`: the modules are a and b, beside this file.
                    each_split(capture(caps, "X"), ',') { x =>
                        let name = trim(x);
                        let sp = find(name, " ");   // `a as b`
                        let base = if sp > 0 { name[..sp] } else { name };
                        if base.len > 0 && base != "*" && base != "(" {
                            sqlite::reset(ins_imp);
                            sqlite::bind_int(ins_imp, 1, fid);
                            sqlite::bind_text(ins_imp, 2, str(trim(text), base));
                            sqlite::bind_int(ins_imp, 3, row + 1);
                            sqlite::step_done(ins_imp);
                        }
                    };
                } else if f[0] == "import" {
                    let m = module_name(text);
                    guard m.len > 0;
                    sqlite::reset(ins_imp);
                    sqlite::bind_int(ins_imp, 1, fid);
                    sqlite::bind_text(ins_imp, 2, m);
                    sqlite::bind_int(ins_imp, 3, row + 1);
                    sqlite::step_done(ins_imp);
                } else if f[0] == "call" {
                    let c = callee_name(text);
                    guard c.len > 0;
                    sqlite::reset(ins_call);
                    sqlite::bind_int(ins_call, 1, fid);
                    sqlite::bind_int(ins_call, 2, row + 1);
                    sqlite::bind_int(ins_call, 3, start);
                    sqlite::bind_text(ins_call, 4, c);
                    sqlite::step_done(ins_call);
                } else {
                    let name = callee_name(text);
                    guard name.len > 0;
                    sqlite::reset(ins_sym);
                    sqlite::bind_int(ins_sym, 1, fid);
                    sqlite::bind_text(ins_sym, 2, name);
                    sqlite::bind_text(ins_sym, 3, f[0]);
                    sqlite::bind_int(ins_sym, 4, row + 1);
                    sqlite::bind_int(ins_sym, 5, start);
                    sqlite::bind_int(ins_sym, 6, end);
                    sqlite::step_done(ins_sym);
                }
            };
            } else {
                write_stderr(str("spread-wings: pattern skipped for ", lang, ": ", f[2], " (", why, ")\n"));
            }
        };
    }
    // ES modules: `import ... from "m"`, `import "m"`, `export ... from "m"`.
    // A pattern can't hold the module (it must be a string literal), and the
    // statement is one line in practice, so these are read from the text.
    for i in 0..pids.len {
        let l = all_langs[i];
        guard l == "typescript" || l == "tsx" || l == "javascript" else { continue; }
        var text: u8[>..] = [];
        guard read_file(all_paths[i], text) else { continue; }
        var row = 0;
        each_split(text, '\n') { raw =>
            row++;
            let line = trim(raw);
            if starts_with(line, "import ") || starts_with(line, "import\"") || starts_with(line, "import'") || starts_with(line, "export ") {
                var at = find(line, " from ");
                if at >= 0 { at = at + 6; } else if starts_with(line, "import") { at = 6; } else { at = -1; }
                if at >= 0 {
                    let rest = trim(line[at..]);
                    if rest.len >= 2 && (rest[0] == '"' || rest[0] == '\'') {
                        let close = find(rest[1..], rest[..1]);
                        if close > 0 {
                            sqlite::reset(ins_imp);
                            sqlite::bind_int(ins_imp, 1, pids[i]);
                            sqlite::bind_text(ins_imp, 2, rest[1..1 + close]);
                            sqlite::bind_int(ins_imp, 3, row);
                            sqlite::step_done(ins_imp);
                        }
                    }
                }
            }
        };
    }
    sqlite::finalize(ins_sym);
    sqlite::finalize(ins_imp);
    sqlite::finalize(ins_call);
    // Two patterns can match one definition (`fn` and `pub fn` don't, but a
    // const arrow and a call can overlap): keep one row per place.
    sqlite::exec_or_die(db, """
        DELETE FROM symbols WHERE id NOT IN (
            SELECT MIN(id) FROM symbols GROUP BY file_id, start, name);
        -- A call site sits in the innermost definition that spans it.
        UPDATE calls SET in_symbol = COALESCE((
            SELECT s.id FROM symbols s
            WHERE s.file_id = calls.file_id AND s.start <= calls.start AND calls.start < s.end_
              AND s.kind IN ('function', 'impl')
            ORDER BY s.end_ - s.start LIMIT 1), 0);
        -- A definition's own pattern also matches as a call in some grammars
        -- (`require(...)`); a call at a definition's exact start is not one.
        DELETE FROM calls WHERE EXISTS (
            SELECT 1 FROM symbols s WHERE s.file_id = calls.file_id AND s.start = calls.start);
    """);
    return pids.len;
}

fn only_dots(s: const u8[:]) -> bool {
    for c in s { if c != '.' { return false; } }
    return true;
}

fn trim_nul(s: const u8[:]) -> const u8[:] {
    var n = s.len;
    while n > 0 && s[n - 1] == 0 { n--; }
    return s[..n];
}
