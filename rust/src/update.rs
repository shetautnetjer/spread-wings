// `update`: the graph `index` would build now, reached from the one that is
// there, by reading only the files that changed and tying again only the
// calls they reach. From src/update.goose, where the reasoning is set out
// beside each script; the scripts are its own (sql.rs).

use crate::db::Db;
use crate::extract::*;
use crate::graph::{communities, link_calls, link_imports, roots_text};
use crate::query::jtext;
use crate::sql;
use crate::sys;
use std::time::Instant;

fn add(out: &mut Vec<u8>, s: &str) { out.extend_from_slice(s.as_bytes()); }

/// A JSON array of the first column of `sql`, as strings.
fn json_texts(db: &Db, sql: &str, out: &mut Vec<u8>) {
    let mut err = String::new();
    let st = db.prepare_or_die(sql.as_bytes());
    out.push(b'[');
    let mut first = true;
    while st.step(&mut err) == 1 {
        if !first { out.push(b','); }
        first = false;
        jtext(out, &st.col_text(0));
    }
    out.push(b']');
}

/// Brings the graph in db (of repo, an absolute path; inside a transaction)
/// up to date, and appends what it did to out as the members of a JSON
/// object. regroup: the communities are wanted at another resolution than
/// the graph has, so they are found again even when no file changed.
/// True when a file changed, was added or is gone.
pub fn update_graph(db: &Db, repo: &[u8], gamma: f64, regroup: bool, out: &mut Vec<u8>) -> bool {
    let now = sys::time_ns();
    let t0 = Instant::now();
    let mut all_paths: Vec<Vec<u8>> = Vec::new();
    let mut all_langs: Vec<&'static str> = Vec::new();
    let mut walked: Vec<Vec<u8>> = Vec::new();
    let n = walk_repo(repo, &mut all_paths, &mut all_langs, &mut walked) as usize;
    let mut sizes: Vec<i64> = Vec::new();
    let mut mtimes: Vec<i64> = Vec::new();
    let mut ctimes: Vec<i64> = Vec::new();
    stat_files(&all_paths, n, &mut sizes, &mut mtimes, &mut ctimes);

    db.exec_or_die(sql::UPDATE_L317.as_bytes());
    {
        let ins_walk = db.prepare_or_die(b"INSERT INTO temp.u_walk (ord, path, lang, size, mtime, ctime) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
        for i in 0..n {
            ins_walk.reset();
            ins_walk.bind_int(1, i as i64);
            ins_walk.bind_text(2, &all_paths[i][repo.len() + 1..]);
            ins_walk.bind_text(3, all_langs[i].as_bytes());
            ins_walk.bind_int(4, sizes[i]);
            ins_walk.bind_int(5, mtimes[i]);
            ins_walk.bind_int(6, ctimes[i]);
            ins_walk.step_done();
        }
    }

    // Each file of the walk: its row (0 until it has one), and, when it has
    // to be looked at, the hash index last saw. A file is looked at when it
    // is new, or its size or a time is not what its stamp says, or its
    // stamp kept no times.
    let mut pids: Vec<i64> = vec![0; n];
    let mut old: Vec<Option<i64>> = vec![None; n];
    let mut is_new: Vec<bool> = vec![false; n];
    let mut which: Vec<usize> = Vec::new();
    let mut err = String::new();
    {
        let q = db.prepare_or_die(sql::UPDATE_L357.as_bytes());
        while q.step(&mut err) == 1 {
            let i = q.col_int(0) as usize;
            pids[i] = q.col_int(1);
            if q.col_int(4) != 0 {
                which.push(i);
                if q.col_int(2) != 0 { old[i] = Some(q.col_int(3)); }
            }
        }
    }
    db.exec_or_die(b"INSERT INTO temp.u_gone SELECT id, path FROM files WHERE path NOT IN (SELECT path FROM temp.u_walk)");
    let gone = db.scalar(b"SELECT COUNT(*) FROM temp.u_gone");
    let added = pids.iter().filter(|&&p| p == 0).count();
    // (Before the new files have rows: the top-level names as they were.)
    let set_changed = added > 0 || gone > 0;
    let roots_before: Vec<u8> = if set_changed { roots_text(db) } else { Vec::new() };
    {
        let ins_file = db.prepare_or_die(b"INSERT INTO files (path, lang, dir) VALUES (?1, ?2, ?3)");
        for i in 0..n {
            if pids[i] == 0 {
                pids[i] = insert_file(db, &ins_file, &all_paths[i][repo.len() + 1..], all_langs[i]);
                is_new[i] = true;
                which.push(i);
            }
        }
    }
    which.sort();

    let parsed = parse_files(&all_paths, &all_langs, n, &which, &old);
    // read again: its content is new, or it is new
    let changed: Vec<usize> = which.iter().copied().filter(|&i| !parsed[i].same).collect();

    {
        let ins_stamp = db.prepare_or_die(b"INSERT OR REPLACE INTO stamps (file_id, ord, size, mtime, ctime, hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
        for &i in &which { put_stamp(&ins_stamp, pids[i], i as i64, sizes[i], mtimes[i], ctimes[i], parsed[i].hash, now); }
    }

    let calls_before = db.scalar(b"SELECT COUNT(*) FROM calls");
    if changed.is_empty() && gone == 0 {
        if regroup { communities(db, gamma); }
        add(out, &format!(
            "\"files\":{},\"looked_at\":{},\"changed\":[],\"added\":[],\"removed\":[],\"calls\":{},\"calls_tied_again\":0,\"all_calls_tied_again\":false,\"files_with_calls_tied_again\":[],\"files_grouped_again\":{},\"reaches_files\":0,\"reaches\":[],\"tests\":[],\"read_ms\":{},\"link_ms\":0",
            n, which.len(), calls_before, if regroup { "true" } else { "false" }, t0.elapsed().as_millis()
        ));
        return false;
    }

    {
        let ins_ch = db.prepare_or_die(b"INSERT INTO temp.u_changed (id) VALUES (?1)");
        let ins_ad = db.prepare_or_die(b"INSERT INTO temp.u_added (id) VALUES (?1)");
        for &i in &changed {
            ins_ch.reset();
            ins_ch.bind_int(1, pids[i]);
            ins_ch.step_done();
            if is_new[i] {
                ins_ad.reset();
                ins_ad.bind_int(1, pids[i]);
                ins_ad.step_done();
            }
        }
    }

    db.exec_or_die(b"INSERT INTO temp.u_set SELECT id FROM temp.u_changed UNION SELECT id FROM temp.u_gone");
    db.exec_or_die(sql::KEEP_OLD_SQL.as_bytes());
    db.exec_or_die(sql::IMPORTED_FILES_SQL.as_bytes());
    if set_changed { db.exec_or_die(sql::UPDATE_L434.as_bytes()); }
    // A definition's new row never takes the number of a row just removed
    // (a row with the highest number holds the place meanwhile): a link
    // that still carries a removed row's number then names no row at all,
    // and DIRTY_SQL finds it, where it would otherwise name a stranger.
    let sym_top = db.scalar(b"SELECT COALESCE(MAX(id), 0) FROM symbols");
    // (The file links about to be redone, as they are: see FILE_LINKS_SAME_SQL.)
    db.exec_or_die(b"CREATE TEMP TABLE u_fe AS SELECT src, dst, kind, weight FROM file_edges WHERE src IN (SELECT id FROM temp.u_set)");
    db.exec_or_die(sql::DROP_ROWS_SQL.as_bytes());
    if sym_top > 0 { db.exec_or_die(format!("INSERT OR IGNORE INTO symbols (id, file_id) VALUES ({}, 0)", sym_top).as_bytes()); }
    write_facts(db, &pids, &all_langs, &changed, &parsed);
    db.exec_or_die(b"DELETE FROM symbols WHERE file_id = 0 AND name IS NULL");
    settle_facts(db, true);
    if set_changed {
        // Every file's place in the walk: a file added or removed moves the rest.
        db.exec_or_die(sql::UPDATE_L455.as_bytes());
    }
    let t1 = Instant::now();

    db.exec_or_die(sql::COMPARE_SQL.as_bytes());
    let mut all_again = false;
    if set_changed {
        // Which file an import names hangs on which files there are.
        db.exec_or_die(b"UPDATE imports SET dst = NULL WHERE dst IS NOT NULL; DELETE FROM aliases; DELETE FROM file_edges WHERE kind = 'import';");
        link_imports(db, false);
        db.exec_or_die(sql::IMPORTED_FILES_SQL.as_bytes());
        db.exec_or_die(sql::REIMPORTED_SQL.as_bytes());
        all_again = roots_text(db) != roots_before;
    } else {
        link_imports(db, true);
        db.exec_or_die(sql::IMPORTED_FILES_SQL.as_bytes());
    }
    db.exec_or_die(sql::COMPARE_IMPORTS_SQL.as_bytes());
    db.exec_or_die(sql::IMPORT_NAMES_SQL.as_bytes());
    db.exec_or_die(sql::MOVE_LINKS_SQL.as_bytes());

    let mut regrouped = true;
    if !all_again {
        db.exec_or_die(sql::DIRTY_SQL.as_bytes());
        // Past two calls in five, tying them all is the quicker way to the
        // same links.
        all_again = db.scalar(b"SELECT COUNT(*) FROM temp.dirty") * 5 > db.scalar(b"SELECT COUNT(*) FROM calls") * 2;
    }
    if all_again {
        db.exec_or_die(b"DELETE FROM call_edges; DELETE FROM file_edges WHERE kind = 'call'; UPDATE calls SET note = NULL WHERE note IS NOT NULL;");
        link_calls(db, false);
    } else {
        db.exec_or_die(sql::UPDATE_L491.as_bytes());
        link_calls(db, true);
        // The groups come from the files and the links between them. With
        // the same files and every link between them as it was (the usual
        // case: a change inside a function), they are as they were.
        regrouped = regroup || set_changed || db.scalar(sql::FILE_LINKS_SAME_SQL.as_bytes()) != 0;
    }
    if regrouped { communities(db, gamma); }
    db.exec_or_die(sql::REACH_SQL.as_bytes());
    let t2 = Instant::now();

    let calls_now = db.scalar(b"SELECT COUNT(*) FROM calls");
    add(out, &format!("\"files\":{},\"looked_at\":{},\"changed\":", n, which.len()));
    json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.u_changed) AND id NOT IN (SELECT id FROM temp.u_added) ORDER BY path", out);
    add(out, ",\"added\":");
    json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.u_added) ORDER BY path", out);
    add(out, ",\"removed\":");
    json_texts(db, "SELECT path FROM temp.u_gone ORDER BY path", out);
    add(out, &format!(
        ",\"calls\":{},\"calls_tied_again\":{},\"all_calls_tied_again\":{},\"files_with_calls_tied_again\":",
        calls_now,
        if all_again { calls_now } else { db.scalar(b"SELECT COUNT(*) FROM temp.dirty") },
        if all_again { "true" } else { "false" }
    ));
    if all_again { add(out, "[]"); }
    else { json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.dirty_files) ORDER BY path", out); }
    // What the change reaches (at most 200 named; reaches_files counts them all).
    add(out, &format!(
        ",\"files_grouped_again\":{},\"reaches_files\":{},\"reaches\":",
        if regrouped { "true" } else { "false" },
        db.scalar(b"SELECT COUNT(*) FROM temp.u_reach")
    ));
    json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.u_reach) ORDER BY path LIMIT 200", out);
    add(out, ",\"tests\":");
    json_texts(db, sql::UPDATE_L523, out);
    add(out, &format!(",\"read_ms\":{},\"link_ms\":{}", (t1 - t0).as_millis(), (t2 - t1).as_millis()));
    true
}
