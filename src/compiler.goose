// Compiler answers from a Swan map. Swan's indexers (scip-python,
// scip-typescript, rust-analyzer, ...) resolve each use of a name to the
// definition the compiler sees. For every call site, linked or not, take
// that answer when Swan has one at the same file and line:
//   all uses there resolve outside the repo    -> the site keeps no link;
//   they resolve to exactly one repo definition -> it becomes the only
//                                                link, resolution `compiler`;
//   they resolve to something in the repo that the graph does not hold as
//   a definition (a parameter, a variable)     -> links into other files
//                                                than Swan's go.
// Anything Swan doesn't cover, or covers ambiguously, stays as the rules
// left it, for `decide` or a reader. Swan's map is only read.
//
// Until 2026-11-18 only the calls tied by name were put to Swan. Measured
// that day, most of what was wrong on a TypeScript repo was tied through an
// imported file instead (morluto/rea: 21,389 wrong `imported_file` links of
// 43,319 judged), and calls no rule could tie had answers waiting.
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

// Opens the graph with the Swan map attached as `sw`, after checking that
// the map is of this code: its root is the graph's root (filled into
// `root`). Returns the database and when the map's SCIP run was (ns).
fn attach_swan(db_path: const u8[:], swan_db: const u8[:], root: u8[>..]&) -> i64, i64 {
    guard find(swan_db, "'") < 0 else { abort("spread-wings: the Swan map path cannot contain a quote"); }
    guard file_exists(swan_db) else { abort(str("spread-wings: no Swan map at ", swan_db)); }
    let db = open_map(db_path);
    sqlite::exec_or_die(db, str("ATTACH DATABASE '", swan_db, "' AS sw"));
    guard scalar(db, "SELECT COUNT(*) FROM sw.sqlite_master WHERE type = 'table' AND name IN ('meta', 'files', 'symbols', 'occurrences')") == 4 else {
        abort(str("spread-wings: ", swan_db, " is not a Swan map (no meta, files, symbols and occurrences tables)"));
    }

    // Same code? The roots must match, and the map must say when it was built.
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
    return db, scip_time;
}

// The files among a query's rows (file id, path, the mtime Swan left on it
// or -1) that changed after the map's SCIP run, or are gone: Swan itself
// calls such a file stale. A file Swan edited keeps the mtime Swan left.
fn stale_files(db: i64, root: const u8[:], scip_time: i64, sql: const u8[:], stale: i64[>..]&) {
    var err: u8[>..] = [];
    let q = sqlite::prepare_or_die(db, sql);
    while sqlite::step(q, err) == 1 {
        var rel: u8[>..] = [];
        sqlite::col_text(q, 1, rel);
        let m = sw_mtime_ns(str(root, "/", rel));
        if m < 0 || (m > scip_time && m != sqlite::col_int(q, 2)) { stale.push(sqlite::col_int(q, 0)); }
    }
    sqlite::finalize(q);
}

fn compiler_main(db_path: const u8[:], swan_db: const u8[:]) {
    var root: u8[>..] = [];
    let db, scip_time = attach_swan(db_path, swan_db, root);

    sqlite::exec_or_die(db, "BEGIN");
    sqlite::exec_or_die(db, """
        -- Every call site, linked or not: a line of a file and the name
        -- called there.
        CREATE TEMP TABLE sites AS
            SELECT c.file_id, c.row, c.callee, f.path, MIN(c.in_symbol) AS caller, COUNT(*) AS ncalls
            FROM calls c JOIN files f ON f.id = c.file_id
            GROUP BY c.file_id, c.row, c.callee;
        CREATE TEMP TABLE nsites AS SELECT COUNT(*) AS n FROM sites;
        CREATE INDEX temp.sites_at ON sites (file_id, row, callee);
    """);

    // Files changed since the map's SCIP run: not answered from this map.
    var stale: i64[>..] = [];
    stale_files(db, root, scip_time, """
        SELECT f.id, f.path, COALESCE((SELECT x.edited_mtime FROM sw.files x WHERE x.file = f.path), -1)
        FROM files f WHERE f.id IN (SELECT DISTINCT file_id FROM sites)
    """, stale);
    for id in stale { sqlite::exec_or_die(db, str("DELETE FROM sites WHERE file_id = ", id)); }
    let skipped = scalar(db, "SELECT n FROM nsites") - scalar(db, "SELECT COUNT(*) FROM sites");

    sqlite::exec_or_die(db, """
        -- The graph's definitions by file path and name, to find the one a
        -- Swan definition is. Swan counts lines from 0, Spread-Wings from 1.
        CREATE TEMP TABLE gsym AS
            SELECT f.path AS path, y.name AS name, y.row AS row, y.end_row AS end_row, y.id AS id, y.file_id AS file_id
            FROM symbols y JOIN files f ON f.id = y.file_id;
        CREATE INDEX temp.gsym_at ON gsym (path, name);
        -- sid: the graph's definition of what Swan resolved the use to (the
        -- innermost of that name around Swan's line); dfile: the graph's
        -- file Swan's definition is in.
        CREATE TEMP TABLE hits AS
            SELECT st.file_id, st.row, st.callee, s.in_repo,
                   (SELECT g.id FROM gsym g WHERE g.path = s.def_file AND g.name = st.callee
                      AND g.row <= s.def_line + 1 AND g.end_row >= s.def_line + 1
                    ORDER BY g.end_row - g.row LIMIT 1) AS sid,
                   (SELECT f2.id FROM files f2 WHERE f2.path = s.def_file) AS dfile
            FROM sites st
            JOIN sw.occurrences o ON o.file = st.path AND o.start_line = st.row - 1
                 AND o.is_def = 0 AND o.by_name = 0 AND o.is_import = 0
            JOIN sw.symbols s ON s.id = o.symbol_id AND s.name = st.callee;
        CREATE INDEX temp.hits_at ON hits (file_id, row, callee);
        -- target: an id = that one definition; 0 = outside the repo; -2 = in
        -- the repo, in file dfile, and nothing the graph holds as a
        -- definition (a parameter, a variable holding the function, a key of
        -- an object); -1 = left alone (fewer answers than calls of that name
        -- on the line, or answers that differ).
        CREATE TEMP TABLE verdict AS
            SELECT st.file_id, st.row, st.callee, st.caller,
                   CASE WHEN COUNT(*) < st.ncalls THEN -1
                        WHEN SUM(h.in_repo) = 0 THEN 0
                        WHEN SUM(h.in_repo) = COUNT(*) AND COUNT(DISTINCT h.sid) = 1
                             AND SUM(h.sid IS NULL) = 0 THEN MIN(h.sid)
                        WHEN SUM(h.in_repo) = COUNT(*) AND SUM(h.sid IS NOT NULL) = 0
                             AND COUNT(DISTINCT h.dfile) = 1 AND SUM(h.dfile IS NULL) = 0 THEN -2
                        ELSE -1 END AS target,
                   MIN(h.dfile) AS dfile
            FROM sites st JOIN hits h ON h.file_id = st.file_id AND h.row = st.row AND h.callee = st.callee
            GROUP BY st.file_id, st.row, st.callee;
        DELETE FROM verdict WHERE target = -1;
        CREATE INDEX temp.verdict_at ON verdict (file_id, row, callee);

        -- The links the graph has at those sites, whatever rule made them.
        CREATE TEMP TABLE at_site AS
            SELECT e.rowid AS eid, e.file_id AS file_id, e.row AS row, y.name AS callee, e.callee AS sid,
                   y.file_id AS sfile, v.target AS target, v.dfile AS dfile
            FROM call_edges e JOIN symbols y ON y.id = e.callee
            JOIN verdict v ON v.file_id = e.file_id AND v.row = e.row AND v.callee = y.name;
        CREATE INDEX temp.at_site_at ON at_site (file_id, row, callee);
        -- What happens to each answered site, for the account below.
        CREATE TEMP TABLE outcome AS
            SELECT v.file_id, v.row, v.callee, v.target, COUNT(a.eid) AS had,
                   COALESCE(SUM(a.sid = v.target), 0) AS had_right,
                   COALESCE(SUM(a.sfile <> v.dfile), 0) AS elsewhere
            FROM verdict v LEFT JOIN at_site a ON a.file_id = v.file_id AND a.row = v.row AND a.callee = v.callee
            GROUP BY v.file_id, v.row, v.callee;

        -- One definition: it becomes the site's only link. Outside the repo:
        -- no link. A value the graph does not hold: the links into other
        -- files than the one Swan names go; one into that file may be the
        -- same thing under the graph's coarser idea of a definition, and stays.
        DELETE FROM call_edges WHERE rowid IN (SELECT eid FROM at_site WHERE target >= 0)
                                  OR rowid IN (SELECT eid FROM at_site WHERE target = -2 AND sfile <> dfile);
        INSERT INTO call_edges (caller, callee, file_id, row, weight, by_name, resolution)
            SELECT caller, target, file_id, row, 1.0, 0, 'compiler' FROM verdict WHERE target > 0;
        -- A note said why a call had no link; with a link it no longer holds.
        UPDATE calls SET note = NULL WHERE note IS NOT NULL AND EXISTS (
            SELECT 1 FROM verdict v WHERE v.target > 0 AND v.file_id = calls.file_id
              AND v.row = calls.row AND v.callee = calls.callee);
        UPDATE calls SET note = 'compiler_outside' WHERE EXISTS (
            SELECT 1 FROM verdict v WHERE v.target = 0 AND v.file_id = calls.file_id
              AND v.row = calls.row AND v.callee = calls.callee);
        UPDATE calls SET note = 'compiler_value' WHERE EXISTS (
            SELECT 1 FROM verdict v WHERE v.target = -2 AND v.file_id = calls.file_id
              AND v.row = calls.row AND v.callee = calls.callee)
          -- (unless a link into Swan's file was kept)
          AND NOT EXISTS (SELECT 1 FROM at_site a WHERE a.file_id = calls.file_id AND a.row = calls.row
                          AND a.callee = calls.callee AND a.sfile = a.dfile);
        DELETE FROM file_edges WHERE kind = 'call';
    """);
    let all = scalar(db, "SELECT n FROM nsites");
    let covered = scalar(db, "SELECT COUNT(*) FROM (SELECT DISTINCT file_id, row, callee FROM hits)");
    let linked = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target > 0");
    let already = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target > 0 AND had = 1 AND had_right = 1");
    let narrowed = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target > 0 AND had > 1 AND had_right = 1");
    let corrected = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target > 0 AND had > 0 AND had_right = 0");
    let added = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target > 0 AND had = 0");
    let outside = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target = 0");
    let outside_unlinked = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target = 0 AND had > 0");
    let values = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target = -2");
    let values_unlinked = scalar(db, "SELECT COUNT(*) FROM outcome WHERE target = -2 AND elsewhere > 0");
    sqlite::exec_or_die(db, "DROP TABLE sites; DROP TABLE nsites; DROP TABLE gsym; DROP TABLE hits; DROP TABLE verdict; DROP TABLE at_site; DROP TABLE outcome;");
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
    print(str("spread-wings compiler: ", all, " call sites; Swan's map covers ", covered,
              ": ", linked, " tied to one definition, ", outside, " outside the repo, ", values,
              " calls of a value the graph does not hold, ", covered - linked - outside - values, " left (unclear)", note,
              ". Of those tied: ", already, " as they were, ", narrowed, " narrowed from several, ", corrected,
              " corrected, ", added, " new. Guessed links removed at ", outside_unlinked, " outside sites and ",
              values_unlinked, " value sites; ",
              scalar(db, "SELECT COUNT(*) FROM communities"), " communities (", rounds, " rounds)"));
    sqlite::close(db);
}
