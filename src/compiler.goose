// Compiler answers from a Swan map. Swan's indexers (scip-python,
// scip-typescript, rust-analyzer, ...) resolve each use of a name to the
// definition the compiler sees. For every call still tied only by name,
// take that answer when Swan has one at the same file and line:
//   all uses there resolve outside the repo  -> the guessed links go;
//   they resolve to exactly one repo definition -> it becomes the only
//                                               link, resolution `compiler`.
// Anything Swan doesn't cover, or covers ambiguously, stays as it was, for
// `decide` or a reader. Swan's map is only read.
//
// A `compiler` link is the strongest claim this graph makes, so the map has
// to be of this code:
//   - the map's root must be the graph's root (else: an error);
//   - a file changed after the map's SCIP run (or gone) is skipped, the way
//     Swan itself calls such a file stale: its line numbers may have moved,
//     and the match is by line;
//   - a line with several calls of one name is taken only when the compiler
//     answered at least as many uses there as there are calls. One answer
//     must not speak for a second call it never saw.

import std;
import sqlite;
import .store;
import .graph;

// sw_realpath is declared in spread-wings.goose.
extern fn sw_mtime_ns(path: const u8[:]) -> i64;

fn swan_meta(db: i64, key: const u8[:], out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, "SELECT value FROM sw.meta WHERE key = ?1");
    sqlite::bind_text(st, 1, key);
    var found = false;
    if sqlite::step(st, err) == 1 { sqlite::col_text(st, 0, out); found = true; }
    sqlite::finalize(st);
    return found;
}

fn compiler_main(db_path: const u8[:], swan_db: const u8[:]) {
    guard find(swan_db, "'") < 0 else { abort("spread-wings: the Swan map path cannot contain a quote"); }
    guard file_exists(swan_db) else { abort(str("spread-wings: no Swan map at ", swan_db)); }
    let db = open_map(db_path);
    sqlite::exec_or_die(db, str("ATTACH DATABASE '", swan_db, "' AS sw"));
    guard scalar(db, "SELECT COUNT(*) FROM sw.sqlite_master WHERE type = 'table' AND name IN ('meta', 'files', 'symbols', 'occurrences')") == 4 else {
        abort(str("spread-wings: ", swan_db, " is not a Swan map (no meta, files, symbols and occurrences tables)"));
    }

    // Same code? The roots must match, and the map must say when it was built.
    var root: u8[>..] = [];
    get_meta(db, "root", root);
    var sw_root: u8[>..] = [];
    var sw_real: u8[>..] = [];
    var when: u8[>..] = [];
    guard swan_meta(db, "root", sw_root) && swan_meta(db, "scip_time", when) else {
        abort("spread-wings: the Swan map does not record its root and SCIP time; rebuild it with a current swan");
    }
    if !sw_realpath(sw_root, sw_real) { sw_real.append(sw_root); }
    guard sw_real == root else {
        abort(str("spread-wings: the Swan map is of ", sw_root, ", this graph is of ", root, "; map the same folder"));
    }
    let scip_time, when_ok = parse_int(when);
    guard when_ok && scip_time > 0 else { abort("spread-wings: the Swan map's SCIP time is not a number"); }

    sqlite::exec_or_die(db, "BEGIN");
    sqlite::exec_or_die(db, """
        CREATE TEMP TABLE sites AS
            SELECT e.file_id, e.row, t.name AS callee, f.path, MIN(e.caller) AS caller
            FROM call_edges e JOIN symbols t ON t.id = e.callee JOIN files f ON f.id = e.file_id
            WHERE e.resolution = 'by_name'
            GROUP BY e.file_id, e.row, t.name;
        CREATE TEMP TABLE nsites AS SELECT COUNT(*) AS n FROM sites;
    """);

    // Files changed since the map's SCIP run: not answered from this map.
    // A file Swan edited itself keeps the mtime Swan left on it.
    var stale: i64[>..] = [];
    var err: u8[>..] = [];
    let q = sqlite::prepare_or_die(db, """
        SELECT DISTINCT s.file_id, s.path,
               COALESCE((SELECT f.edited_mtime FROM sw.files f WHERE f.file = s.path), -1)
        FROM sites s
    """);
    while sqlite::step(q, err) == 1 {
        var rel: u8[>..] = [];
        sqlite::col_text(q, 1, rel);
        let m = sw_mtime_ns(str(root, "/", rel));
        if m < 0 || (m > scip_time && m != sqlite::col_int(q, 2)) { stale.push(sqlite::col_int(q, 0)); }
    }
    sqlite::finalize(q);
    for id in stale { sqlite::exec_or_die(db, str("DELETE FROM sites WHERE file_id = ", id)); }
    let skipped = scalar(db, "SELECT n FROM nsites") - scalar(db, "SELECT COUNT(*) FROM sites");

    sqlite::exec_or_die(db, """
        -- Swan counts lines from 0, Spread-Wings from 1.
        CREATE TEMP TABLE hits AS
            SELECT st.file_id, st.row, st.callee, s.in_repo,
                   (SELECT y.id FROM files f2 JOIN symbols y ON y.file_id = f2.id
                    WHERE f2.path = s.def_file AND y.name = st.callee
                      AND y.row <= s.def_line + 1 AND y.end_row >= s.def_line + 1
                    ORDER BY y.end_row - y.row LIMIT 1) AS sid
            FROM sites st
            JOIN sw.occurrences o ON o.file = st.path AND o.start_line = st.row - 1
                 AND o.is_def = 0 AND o.by_name = 0 AND o.is_import = 0
            JOIN sw.symbols s ON s.id = o.symbol_id AND s.name = st.callee;
        -- target: 0 = outside the repo, an id = that one definition, -1 = left
        -- alone (fewer answers than calls on the line, answers that differ, or
        -- a repo symbol that is no definition here: a parameter or a variable
        -- holding the function).
        CREATE TEMP TABLE verdict AS
            SELECT st.file_id, st.row, st.callee, st.caller,
                   CASE WHEN COUNT(*) < (SELECT COUNT(*) FROM calls c WHERE c.file_id = st.file_id
                                         AND c.row = st.row AND c.callee = st.callee) THEN -1
                        WHEN SUM(h.in_repo) = 0 THEN 0
                        WHEN SUM(h.in_repo) = COUNT(*) AND COUNT(DISTINCT h.sid) = 1
                             AND SUM(h.sid IS NULL) = 0 THEN MIN(h.sid)
                        ELSE -1 END AS target
            FROM sites st JOIN hits h ON h.file_id = st.file_id AND h.row = st.row AND h.callee = st.callee
            GROUP BY st.file_id, st.row, st.callee;
        DELETE FROM verdict WHERE target < 0;

        DELETE FROM call_edges WHERE resolution = 'by_name' AND rowid IN (
            SELECT e.rowid FROM call_edges e JOIN symbols t ON t.id = e.callee
            JOIN verdict v ON v.file_id = e.file_id AND v.row = e.row AND v.callee = t.name);
        INSERT INTO call_edges (caller, callee, file_id, row, weight, by_name, resolution)
            SELECT caller, target, file_id, row, 1.0, 0, 'compiler' FROM verdict WHERE target > 0;
        UPDATE calls SET note = 'compiler_outside' WHERE EXISTS (
            SELECT 1 FROM verdict v WHERE v.target = 0 AND v.file_id = calls.file_id
              AND v.row = calls.row AND v.callee = calls.callee);
        DELETE FROM file_edges WHERE kind = 'call';
    """);
    let before = scalar(db, "SELECT n FROM nsites");
    let linked = scalar(db, "SELECT COUNT(*) FROM verdict WHERE target > 0");
    let outside = scalar(db, "SELECT COUNT(*) FROM verdict WHERE target = 0");
    let covered = scalar(db, "SELECT COUNT(*) FROM (SELECT DISTINCT file_id, row, callee FROM hits)");
    sqlite::exec_or_die(db, "DROP TABLE sites; DROP TABLE nsites; DROP TABLE hits; DROP TABLE verdict;");
    call_file_edges(db);
    var gs: u8[>..] = [];
    get_meta(db, "resolution", gs);
    let g100, g_ok = parse_int(gs);
    let rounds = communities(db, if g_ok && g100 > 0 { g100 as f64 / 100.0 } else { 1.5 });
    set_meta(db, "compiler_answers", "swan");
    sqlite::exec_or_die(db, "COMMIT");
    sqlite::exec_or_die(db, "DETACH DATABASE sw");
    var note: u8[>..] = [];
    if stale.len > 0 {
        note.append(str("; skipped ", skipped, " in ", stale.len, " files changed since the Swan map was built (refresh the map)"));
    }
    print(str("spread-wings compiler: ", before, " calls tied only by name; Swan's map covers ", covered,
              ": ", linked, " tied to one definition, ", outside, " outside the repo, ",
              covered - linked - outside, " left (unclear)", note, "; ",
              scalar(db, "SELECT COUNT(*) FROM communities"), " communities (", rounds, " rounds)"));
    sqlite::close(db);
}
