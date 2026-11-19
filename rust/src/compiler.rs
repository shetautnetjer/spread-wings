// Compiler answers from a Swan map, and what the graph is worth against
// one. From src/compiler.goose and src/score.goose, where the rules are set
// out; the scripts are their own (sql.rs). Swan's map is only read.

use crate::db::Db;
use crate::graph::{call_file_edges, communities};
use crate::sql;
use crate::store::*;
use crate::sys;
use crate::util::*;

fn swan_meta(db: &Db, key: &[u8]) -> Option<Vec<u8>> {
    let mut err = String::new();
    let st = db.prepare_or_die(b"SELECT value FROM sw.meta WHERE key = ?1");
    st.bind_text(1, key);
    if st.step(&mut err) == 1 { Some(st.col_text(0)) } else { None }
}

/// Opens the graph with the Swan map attached as `sw`, after checking that
/// the map is of this code: its root is the graph's root. Gives the
/// database, that root, and when the map's SCIP run was (ns).
fn attach_swan(db_path: &[u8], swan_db: &[u8]) -> (Db, Vec<u8>, i64) {
    if find(swan_db, b"'") >= 0 { die("spread-wings: the Swan map path cannot contain a quote"); }
    if !sys::file_exists(swan_db) { die(&format!("spread-wings: no Swan map at {}", s(swan_db))); }
    let db = open_map(db_path);
    let mut q: Vec<u8> = b"ATTACH DATABASE '".to_vec();
    q.extend_from_slice(swan_db);
    q.extend_from_slice(b"' AS sw");
    db.exec_or_die(&q);
    if db.scalar(b"SELECT COUNT(*) FROM sw.sqlite_master WHERE type = 'table' AND name IN ('meta', 'files', 'symbols', 'occurrences')") != 4 {
        die(&format!("spread-wings: {} is not a Swan map (no meta, files, symbols and occurrences tables)", s(swan_db)));
    }
    // Same code? The roots must match, and the map must say when it was built.
    let root = get_meta(&db, b"root").unwrap_or_default();
    let (sw_root, when) = match (swan_meta(&db, b"root"), swan_meta(&db, b"scip_time")) {
        (Some(r), Some(w)) => (r, w),
        _ => die("spread-wings: the Swan map does not record its root and SCIP time; rebuild it with a current swan"),
    };
    let sw_real = if sw_root.is_empty() || sw_root.len() >= 4096 { sw_root.clone() } else { sys::realpath(&sw_root).unwrap_or_else(|| sw_root.clone()) };
    if sw_real != root {
        die(&format!("spread-wings: the Swan map is of {}, this graph is of {}; map the same folder", s(&sw_root), s(&root)));
    }
    let scip_time = match parse_int(&when) {
        Some(t) if t > 0 => t,
        _ => die("spread-wings: the Swan map's SCIP time is not a number"),
    };
    (db, root, scip_time)
}

/// The files among a query's rows (file id, path, the mtime Swan left on it
/// or -1) that changed after the map's SCIP run, or are gone: Swan itself
/// calls such a file stale. A file Swan edited keeps the mtime Swan left.
fn stale_files(db: &Db, root: &[u8], scip_time: i64, sql: &str) -> Vec<i64> {
    let mut stale: Vec<i64> = Vec::new();
    let mut err = String::new();
    let q = db.prepare_or_die(sql.as_bytes());
    while q.step(&mut err) == 1 {
        let mut p = root.to_vec();
        p.push(b'/');
        p.extend_from_slice(&q.col_text(1));
        let m = if p.len() >= 4096 { -1 } else { sys::mtime_ns(&p) };
        if m < 0 || (m > scip_time && m != q.col_int(2)) { stale.push(q.col_int(0)); }
    }
    stale
}

pub fn compiler_main(db_path: &[u8], swan_db: &[u8]) {
    let (db, root, scip_time) = attach_swan(db_path, swan_db);

    db.exec_or_die(b"BEGIN");
    db.exec_or_die(sql::COMPILER_L96.as_bytes());

    // Files changed since the map's SCIP run: not answered from this map.
    let stale = stale_files(&db, &root, scip_time, sql::COMPILER_L109);
    for id in &stale { db.exec_or_die(format!("DELETE FROM sites WHERE file_id = {}", id).as_bytes()); }
    let skipped = db.scalar(b"SELECT n FROM nsites") - db.scalar(b"SELECT COUNT(*) FROM sites");

    db.exec_or_die(sql::COMPILER_L116.as_bytes());
    let all = db.scalar(b"SELECT n FROM nsites");
    let covered = db.scalar(b"SELECT COUNT(*) FROM (SELECT DISTINCT file_id, row, callee FROM hits)");
    let linked = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target > 0");
    let already = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target > 0 AND had = 1 AND had_right = 1");
    let narrowed = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target > 0 AND had > 1 AND had_right = 1");
    let corrected = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target > 0 AND had > 0 AND had_right = 0");
    let added = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target > 0 AND had = 0");
    let outside = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target = 0");
    let outside_unlinked = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target = 0 AND had > 0");
    let values = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target = -2");
    let values_unlinked = db.scalar(b"SELECT COUNT(*) FROM outcome WHERE target = -2 AND elsewhere > 0");
    db.exec_or_die(b"DROP TABLE sites; DROP TABLE nsites; DROP TABLE gsym; DROP TABLE hits; DROP TABLE verdict; DROP TABLE at_site; DROP TABLE outcome;");
    call_file_edges(&db, false);
    let g100 = parse_int(&get_meta(&db, b"resolution").unwrap_or_default());
    let rounds = communities(&db, match g100 { Some(g) if g > 0 => g as f64 / 100.0, _ => 1.5 });
    set_meta(&db, b"compiler_answers", b"swan");
    db.exec_or_die(b"COMMIT");
    db.exec_or_die(b"DETACH DATABASE sw");
    let note = if !stale.is_empty() {
        format!("; skipped {} in {} files changed since the Swan map was built (refresh the map)", skipped, stale.len())
    } else {
        String::new()
    };
    println!(
        "spread-wings compiler: {} call sites; Swan's map covers {}: {} tied to one definition, {} outside the repo, {} calls of a value the graph does not hold, {} left (unclear){}. Of those tied: {} as they were, {} narrowed from several, {} corrected, {} new. Guessed links removed at {} outside sites and {} value sites; {} communities ({} rounds)",
        all, covered, linked, outside, values, covered - linked - outside - values, note,
        already, narrowed, corrected, added, outside_unlinked, values_unlinked,
        db.scalar(b"SELECT COUNT(*) FROM communities"), rounds
    );
}

fn json_rows(db: &Db, sql: &str, names: &[&str], texts: usize, out: &mut Vec<u8>) {
    let mut err = String::new();
    let q = db.prepare_or_die(sql.as_bytes());
    let mut first = true;
    out.push(b'[');
    while q.step(&mut err) == 1 {
        if !first { out.push(b','); }
        first = false;
        out.extend_from_slice(b"\n    {");
        for k in 0..names.len() {
            if k > 0 { out.extend_from_slice(b", "); }
            out.push(b'"');
            out.extend_from_slice(names[k].as_bytes());
            out.extend_from_slice(b"\": ");
            if k < texts {
                out.push(b'"');
                for c in q.col_text(k as i32) {
                    if c == b'"' || c == b'\\' { out.push(b'\\'); out.push(c); } else if c >= b' ' { out.push(c); }
                }
                out.push(b'"');
            } else {
                push_int(out, q.col_int(k as i32));
            }
        }
        out.push(b'}');
    }
    out.extend_from_slice(if first { b"]" as &[u8] } else { b"\n  ]" });
}

/// What the graph's definitions and links are worth against a Swan map.
pub fn score_main(db_path: &[u8], swan_db: &[u8]) {
    use std::io::Write;
    let (db, root, scip_time) = attach_swan(db_path, swan_db);
    if db.scalar(b"SELECT COUNT(*) FROM pragma_table_info('symbols', 'sw') WHERE name IN ('kind', 'language', 'def_file', 'def_line', 'in_repo')") != 5 {
        die("spread-wings: the Swan map's symbols have no kind and language; rebuild it with a current swan");
    }

    let stale = stale_files(&db, &root, scip_time, sql::SCORE_L70);
    db.exec_or_die(b"CREATE TEMP TABLE stale (file_id INTEGER PRIMARY KEY, path TEXT)");
    for id in &stale { db.exec_or_die(format!("INSERT INTO stale SELECT id, path FROM files WHERE id = {}", id).as_bytes()); }

    db.exec_or_die(sql::SCORE_L77.as_bytes());

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"{\n  \"root\": \"");
    out.extend_from_slice(&root);
    out.extend_from_slice(format!("\",\n  \"files_changed_since_the_map\": {},\n  \"links\": ", stale.len()).as_bytes());
    json_rows(&db, sql::SCORE_L115, &["language", "rule", "links", "judged", "right", "other_file", "outside", "calls_judged", "calls_with_the_right_link"], 2, &mut out);
    out.extend_from_slice(b",\n  \"definitions\": ");
    // Swan names a constructor `<constructor>` (Java: `<init>`) and an
    // accessor `<get>size`; the graph `constructor` and `size`.
    json_rows(&db, sql::SCORE_L128, &["language", "kind", "in_swan", "in_graph"], 2, &mut out);
    out.extend_from_slice(b",\n  \"called\": ");
    json_rows(&db, sql::SCORE_L142, &["language", "kind", "in_swan", "in_graph"], 2, &mut out);
    out.extend_from_slice(b"\n}\n");
    let _ = std::io::stdout().write_all(&out);
    db.exec_or_die(b"DROP TABLE stale; DROP TABLE gdefs; DROP TABLE judged; DROP TABLE reached;");
    db.exec_or_die(b"DETACH DATABASE sw");
}
