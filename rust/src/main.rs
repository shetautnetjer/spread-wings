// Spread-Wings in Rust: a trial port of the Goose program, held to the same
// graph and the same checks (docs/rust-port.md). The commands, their
// arguments and their answers are those of src/spread-wings.goose.

mod compiler;
mod db;
mod decide;
mod extract;
mod graph;
mod query;
mod run;
mod serve;
mod sql;
mod store;
mod survey;
mod sys;
mod treedefs;
mod ts;
mod update;
mod util;
mod watch;

use std::io::Write;
use util::*;

/// "1.25" -> 1.25, by the Goose program's own steps (so that a resolution
/// reads as the same number in both).
fn parse_decimal(s: &[u8]) -> Option<f64> {
    let dot = find(s, b".");
    let whole = parse_int(if dot >= 0 { &s[..dot as usize] } else { s })?;
    let mut v = whole as f64;
    if dot >= 0 {
        let mut scale = 0.1;
        for &c in &s[dot as usize + 1..] {
            if !c.is_ascii_digit() { return None; }
            v = v + (c - b'0') as f64 * scale;
            scale = scale / 10.0;
        }
    }
    Some(v)
}

fn usage() -> ! {
    let t = sql::SPREAD_WINGS_L50;
    let t = t.strip_prefix('\n').unwrap_or(t);
    let t = t.strip_suffix('\n').unwrap_or(t);
    let _ = std::io::stderr().write_all(t.as_bytes());
    std::process::exit(2);
}

fn resolution(a: &[u8]) -> f64 {
    match parse_decimal(a) {
        Some(g) if g > 0.0 && g <= 10.0 => g,
        _ => die("spread-wings: --resolution needs a number between 0 and 10"),
    }
}

fn main() {
    // A reader that goes away ends the program at its next line, as it ends
    // the Goose one (Rust would otherwise carry on writing to nobody: a
    // watcher whose reader has gone must not stay).
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL); }
    let a: Vec<Vec<u8>> = std::env::args_os().map(std::os::unix::ffi::OsStringExt::into_vec).collect();
    if a.len() < 3 { usage(); }
    let cmd = &a[1][..];
    if cmd == b"index" && (a.len() == 4 || (a.len() == 6 && a[4] == b"--resolution")) {
        // (measured: on a test-heavy repo, 1.5 splits code into its modules)
        let gamma = if a.len() == 6 { resolution(&a[5]) } else { 1.5 };
        run::index_main(&a[2], &a[3], gamma);
        return;
    }
    if cmd == b"facts" && a.len() == 4 {
        // A stage of the port, not a command of the Goose program: the facts alone.
        let repo = run::abs_dir(&a[2]);
        let db = store::open_fresh(&a[3]);
        db.exec_or_die(b"BEGIN");
        let n = extract::extract_repo(&db, &repo);
        db.exec_or_die(b"COMMIT");
        println!("{} files", n);
        return;
    }
    if cmd == b"update" && (a.len() == 4 || (a.len() == 6 && a[4] == b"--resolution")) {
        // (0: as the graph was built)
        let gamma = if a.len() == 6 { resolution(&a[5]) } else { 0.0 };
        run::update_main(&a[2], &a[3], gamma);
        return;
    }
    if cmd == b"serve" && a.len() == 3 { serve::serve_main(&a[2]); return; }
    if cmd == b"compiler" && a.len() == 4 {
        compiler::compiler_main(&a[2], &a[3]);
        return;
    }
    if cmd == b"compiler" && a.len() == 6 && a[4] == b"--into" {
        run::copy_graph(&a[2], &a[5]);
        compiler::compiler_main(&a[5], &a[3]);
        return;
    }
    if cmd == b"watch" && (a.len() == 4 || (a.len() == 6 && a[4] == b"--every")) {
        let mut every: i64 = 30;
        if a.len() == 6 {
            every = match parse_int(&a[5]) {
                Some(v) if v >= 1 && v <= 86400 => v,
                _ => die("spread-wings: --every needs a number of seconds, 1 to 86400"),
            };
        }
        run::watch_main(&a[2], &a[3], 0.0, every);
        return;
    }
    if cmd == b"decide-apply" && a.len() == 3 {
        decide::decide_apply_main(&a[2]);
        return;
    }
    if cmd == b"survey" && a.len() == 3 {
        survey::survey_main(&a[2]);
        return;
    }
    if cmd == b"score" && a.len() == 4 {
        compiler::score_main(&a[2], &a[3]);
        return;
    }
    if cmd == b"decide" {
        let mut maxq: i64 = 5000;
        let mut workers: i64 = 32;
        let mut k = 3;
        while k + 1 < a.len() {
            let v = match parse_int(&a[k + 1]) { Some(v) if v > 0 => v, _ => usage() };
            if a[k] == b"--max" { maxq = v; } else if a[k] == b"--workers" { workers = v.min(128); } else { usage(); }
            k += 2;
        }
        if k != a.len() { usage(); }
        decide::decide_main(&a[2], maxq, workers);
        return;
    }
    let db = store::open_map(&a[2]);
    let mut out: Vec<u8> = Vec::new();
    let mut ok = true;
    if cmd == b"overview" && a.len() == 3 { query::overview(&db, &mut out); }
    else if cmd == b"find" && a.len() == 4 { query::find_defs(&db, &a[3], &mut out); }
    else if cmd == b"neighbors" && a.len() == 4 { ok = query::neighbors(&db, &a[3], &mut out); }
    else if cmd == b"callers" && a.len() == 4 { query::callers(&db, &a[3], &mut out); }
    else if cmd == b"touches" && (a.len() == 4 || a.len() == 5) { ok = query::touches(&db, &a[3], if a.len() == 5 { &a[4] } else { b"" }, &mut out); }
    else { usage(); }
    drop(db);
    out.push(b'\n');
    if ok { let _ = std::io::stdout().write_all(&out); } else { let _ = std::io::stderr().write_all(&out); std::process::exit(1); }
}
