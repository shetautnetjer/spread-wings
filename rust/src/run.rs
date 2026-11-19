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

/// `update`: the graph index would build now, reached from the one that is
/// there. gamma_arg 0: the resolution the graph was built with. When the
/// graph cannot be brought up to date (none there; another layout or other
/// rules; another folder's; one holding answers from `compiler` or `decide`,
/// which sit on links update would redo), it is built whole, and the answer
/// says why. The answer, one JSON object, is appended to out; true when the
/// graph is not what it was (a file changed, or it was built whole).
pub fn update_run(repo: &[u8], db_path: &[u8], gamma_arg: f64, out: &mut Vec<u8>) -> bool {
    use crate::db::Db;
    use crate::query::jstr;
    let mut why: Vec<u8> = Vec::new();
    let mut gamma = if gamma_arg > 0.0 { gamma_arg } else { 1.5 };
    let mut regroup = false;
    let mut db: Option<Db> = None;
    if !sys::file_exists(db_path) {
        why.extend_from_slice(b"no graph was there");
    } else {
        let d = match Db::open_existing(db_path) {
            Ok(d) => d,
            Err(e) => die(&format!("spread-wings: cannot open {}: {}", s(db_path), e)),
        };
        if d.scalar(b"SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'") != 1 {
            die(&format!("spread-wings: {} is not a spread-wings graph", s(db_path)));
        }
        let v = get_meta(&d, b"schema").unwrap_or_default();
        if v != SCHEMA_NUMBER.as_bytes() { why.extend_from_slice(b"the graph there was written by another version of spread-wings"); }
        if why.is_empty() {
            let v = get_meta(&d, b"rules").unwrap_or_default();
            if v != RULES_NUMBER.as_bytes() { why.extend_from_slice(b"the graph there was built under other rules (another spread-wings)"); }
        }
        if why.is_empty() {
            let v = get_meta(&d, b"root").unwrap_or_default();
            if v != repo { why.extend_from_slice(b"the graph there was of "); why.extend_from_slice(&v); }
        }
        if why.is_empty() {
            if get_meta(&d, b"compiler_answers").is_some() {
                why.extend_from_slice(b"the graph there held answers from `compiler`, which update cannot keep: run compiler again");
            } else if get_meta(&d, b"decided_with").is_some() || d.scalar(b"SELECT COUNT(*) FROM decisions") > 0 {
                why.extend_from_slice(b"the graph there held answers from `decide`, which update cannot keep: run decide again");
            }
        }
        if why.is_empty() {
            let v = get_meta(&d, b"resolution").unwrap_or_default();
            let g100 = parse_int(&v);
            if gamma_arg <= 0.0 {
                if let Some(g) = g100 { if g > 0 { gamma = g as f64 / 100.0; } }
            } else {
                regroup = match g100 { Some(g) => g != (gamma * 100.0 + 0.5) as i64, None => true };
            }
        }
        db = Some(d);
    }
    let mut changed = true;
    out.push(b'{');
    jstr(out, "root", repo);
    if !why.is_empty() {
        drop(db);
        let line = index_run(repo, db_path, gamma);
        out.extend_from_slice(b",\"built_whole\":true,");
        jstr(out, "why", &why);
        out.push(b',');
        jstr(out, "index", &line);
    } else if let Some(db) = db {
        // One writer at a time: a second update of the same graph waits for
        // the first (ten seconds at most) and then finds its work done.
        db.exec_or_die(b"PRAGMA busy_timeout = 10000; BEGIN IMMEDIATE");
        out.extend_from_slice(b",\"built_whole\":false,");
        changed = crate::update::update_graph(&db, repo, gamma, regroup, out);
        set_meta(&db, b"resolution", &gamma100(gamma));
        db.exec_or_die(b"COMMIT");
    }
    out.push(b'}');
    changed
}

pub fn update_main(repo_arg: &[u8], db_path: &[u8], gamma_arg: f64) {
    use std::io::Write;
    let repo = abs_dir(repo_arg);
    if !sys::is_dir(&repo) { die(&format!("spread-wings: not a directory: {}", s(&repo))); }
    let mut out: Vec<u8> = Vec::new();
    update_run(&repo, db_path, gamma_arg, &mut out);
    out.push(b'\n');
    let _ = std::io::stdout().write_all(&out);
}

/// `watch`: stays awake and keeps the graph up to date. It sleeps until a
/// file event comes from one of the repo's folders (or `every` seconds
/// pass), lets the writing settle (until 200 ms pass with no event, two
/// seconds at most), and runs `update`. Each update that changed the graph
/// is one line on standard output; the first line comes when the graph is
/// up to date, changed or not, so a reader knows the watcher is ready.
/// The events only wake it: what changed is found by update. It ends when
/// the process that started it ends.
pub fn watch_main(repo_arg: &[u8], db_path: &[u8], gamma_arg: f64, every: i64) {
    use crate::watch;
    use std::io::Write;
    let repo = abs_dir(repo_arg);
    if !sys::is_dir(&repo) { die(&format!("spread-wings: not a directory: {}", s(&repo))); }
    let fd = watch::open();
    let mut events = fd >= 0;
    let mut first = true;
    loop {
        // The folders to watch, before the look: what is written while
        // update runs is then an event for the next round.
        if events {
            let mut paths: Vec<Vec<u8>> = Vec::new();
            let mut langs: Vec<&'static str> = Vec::new();
            let mut dirs: Vec<Vec<u8>> = Vec::new();
            crate::extract::walk_repo(&repo, &mut paths, &mut langs, &mut dirs);
            for d in &dirs {
                if !d.is_empty() && events && watch::add(fd, d) < 0 { events = false; }
            }
        }
        let mut out: Vec<u8> = Vec::new();
        let changed = update_run(&repo, db_path, if first { gamma_arg } else { 0.0 }, &mut out);
        if first || changed {
            let mut line: Vec<u8> = Vec::new();
            line.extend_from_slice(b"{\"watching\":");
            line.extend_from_slice(if events { b"\"file events\"" as &[u8] } else { b"\"a look every 2 seconds\"" });
            line.push(b',');
            line.extend_from_slice(&out[1..]);
            line.push(b'\n');
            let mut so = std::io::stdout();
            let _ = so.write_all(&line);
            let _ = so.flush();
        }
        first = false;
        if events {
            let r = watch::wait(fd, every * 1000);
            if r < 0 { events = false; }
            if r > 0 {
                let t = Instant::now();
                while t.elapsed().as_secs_f64() < 2.0 && watch::wait(fd, 200) > 0 {}
            }
        } else {
            std::thread::sleep(std::time::Duration::from_millis(2000));
        }
    }
}

/// A copy of a graph, for `compiler --into`: the graph as its last finished
/// write left it, read while a watcher may be writing the next.
pub fn copy_graph(from: &[u8], to: &[u8]) {
    use crate::db::Db;
    if find(to, b"'") >= 0 { die("spread-wings: the path of the copy cannot contain a quote"); }
    if from == to { die("spread-wings: --into names the graph itself"); }
    {
        let db = open_map(from);
        for tail in ["", "-wal", "-shm"] {
            let mut p = to.to_vec();
            p.extend_from_slice(tail.as_bytes());
            let _ = std::fs::remove_file(sys::path(&p));
        }
        let mut q: Vec<u8> = b"PRAGMA busy_timeout = 10000; VACUUM INTO '".to_vec();
        q.extend_from_slice(to);
        q.push(b'\'');
        db.exec_or_die(&q);
    }
    let c = match Db::open_existing(to) {
        Ok(c) => c,
        Err(e) => die(&format!("spread-wings: cannot write {}: {}", s(to), e)),
    };
    c.exec_or_die(b"PRAGMA journal_mode = WAL");
}
