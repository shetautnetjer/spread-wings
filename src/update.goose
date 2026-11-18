// One-file updates: `spread-wings update <repo> <graph.db>` brings a graph
// up to date with its repo by reading again only the files that changed and
// tying again only the calls a change can reach. The graph it leaves is the
// one `index` builds from the same files, apart from row numbers
// (tests/graph_dump.py prints a graph without them; the two are compared).
//
// What a call's links hang on, and so what makes update tie it again:
//   - its own file: its definitions, imports and variables. The file was
//     read again; or its imports now land on other files (a file was added
//     or removed); or a variable in it is bound from a call of a name whose
//     definitions changed, one of which says what it returns (what x holds
//     after `x = build()` decides the calls on x, and is read off
//     `def build() -> Graph`);
//   - the definitions of the name it calls, anywhere: how many there are,
//     which files hold them, which type each belongs to, what each says it
//     returns. A file read again changes a name when the definitions of
//     that name in it are not what they were (by kind, type and signature
//     line): the body of a function can change and its callers stay as
//     they are, their links moved to the definition's new row. A name
//     defined in more than 50 places is tied only within the caller's own
//     file and the files it imports, so a change to one reaches only the
//     files that import the changed file;
//   - the names files pass on (`from .base import f`): a name on an import
//     line that a file read again gained, lost or changed may now come
//     through it from elsewhere, when some file imports from that file
//     (a file nothing imports from passes nothing on);
//   - a name called under another (`import {f as g}`: `g()` when f changed);
//   - what a function returns, as far as its file's imports say (`-> Graph`
//     is an outside type while the file imports Graph from outside): when
//     a file's imports change, the names of its functions that say what
//     they return;
//   - the far end of a link: one to a definition that is gone is redone;
//   - the repo's top-level names (make_roots): when a file added or removed
//     changes them, every call is tied again.
// A link is kept by line, so every call on a line is tied again with any
// one of them.

import std;
import json;
import sqlite;
import .store;
import .extract;
import .graph;

// The names on the import lines in temp.u_lines, into temp.u_names: `f`,
// both sides of `orig>bound`, the x of `@x`.
let IMPORT_NAMES_SQL = """
    WITH RECURSIVE sp(tok, rest) AS (
        SELECT '', names || ',' FROM temp.u_lines
        UNION ALL SELECT substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1) FROM sp WHERE rest <> '')
    INSERT OR IGNORE INTO temp.u_names
        SELECT replace(tok, '@', '') FROM sp WHERE tok <> '' AND tok <> '@' AND instr(tok, '>') = 0
        UNION SELECT substr(tok, 1, instr(tok, '>') - 1) FROM sp WHERE instr(tok, '>') > 1
        UNION SELECT substr(tok, instr(tok, '>') + 1) FROM sp WHERE instr(tok, '>') > 0 AND substr(tok, instr(tok, '>') + 1) <> '';
    DELETE FROM temp.u_lines;
""";

// What the files in temp.u_set (read again, or gone) held, kept before
// their rows go: each definition as other files' calls can tell it (name,
// kind, the type it belongs to, its signature line), and each import line.
let KEEP_OLD_SQL = """
    CREATE TEMP TABLE u_old_sym AS
        SELECT id, file_id, name, kind, COALESCE(container, '') AS container, COALESCE(sig, '') AS sig, start
        FROM symbols WHERE file_id IN (SELECT id FROM temp.u_set) AND name IS NOT NULL;
    CREATE TEMP TABLE u_old_imp AS
        SELECT file_id, COALESCE(module, '') AS module, COALESCE(names, '') AS names, COALESCE(dst, 0) AS dst
        FROM imports WHERE file_id IN (SELECT id FROM temp.u_set);
    CREATE TEMP TABLE u_dsts (id INTEGER PRIMARY KEY);
""";

// The files something imports from, or names as a module (temp.u_dsts):
// taken before the change and again after the imports are tied.
let IMPORTED_FILES_SQL = """
    INSERT OR IGNORE INTO temp.u_dsts SELECT DISTINCT dst FROM imports WHERE dst > 0;
    INSERT OR IGNORE INTO temp.u_dsts SELECT DISTINCT dst FROM aliases WHERE dst > 0;
""";

// After the files read again have their new rows: the names whose
// definitions in them are not what they were (temp.u_chg, by file). A name
// defined in at most 50 places, before or now, can be tied from anywhere,
// and goes to temp.u_names: every call of it is tied again. A name defined
// in more than 50 places before and now is only ever tied to the
// definitions in the caller's own file and in the files it imports
// (LINK_CALLS_SQL), so a change to it in a file reaches the calls of it in
// the files that import that file and no others (temp.u_near).
let COMPARE_SQL = """
    CREATE TEMP TABLE u_new_sym AS
        SELECT id, file_id, name, kind, COALESCE(container, '') AS container, COALESCE(sig, '') AS sig, start
        FROM symbols WHERE file_id IN (SELECT id FROM temp.u_changed) AND name IS NOT NULL;
    CREATE INDEX temp.u_old_sym_name ON u_old_sym(name);
    CREATE INDEX temp.u_new_sym_name ON u_new_sym(name);
    CREATE TEMP TABLE u_chg AS
        SELECT DISTINCT file_id, name FROM (
            SELECT file_id, name FROM (
                SELECT file_id, name, kind, container, sig, COUNT(*) FROM temp.u_old_sym GROUP BY 1, 2, 3, 4, 5
                EXCEPT SELECT file_id, name, kind, container, sig, COUNT(*) FROM temp.u_new_sym GROUP BY 1, 2, 3, 4, 5)
            UNION ALL
            SELECT file_id, name FROM (
                SELECT file_id, name, kind, container, sig, COUNT(*) FROM temp.u_new_sym GROUP BY 1, 2, 3, 4, 5
                EXCEPT SELECT file_id, name, kind, container, sig, COUNT(*) FROM temp.u_old_sym GROUP BY 1, 2, 3, 4, 5));
    -- How many definitions each of those names has, and had.
    CREATE TEMP TABLE u_cnt AS
        SELECT name, now, now - gained + lost AS was FROM (
            SELECT c.name,
                (SELECT COUNT(*) FROM symbols s WHERE s.name = c.name
                    AND s.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface')) AS now,
                (SELECT COUNT(*) FROM temp.u_new_sym n WHERE n.name = c.name
                    AND n.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface')) AS gained,
                (SELECT COUNT(*) FROM temp.u_old_sym o WHERE o.name = c.name
                    AND o.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface')) AS lost
            FROM (SELECT DISTINCT name FROM temp.u_chg) c);
    INSERT OR IGNORE INTO temp.u_names SELECT name FROM temp.u_cnt WHERE now <= 50 OR was <= 50;
    CREATE TEMP TABLE u_near AS
        SELECT g.file_id, g.name FROM temp.u_chg g JOIN temp.u_cnt c ON c.name = g.name WHERE c.now > 50 AND c.was > 50;
""";

// After their imports are tied: the import lines a file read again gained
// or lost. One that names a file of the repo, in a file that something
// imports from, passes names on, and the names on it go to temp.u_lines
// (an import from outside the repo passes nothing on, nor does a file
// nothing imports from). And in a file whose import lines are not what
// they were, the functions that say what they return.
let COMPARE_IMPORTS_SQL = """
    CREATE TEMP TABLE u_new_imp AS
        SELECT file_id, COALESCE(module, '') AS module, COALESCE(names, '') AS names, COALESCE(dst, 0) AS dst
        FROM imports WHERE file_id IN (SELECT id FROM temp.u_changed);
    CREATE TEMP TABLE u_lost AS
        SELECT file_id, module, names FROM temp.u_old_imp EXCEPT SELECT file_id, module, names FROM temp.u_new_imp;
    CREATE TEMP TABLE u_gained AS
        SELECT file_id, module, names FROM temp.u_new_imp EXCEPT SELECT file_id, module, names FROM temp.u_old_imp;
    INSERT INTO temp.u_lines
        SELECT l.names FROM temp.u_lost l WHERE l.file_id IN (SELECT id FROM temp.u_dsts) AND EXISTS (
            SELECT 1 FROM temp.u_old_imp o WHERE o.file_id = l.file_id AND o.module = l.module AND o.names = l.names AND o.dst > 0)
        UNION ALL
        SELECT g.names FROM temp.u_gained g WHERE g.file_id IN (SELECT id FROM temp.u_dsts) AND EXISTS (
            SELECT 1 FROM temp.u_new_imp o WHERE o.file_id = g.file_id AND o.module = g.module AND o.names = g.names AND o.dst > 0);
    INSERT OR IGNORE INTO temp.u_names
        SELECT name FROM temp.u_old_sym WHERE instr(sig, '->') > 0
          AND file_id IN (SELECT file_id FROM temp.u_lost UNION SELECT file_id FROM temp.u_gained)
        UNION SELECT name FROM temp.u_new_sym WHERE instr(sig, '->') > 0
          AND file_id IN (SELECT file_id FROM temp.u_lost UNION SELECT file_id FROM temp.u_gained);
""";

// The links of every name whose definitions are as they were (not in
// temp.u_all), moved from a definition's old row to its new one. Definitions alike in name, kind, type and
// signature line are the same to any call from outside the file, so the
// old ones are paired with the new ones in the order they stand in it.
let MOVE_LINKS_SQL = """
    CREATE TEMP TABLE u_all (name TEXT PRIMARY KEY) WITHOUT ROWID;
    INSERT OR IGNORE INTO temp.u_all SELECT name FROM temp.u_names;
    INSERT OR IGNORE INTO temp.u_all SELECT name FROM temp.u_chg;
    CREATE TEMP TABLE u_map AS
        SELECT o.id AS old, n.id AS new FROM
            (SELECT id, file_id, name, kind, container, sig,
                    ROW_NUMBER() OVER (PARTITION BY file_id, name, kind, container, sig ORDER BY start, id) AS k
             FROM temp.u_old_sym WHERE name NOT IN (SELECT name FROM temp.u_all)) o
        JOIN (SELECT id, file_id, name, kind, container, sig,
                     ROW_NUMBER() OVER (PARTITION BY file_id, name, kind, container, sig ORDER BY start, id) AS k
              FROM temp.u_new_sym WHERE name NOT IN (SELECT name FROM temp.u_all)) n
          ON n.file_id = o.file_id AND n.name = o.name AND n.kind = o.kind AND n.container = o.container
             AND n.sig = o.sig AND n.k = o.k;
    CREATE UNIQUE INDEX temp.u_map_old ON u_map(old);
    UPDATE call_edges SET callee = (SELECT m.new FROM temp.u_map m WHERE m.old = call_edges.callee)
        WHERE callee IN (SELECT old FROM temp.u_map);
""";

// Every row of the files in temp.u_set (read again, or gone), and the files
// in temp.u_gone themselves.
let DROP_ROWS_SQL = """
    DELETE FROM symbols WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM imports WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM calls WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM assigns WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM aliases WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM call_edges WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM decisions WHERE file_id IN (SELECT id FROM temp.u_set);
    DELETE FROM file_edges WHERE src IN (SELECT id FROM temp.u_set);
    DELETE FROM file_edges WHERE dst IN (SELECT id FROM temp.u_gone);
    DELETE FROM stamps WHERE file_id IN (SELECT id FROM temp.u_gone);
    DELETE FROM files WHERE id IN (SELECT id FROM temp.u_gone);
""";

// After every import was tied again (a file was added or removed): the
// files not read again whose imports, or names for whole modules, now land
// somewhere else than before (temp.u_imp, temp.u_ali).
let REIMPORTED_SQL = """
    INSERT OR IGNORE INTO temp.u_reimp
        SELECT b.file_id FROM temp.u_imp b JOIN imports i ON i.rowid = b.r WHERE COALESCE(i.dst, 0) <> b.dst;
    INSERT OR IGNORE INTO temp.u_reimp
        SELECT file_id FROM (SELECT file_id, alias, dst FROM temp.u_ali EXCEPT SELECT file_id, alias, dst FROM aliases);
    INSERT OR IGNORE INTO temp.u_reimp
        SELECT file_id FROM (SELECT file_id, alias, dst FROM aliases WHERE file_id NOT IN (SELECT id FROM temp.u_changed)
                             EXCEPT SELECT file_id, alias, dst FROM temp.u_ali);
    INSERT OR IGNORE INTO temp.u_files SELECT id FROM temp.u_reimp;
    INSERT INTO temp.u_lines SELECT COALESCE(names, '') FROM imports
        WHERE file_id IN (SELECT id FROM temp.u_reimp) AND file_id IN (SELECT id FROM temp.u_dsts);
    INSERT OR IGNORE INTO temp.u_names
        SELECT name FROM symbols WHERE file_id IN (SELECT id FROM temp.u_reimp)
          AND name IS NOT NULL AND instr(COALESCE(sig, ''), '->') > 0;
""";

// The calls to tie again (temp.dirty), by the list at the top of this file,
// the files they are in (temp.dirty_files), and their links and notes taken
// away. temp.u_names holds the names every call of which is redone,
// temp.u_near those redone in the files that import the changed file,
// temp.u_all every name whose definitions or passing on changed, and
// temp.u_files the files whose every call is redone.
let DIRTY_SQL = """
    INSERT OR IGNORE INTO temp.u_files SELECT id FROM temp.u_changed;
    -- What a variable bound from a call holds is read off the called
    -- function's signature, where it says what it returns (`-> Type`). A
    -- name none of whose definitions says so, before or now, tells
    -- nothing about `x = name()`, and leaves the calls on x as they are.
    INSERT OR IGNORE INTO temp.u_files
        SELECT DISTINCT file_id FROM assigns WHERE value IN (
            SELECT n.name FROM temp.u_all n
            WHERE EXISTS (SELECT 1 FROM symbols s WHERE s.name = n.name AND instr(COALESCE(s.sig, ''), '->') > 0)
               OR EXISTS (SELECT 1 FROM temp.u_old_sym o WHERE o.name = n.name AND instr(o.sig, '->') > 0));
    INSERT OR IGNORE INTO temp.dirty SELECT rowid FROM calls WHERE file_id IN (SELECT id FROM temp.u_files);
    INSERT OR IGNORE INTO temp.dirty SELECT c.rowid FROM temp.u_names n JOIN calls c ON c.callee = n.name;
    INSERT OR IGNORE INTO temp.dirty
        SELECT c.rowid FROM temp.u_near n JOIN imports i ON i.dst = n.file_id
        JOIN calls c ON c.file_id = i.file_id AND c.callee = n.name;
    WITH RECURSIVE sp(file_id, tok, rest) AS (
        SELECT file_id, '', names || ',' FROM imports WHERE instr(names, '>') > 0
        UNION ALL SELECT file_id, substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1)
        FROM sp WHERE rest <> '')
    INSERT OR IGNORE INTO temp.dirty
        SELECT c.rowid FROM sp JOIN temp.u_all n ON n.name = substr(sp.tok, 1, instr(sp.tok, '>') - 1)
        JOIN calls c ON c.file_id = sp.file_id AND c.callee = substr(sp.tok, instr(sp.tok, '>') + 1)
        WHERE instr(sp.tok, '>') > 1;
    INSERT OR IGNORE INTO temp.dirty
        SELECT c.rowid FROM (SELECT DISTINCT file_id, row FROM call_edges
                             WHERE callee NOT IN (SELECT id FROM symbols)) e
        JOIN calls c ON c.file_id = e.file_id AND c.row = e.row;
    CREATE TEMP TABLE u_sites AS
        SELECT DISTINCT c.file_id, c.row FROM temp.dirty d JOIN calls c ON c.rowid = d.cid;
    CREATE INDEX temp.u_sites_at ON u_sites(file_id, row);
    INSERT OR IGNORE INTO temp.dirty
        SELECT c.rowid FROM temp.u_sites s JOIN calls c ON c.file_id = s.file_id AND c.row = s.row;
    INSERT OR IGNORE INTO temp.dirty_files SELECT DISTINCT file_id FROM temp.u_sites;
    INSERT OR IGNORE INTO temp.dirty_files SELECT id FROM temp.u_changed;
    DELETE FROM call_edges WHERE EXISTS (
        SELECT 1 FROM temp.u_sites s WHERE s.file_id = call_edges.file_id AND s.row = call_edges.row);
    DELETE FROM call_edges WHERE callee NOT IN (SELECT id FROM symbols);
    UPDATE calls SET note = NULL WHERE note IS NOT NULL AND rowid IN (SELECT cid FROM temp.dirty);
""";

// How many of the file links update redid (those out of the files read
// again, and the call links out of the files with calls tied again) are not
// what they were (temp.u_fe): 0 when the same links, with the same weights,
// are back.
let FILE_LINKS_SAME_SQL = """
    SELECT (SELECT COUNT(*) FROM (
                SELECT src, dst, kind, weight, COUNT(*) FROM temp.u_fe GROUP BY 1, 2, 3, 4
                EXCEPT
                SELECT src, dst, kind, weight, COUNT(*) FROM file_edges
                WHERE src IN (SELECT id FROM temp.u_set)
                   OR (kind = 'call' AND src IN (SELECT id FROM temp.dirty_files))
                GROUP BY 1, 2, 3, 4))
         + (SELECT COUNT(*) FROM (
                SELECT src, dst, kind, weight, COUNT(*) FROM file_edges
                WHERE src IN (SELECT id FROM temp.u_set)
                   OR (kind = 'call' AND src IN (SELECT id FROM temp.dirty_files))
                GROUP BY 1, 2, 3, 4
                EXCEPT
                SELECT src, dst, kind, weight, COUNT(*) FROM temp.u_fe GROUP BY 1, 2, 3, 4))
""";

// A JSON array of the first column of `sql`, as strings.
fn json_texts(db: i64, sql: const u8[:], out: u8[>..]&) {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, sql);
    out.push('[');
    var first = true;
    while sqlite::step(st, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var v: u8[>..] = [];
        sqlite::col_text(st, 0, v);
        json::format_string(out, v);
    }
    out.push(']');
    sqlite::finalize(st);
}

// Brings the graph in db (of repo, an absolute path; inside a transaction)
// up to date, and appends what it did to out as the members of a JSON
// object. regroup: the communities are wanted at another resolution than
// the graph has, so they are found again even when no file changed.
fn update_graph(db: i64, repo: const u8[:], gamma: f64, regroup: bool, out: u8[>..]&) {
    let now = time_ns();
    let t0 = clock();
    var paths: u8[>..] = [];
    var plangs: u8[>..] = [];
    let n = walk_repo(repo, paths, plangs);
    let all_paths = split(paths, '\n');
    let all_langs = split(plangs, '\n');
    var sizes: i64[>..] = [];
    var mtimes: i64[>..] = [];
    var ctimes: i64[>..] = [];
    stat_files(all_paths, n, sizes, mtimes, ctimes);

    sqlite::exec_or_die(db, """
        CREATE TEMP TABLE u_walk (ord INTEGER PRIMARY KEY, path TEXT UNIQUE, lang TEXT, size INTEGER, mtime INTEGER, ctime INTEGER);
        CREATE TEMP TABLE u_changed (id INTEGER PRIMARY KEY);
        CREATE TEMP TABLE u_added (id INTEGER PRIMARY KEY);
        CREATE TEMP TABLE u_gone (id INTEGER PRIMARY KEY, path TEXT);
        CREATE TEMP TABLE u_set (id INTEGER PRIMARY KEY);
        CREATE TEMP TABLE u_names (name TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TEMP TABLE u_lines (names TEXT);
        CREATE TEMP TABLE u_files (id INTEGER PRIMARY KEY);
        CREATE TEMP TABLE u_reimp (id INTEGER PRIMARY KEY);
        CREATE TEMP TABLE dirty (cid INTEGER PRIMARY KEY);
        CREATE TEMP TABLE dirty_files (id INTEGER PRIMARY KEY);
    """);
    let ins_walk = sqlite::prepare_or_die(db, "INSERT INTO temp.u_walk (ord, path, lang, size, mtime, ctime) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
    for i in 0..n {
        sqlite::reset(ins_walk);
        sqlite::bind_int(ins_walk, 1, i);
        sqlite::bind_text(ins_walk, 2, all_paths[i][repo.len + 1..]);
        sqlite::bind_text(ins_walk, 3, all_langs[i]);
        sqlite::bind_int(ins_walk, 4, sizes[i]);
        sqlite::bind_int(ins_walk, 5, mtimes[i]);
        sqlite::bind_int(ins_walk, 6, ctimes[i]);
        sqlite::step_done(ins_walk);
    }
    sqlite::finalize(ins_walk);

    // Each file of the walk: its row (0 until it has one), and, when it has
    // to be looked at, the hash index last saw. A file is looked at when it
    // is new, or its size or a time is not what its stamp says, or its
    // stamp kept no times.
    var pids: i64[>..] = [];
    var old_known: i64[>..] = [];
    var old_hash: i64[>..] = [];
    var is_new: i64[>..] = [];
    pids.resize(n, 0);
    old_known.resize(n, 0);
    old_hash.resize(n, 0);
    is_new.resize(n, 0);
    var which: i64[>..] = [];
    var err: u8[>..] = [];
    let q = sqlite::prepare_or_die(db, """
        SELECT w.ord, f.id, s.hash IS NOT NULL, COALESCE(s.hash, 0),
               s.file_id IS NULL OR s.mtime = 0 OR s.size IS NOT w.size OR s.mtime IS NOT w.mtime OR s.ctime IS NOT w.ctime
        FROM temp.u_walk w JOIN files f ON f.path = w.path LEFT JOIN stamps s ON s.file_id = f.id
        ORDER BY w.ord
    """);
    while sqlite::step(q, err) == 1 {
        let i = sqlite::col_int(q, 0);
        pids[i] = sqlite::col_int(q, 1);
        if sqlite::col_int(q, 4) != 0 {
            which.push(i);
            old_known[i] = sqlite::col_int(q, 2);
            old_hash[i] = sqlite::col_int(q, 3);
        }
    }
    sqlite::finalize(q);
    sqlite::exec_or_die(db, "INSERT INTO temp.u_gone SELECT id, path FROM files WHERE path NOT IN (SELECT path FROM temp.u_walk)");
    let gone = scalar(db, "SELECT COUNT(*) FROM temp.u_gone");
    var added: i64 = 0;
    for i in 0..n { if pids[i] == 0 { added++; } }
    // (Before the new files have rows: the top-level names as they were.)
    let set_changed = added > 0 || gone > 0;
    let roots_before: u8[>..] = if set_changed { roots_text(db) } else { str("") };
    let ins_file = sqlite::prepare_or_die(db, "INSERT INTO files (path, lang, dir) VALUES (?1, ?2, ?3)");
    for i in 0..n {
        if pids[i] == 0 {
            pids[i] = insert_file(db, ins_file, all_paths[i][repo.len + 1..], all_langs[i]);
            is_new[i] = 1;
            which.push(i);
        }
    }
    sqlite::finalize(ins_file);
    sort(which);

    var all: u8[>..] = [];
    var at: i64[>..] = [];
    var len: i64[>..] = [];
    var hashes: i64[>..] = [];
    var same: i64[>..] = [];
    parse_files(all_paths, all_langs, n, which, old_known, old_hash, all, at, len, hashes, same);
    var changed: i64[>..] = [];   // read again: its content is new, or it is new
    for i in which { if same[i] == 0 { changed.push(i); } }

    let ins_stamp = sqlite::prepare_or_die(db, "INSERT OR REPLACE INTO stamps (file_id, ord, size, mtime, ctime, hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
    for i in which { put_stamp(ins_stamp, pids[i], i, sizes[i], mtimes[i], ctimes[i], hashes[i], now); }
    sqlite::finalize(ins_stamp);

    let calls_before = scalar(db, "SELECT COUNT(*) FROM calls");
    if changed.len == 0 && gone == 0 {
        if regroup { communities(db, gamma); }
        format(out, "\"files\":", n, ",\"looked_at\":", which.len,
               ",\"changed\":[],\"added\":[],\"removed\":[],\"calls\":", calls_before,
               ",\"calls_tied_again\":0,\"all_calls_tied_again\":false,\"files_with_calls_tied_again\":[],\"files_grouped_again\":",
               if regroup { "true" } else { "false" }, ",\"read_ms\":",
               ((clock() - t0) * 1000.0) as i64, ",\"link_ms\":0");
        return;
    }

    let ins_ch = sqlite::prepare_or_die(db, "INSERT INTO temp.u_changed (id) VALUES (?1)");
    let ins_ad = sqlite::prepare_or_die(db, "INSERT INTO temp.u_added (id) VALUES (?1)");
    for i in changed {
        sqlite::reset(ins_ch);
        sqlite::bind_int(ins_ch, 1, pids[i]);
        sqlite::step_done(ins_ch);
        if is_new[i] != 0 {
            sqlite::reset(ins_ad);
            sqlite::bind_int(ins_ad, 1, pids[i]);
            sqlite::step_done(ins_ad);
        }
    }
    sqlite::finalize(ins_ch);
    sqlite::finalize(ins_ad);

    sqlite::exec_or_die(db, "INSERT INTO temp.u_set SELECT id FROM temp.u_changed UNION SELECT id FROM temp.u_gone");
    sqlite::exec_or_die(db, KEEP_OLD_SQL);
    sqlite::exec_or_die(db, IMPORTED_FILES_SQL);
    if set_changed {
        sqlite::exec_or_die(db, """
            CREATE TEMP TABLE u_imp AS SELECT rowid AS r, file_id, COALESCE(dst, 0) AS dst FROM imports
                WHERE file_id NOT IN (SELECT id FROM temp.u_set);
            CREATE TEMP TABLE u_ali AS SELECT file_id, alias, dst FROM aliases
                WHERE file_id NOT IN (SELECT id FROM temp.u_set);
        """);
    }
    // A definition's new row never takes the number of a row just removed
    // (a row with the highest number holds the place meanwhile): a link
    // that still carries a removed row's number then names no row at all,
    // and DIRTY_SQL finds it, where it would otherwise name a stranger.
    let sym_top = scalar(db, "SELECT COALESCE(MAX(id), 0) FROM symbols");
    // (The file links about to be redone, as they are: see FILE_LINKS_SAME_SQL.)
    sqlite::exec_or_die(db, "CREATE TEMP TABLE u_fe AS SELECT src, dst, kind, weight FROM file_edges WHERE src IN (SELECT id FROM temp.u_set)");
    sqlite::exec_or_die(db, DROP_ROWS_SQL);
    if sym_top > 0 { sqlite::exec_or_die(db, str("INSERT OR IGNORE INTO symbols (id, file_id) VALUES (", sym_top, ", 0)")); }
    write_facts(db, pids, all_langs, changed, all, at, len);
    sqlite::exec_or_die(db, "DELETE FROM symbols WHERE file_id = 0 AND name IS NULL");
    settle_facts(db, true);
    if set_changed {
        // Every file's place in the walk: a file added or removed moves the rest.
        sqlite::exec_or_die(db, """
            UPDATE stamps SET ord = (SELECT w.ord FROM temp.u_walk w JOIN files f ON f.path = w.path
                                     WHERE f.id = stamps.file_id);
        """);
    }
    let t1 = clock();

    sqlite::exec_or_die(db, COMPARE_SQL);
    var all_again = false;
    if set_changed {
        // Which file an import names hangs on which files there are.
        sqlite::exec_or_die(db, "UPDATE imports SET dst = NULL WHERE dst IS NOT NULL; DELETE FROM aliases; DELETE FROM file_edges WHERE kind = 'import';");
        link_imports(db);
        sqlite::exec_or_die(db, IMPORTED_FILES_SQL);
        sqlite::exec_or_die(db, REIMPORTED_SQL);
        all_again = roots_text(db) != roots_before;
    } else {
        link_imports(db, true);
        sqlite::exec_or_die(db, IMPORTED_FILES_SQL);
    }
    sqlite::exec_or_die(db, COMPARE_IMPORTS_SQL);
    sqlite::exec_or_die(db, IMPORT_NAMES_SQL);
    sqlite::exec_or_die(db, MOVE_LINKS_SQL);

    var regrouped = true;
    if !all_again {
        sqlite::exec_or_die(db, DIRTY_SQL);
        // Past two calls in five, tying them all is the quicker way to the
        // same links (the script run on a list pays for the list at every
        // statement: 568,459 of rea's 744,581 calls took 22 s, all of them 14 s).
        all_again = scalar(db, "SELECT COUNT(*) FROM temp.dirty") * 5 > scalar(db, "SELECT COUNT(*) FROM calls") * 2;
    }
    if all_again {
        sqlite::exec_or_die(db, "DELETE FROM call_edges; DELETE FROM file_edges WHERE kind = 'call'; UPDATE calls SET note = NULL WHERE note IS NOT NULL;");
        link_calls(db);
    } else {
        sqlite::exec_or_die(db, """
            INSERT INTO temp.u_fe SELECT src, dst, kind, weight FROM file_edges
                WHERE kind = 'call' AND src IN (SELECT id FROM temp.dirty_files) AND src NOT IN (SELECT id FROM temp.u_set);
        """);
        link_calls(db, true);
        // The groups come from the files and the links between them. With
        // the same files and every link between them as it was (the usual
        // case: a change inside a function), they are as they were.
        regrouped = regroup || set_changed || scalar(db, FILE_LINKS_SAME_SQL) != 0;
    }
    if regrouped { communities(db, gamma); }
    let t2 = clock();

    let calls_now = scalar(db, "SELECT COUNT(*) FROM calls");
    format(out, "\"files\":", n, ",\"looked_at\":", which.len, ",\"changed\":");
    json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.u_changed) AND id NOT IN (SELECT id FROM temp.u_added) ORDER BY path", out);
    out.append(",\"added\":");
    json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.u_added) ORDER BY path", out);
    out.append(",\"removed\":");
    json_texts(db, "SELECT path FROM temp.u_gone ORDER BY path", out);
    format(out, ",\"calls\":", calls_now, ",\"calls_tied_again\":",
           if all_again { calls_now } else { scalar(db, "SELECT COUNT(*) FROM temp.dirty") },
           ",\"all_calls_tied_again\":", if all_again { "true" } else { "false" },
           ",\"files_with_calls_tied_again\":");
    if all_again { out.append("[]"); }
    else { json_texts(db, "SELECT path FROM files WHERE id IN (SELECT id FROM temp.dirty_files) ORDER BY path", out); }
    format(out, ",\"files_grouped_again\":", if regrouped { "true" } else { "false" },
           ",\"read_ms\":", ((t1 - t0) * 1000.0) as i64, ",\"link_ms\":", ((t2 - t1) * 1000.0) as i64);
}
