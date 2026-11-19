// The commands that build a graph and keep it: index, update, watch, and
// the copy `compiler --into` works on. From src/spread-wings.goose.

use crate::extract::extract_repo;
use crate::graph::{communities, link_calls, link_imports};
use crate::serve::VERSION;
use crate::store::*;
use crate::sys;
use crate::util::*;
use std::time::Instant;

pub fn abs_dir(p: &[u8]) -> Vec<u8> {
    match sys::realpath(p) {
        Some(d) => d,
        None => die(&format!("spread-wings: no such directory: {}", s(p))),
    }
}

/// gamma as the graph keeps it: hundredths, rounded.
pub fn gamma100(gamma: f64) -> Vec<u8> {
    ((gamma * 100.0 + 0.5) as i64).to_string().into_bytes()
}

/// Builds the graph of repo (an absolute path) whole, and gives the line
/// that says what it holds.
pub fn index_run(repo: &[u8], db_path: &[u8], gamma: f64) -> Vec<u8> {
    let t0 = Instant::now();
    let db = open_fresh(db_path);
    db.exec_or_die(b"BEGIN");
    let n = extract_repo(&db, repo);
    let t1 = Instant::now();
    let imports = link_imports(&db, false);
    link_calls(&db, false);
    let rounds = communities(&db, gamma);
    set_meta(&db, b"root", repo);
    set_meta(&db, b"version", VERSION.as_bytes());
    set_meta(&db, b"schema", SCHEMA_NUMBER.as_bytes());
    set_meta(&db, b"rules", RULES_NUMBER.as_bytes());
    set_meta(&db, b"resolution", &gamma100(gamma));
    db.exec_or_die(b"COMMIT");
    let t2 = Instant::now();
    let mut line: Vec<u8> = Vec::new();
    line.extend_from_slice(
        format!(
            "spread-wings: {} files, {} definitions, {} call sites, {} imports linked, {} call links, {} communities ({} rounds); parse {} ms, link {} ms -> ",
            n,
            db.scalar(b"SELECT COUNT(*) FROM symbols"),
            db.scalar(b"SELECT COUNT(*) FROM calls"),
            imports,
            db.scalar(b"SELECT COUNT(*) FROM call_edges"),
            db.scalar(b"SELECT COUNT(*) FROM communities"),
            rounds,
            (t1 - t0).as_millis(),
            (t2 - t1).as_millis()
        )
        .as_bytes(),
    );
    line.extend_from_slice(db_path);
    line
}

pub fn index_main(repo_arg: &[u8], db_path: &[u8], gamma: f64) {
    let repo = abs_dir(repo_arg);
    if !sys::is_dir(&repo) { die(&format!("spread-wings: not a directory: {}", s(&repo))); }
    let mut line = index_run(&repo, db_path, gamma);
    line.push(b'\n');
    use std::io::Write;
    let _ = std::io::stdout().write_all(&line);
}
