// The graph lives in one SQLite file. Facts come straight from the parser
// (files, definitions, imports, call sites); edges are derived from them by
// name and say so (`by_name`, with a weight when a name has several
// definitions).

import std;
import sqlite;

let SCHEMA = """
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY, path TEXT UNIQUE, lang TEXT, dir TEXT,
    community INTEGER, is_test INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS symbols (
    id INTEGER PRIMARY KEY, file_id INTEGER, name TEXT, kind TEXT,
    row INTEGER, start INTEGER, end_ INTEGER, end_row INTEGER, sig TEXT, container TEXT,
    params TEXT);   -- a function's parameter names, ",a,b,c," ("" for none): what its body binds on entry
CREATE TABLE IF NOT EXISTS imports (file_id INTEGER, module TEXT, row INTEGER, names TEXT, dst INTEGER);
CREATE TABLE IF NOT EXISTS calls (
    file_id INTEGER, row INTEGER, start INTEGER, callee TEXT, in_symbol INTEGER, text TEXT,
    note TEXT,
    qual TEXT);     -- the name right before the callee's: `Pair` of `Pair::new`, `this` of `this.push`; "" for none
CREATE TABLE IF NOT EXISTS assigns (
    file_id INTEGER, row INTEGER, start INTEGER, name TEXT, value TEXT, in_symbol INTEGER);
CREATE INDEX IF NOT EXISTS assigns_scope ON assigns(file_id, name);
CREATE TABLE IF NOT EXISTS aliases (file_id INTEGER, alias TEXT, dst INTEGER);
CREATE TABLE IF NOT EXISTS file_edges (src INTEGER, dst INTEGER, kind TEXT, weight REAL);
CREATE TABLE IF NOT EXISTS call_edges (
    caller INTEGER, callee INTEGER, file_id INTEGER, row INTEGER, weight REAL, by_name INTEGER,
    resolution TEXT);
CREATE TABLE IF NOT EXISTS decisions (
    file_id INTEGER, row INTEGER, callee TEXT, choice TEXT, target INTEGER, p INTEGER);
CREATE TABLE IF NOT EXISTS communities (id INTEGER PRIMARY KEY, label TEXT, size INTEGER, tests INTEGER);
-- What index last saw of each file, for `update`: its place in the walk
-- (0 for the first file), and its size, times and a hash of its content.
-- mtime and ctime are 0 when the file was written so close to the run that
-- a later write could carry the same times: such a file is read again.
CREATE TABLE IF NOT EXISTS stamps (
    file_id INTEGER PRIMARY KEY, ord INTEGER, size INTEGER, mtime INTEGER, ctime INTEGER, hash INTEGER);
CREATE INDEX IF NOT EXISTS symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS symbols_file ON symbols(file_id);
CREATE INDEX IF NOT EXISTS calls_callee ON calls(callee);
CREATE INDEX IF NOT EXISTS calls_file ON calls(file_id);
CREATE INDEX IF NOT EXISTS file_edges_src ON file_edges(src);
CREATE INDEX IF NOT EXISTS imports_file ON imports(file_id, dst);
CREATE INDEX IF NOT EXISTS aliases_file ON aliases(file_id, dst);
CREATE INDEX IF NOT EXISTS calls_site ON calls(file_id, row);
CREATE INDEX IF NOT EXISTS file_edges_dst ON file_edges(dst);
""";

fn open_fresh(path: const u8[:]) -> i64 {
    delete_file(path);
    delete_file(str(path, "-wal"));
    delete_file(str(path, "-shm"));
    var err: u8[>..] = [];
    let db = sqlite::open(path, err);
    guard db != 0 else { abort(str("spread-wings: cannot create ", path, ": ", err)); }
    sqlite::exec_or_die(db, SCHEMA);
    return db;
}

// The number of this file's layout (the tables and columns above). It goes
// up whenever they change; a graph written with another number is rebuilt,
// not read: indexing takes seconds, and a command that met a missing column
// used to stop with a raw SQL error.
let SCHEMA_NUMBER = "8";

// The number of what index writes for a given repo: the readers, the
// patterns and the link rules. It goes up whenever a change to any of them
// gives some repo another graph. `update` redoes only what a changed file
// reaches, so a graph it left half under the old rules and half under the
// new would be neither: a graph written under another number is rebuilt
// whole. (tests/test.sh holds the fixtures' graphs to this number: when
// they change and it has not, a check fails and says to raise it.)
let RULES_NUMBER = "1";

// `/*tag: text */` in a script is a comment, and the script covers the whole
// graph (index). With `on`, each one is opened up into its text, which
// narrows the statement it sits in to the rows update is redoing.
fn open_marks(sql: const u8[:], tag: const u8[:], on: bool) -> u8[>..] {
    var out: u8[>..] = [];
    guard on else { out.append(sql); return out; }
    let open = str("/*", tag, ":");
    var at = 0;
    loop {
        let a = find(sql[at..], open);
        guard a >= 0 else { break; }
        out.append(sql[at..at + a]);
        let b = find(sql[at + a..], "*/");
        guard b >= 0 else { abort(str("spread-wings: an unclosed /*", tag, ": in a script")); }
        out.append(sql[at + a + open.len..at + a + b]);
        at = at + a + b + 2;
    }
    out.append(sql[at..]);
    return out;
}

fn open_map(path: const u8[:]) -> i64 {
    var err: u8[>..] = [];
    let db = sqlite::open_existing(path, err);
    guard db != 0 else { abort(str("spread-wings: cannot open ", path, ": ", err)); }
    var have: u8[>..] = [];
    let st = sqlite::prepare(db, "SELECT value FROM meta WHERE key = 'schema'", err);
    if st != 0 {
        if sqlite::step(st, err) == 1 { sqlite::col_text(st, 0, have); }
        sqlite::finalize(st);
    }
    guard have == SCHEMA_NUMBER else {
        abort(str("spread-wings: ", path, " was written by another version of spread-wings (layout ",
                  if have.len > 0 { have[..] } else { "unnumbered" }, ", this one reads ", SCHEMA_NUMBER,
                  "); rebuild it: spread-wings index <repo> ", path));
    }
    return db;
}

fn set_meta(db: i64, key: const u8[:], value: const u8[:]) {
    let st = sqlite::prepare_or_die(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)");
    sqlite::bind_text(st, 1, key);
    sqlite::bind_text(st, 2, value);
    sqlite::step_done(st);
    sqlite::finalize(st);
}

fn get_meta(db: i64, key: const u8[:], out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, "SELECT value FROM meta WHERE key = ?1");
    sqlite::bind_text(st, 1, key);
    var found = false;
    if sqlite::step(st, err) == 1 { sqlite::col_text(st, 0, out); found = true; }
    sqlite::finalize(st);
    return found;
}

// One integer from a query with no parameters.
fn scalar(db: i64, sql: const u8[:]) -> i64 {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, sql);
    var v: i64 = 0;
    if sqlite::step(st, err) == 1 { v = sqlite::col_int(st, 0); }
    sqlite::finalize(st);
    return v;
}
