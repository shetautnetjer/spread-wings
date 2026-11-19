// The graph lives in one SQLite file. Facts come straight from the parser
// (files, definitions, imports, call sites); edges are derived from them by
// name and say so (`by_name`, with a weight when a name has several
// definitions).
//
// The layout itself (SCHEMA) is in sql.rs.

use crate::db::Db;
use crate::sql;
use crate::util::*;

pub fn open_fresh(path: &[u8]) -> Db {
    for tail in ["", "-wal", "-shm"] {
        let mut p = path.to_vec();
        p.extend_from_slice(tail.as_bytes());
        let _ = std::fs::remove_file(crate::sys::path(&p));
    }
    let db = match Db::open(path) {
        Ok(d) => d,
        Err(e) => die(&format!("spread-wings: cannot create {}: {}", s(path), e)),
    };
    db.exec_or_die(sql::SCHEMA.as_bytes());
    db
}

// The number of this file's layout (the tables and columns in SCHEMA). It
// goes up whenever they change; a graph written with another number is
// rebuilt, not read: indexing takes seconds, and a command that met a
// missing column used to stop with a raw SQL error.
pub const SCHEMA_NUMBER: &str = "8";

// The number of what index writes for a given repo: the readers, the
// patterns and the link rules. It goes up whenever a change to any of them
// gives some repo another graph. `update` redoes only what a changed file
// reaches, so a graph it left half under the old rules and half under the
// new would be neither: a graph written under another number is rebuilt
// whole. (tests/test.sh holds the fixtures' graphs to this number: when
// they change and it has not, a check fails and says to raise it.)
pub const RULES_NUMBER: &str = "1";

/// `/*tag: text */` in a script is a comment, and the script covers the whole
/// graph (index). With `on`, each one is opened up into its text, which
/// narrows the statement it sits in to the rows update is redoing.
pub fn open_marks(sql: &[u8], tag: &[u8], on: bool) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    if !on { out.extend_from_slice(sql); return out; }
    let mut open: Vec<u8> = b"/*".to_vec();
    open.extend_from_slice(tag);
    open.push(b':');
    let mut at = 0usize;
    loop {
        let a = find(&sql[at..], &open);
        if a < 0 { break; }
        let a = a as usize;
        out.extend_from_slice(&sql[at..at + a]);
        let b = find(&sql[at + a..], b"*/");
        if b < 0 { die(&format!("spread-wings: an unclosed /*{}: in a script", s(tag))); }
        let b = b as usize;
        out.extend_from_slice(&sql[at + a + open.len()..at + a + b]);
        at = at + a + b + 2;
    }
    out.extend_from_slice(&sql[at..]);
    out
}

pub fn open_map(path: &[u8]) -> Db {
    let db = match Db::open_existing(path) {
        Ok(d) => d,
        Err(e) => die(&format!("spread-wings: cannot open {}: {}", s(path), e)),
    };
    let mut have: Vec<u8> = Vec::new();
    if let Ok(st) = db.prepare(b"SELECT value FROM meta WHERE key = 'schema'") {
        let mut err = String::new();
        if st.step(&mut err) == 1 { have = st.col_text(0); }
    }
    if have != SCHEMA_NUMBER.as_bytes() {
        die(&format!(
            "spread-wings: {} was written by another version of spread-wings (layout {}, this one reads {}); rebuild it: spread-wings index <repo> {}",
            s(path), if !have.is_empty() { s(&have) } else { "unnumbered".to_string() }, SCHEMA_NUMBER, s(path)
        ));
    }
    db
}

pub fn set_meta(db: &Db, key: &[u8], value: &[u8]) {
    let st = db.prepare_or_die(b"INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)");
    st.bind_text(1, key);
    st.bind_text(2, value);
    st.step_done();
}

pub fn get_meta(db: &Db, key: &[u8]) -> Option<Vec<u8>> {
    let st = db.prepare_or_die(b"SELECT value FROM meta WHERE key = ?1");
    st.bind_text(1, key);
    let mut err = String::new();
    if st.step(&mut err) == 1 { Some(st.col_text(0)) } else { None }
}
