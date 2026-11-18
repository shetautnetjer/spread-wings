// How a graph compares with Swan's map of the same code.
//
// Spread-Wings links by name and by path; Swan's indexers resolve each use
// the way the compiler does (and agree with JetBrains IDEs on 99% of sampled
// references). Put side by side, the map says what the graph's definitions
// and links are worth, for each language, without anyone reading code:
//
//   links        per language of the calling file and per rule that made the
//                link: how many links, how many Swan can judge (it resolved
//                a use of that name on that line), and of those how many
//                are right (Swan's definition is in the linked file), in
//                another file of the repo, or outside the repo. A call
//                whose name several candidates share is linked to each of
//                them, the weight divided: so also how many calls were
//                judged, and how many have the right link among theirs;
//   definitions  per language and kind: the functions, methods and types
//                Swan has, and how many the graph has at the same place;
//   called       the same, for the definitions this repo's own call sites
//                reach, of any kind (a constant that holds a function is a
//                `variable` to Swan). A call whose definition the graph
//                lacks can only be linked wrongly or not at all.
//
// "At the same place" is the same file, name and line. Nothing is written
// to either database. Files changed since the map was built are left out
// (their lines may have moved), and counted.

import std;
import sqlite;
import .store;
import .compiler;

// The rows of a query as JSON objects: the first `texts` columns are
// strings, the rest numbers; `names` are the keys.
fn json_rows(db: i64, sql: const u8[:], names: const u8[:][:], texts: i64, out: u8[>..]&) {
    var err: u8[>..] = [];
    let q = sqlite::prepare_or_die(db, sql);
    var first = true;
    out.push('[');
    while sqlite::step(q, err) == 1 {
        if !first { out.push(','); }
        first = false;
        out.append("\n    {");
        for k in 0..names.len {
            if k > 0 { out.append(", "); }
            format(out, "\"", names[k], "\": ");
            if k < texts {
                var v: u8[>..] = [];
                sqlite::col_text(q, k as i32, v);
                out.push('"');
                for c in v { if c == '"' || c == '\\' { out.push('\\'); out.push(c); } else if c >= ' ' { out.push(c); } }
                out.push('"');
            } else {
                format(out, sqlite::col_int(q, k as i32));
            }
        }
        out.push('}');
    }
    sqlite::finalize(q);
    out.append(if first { "]" } else { "\n  ]" });
}

fn score_main(db_path: const u8[:], swan_db: const u8[:]) {
    var root: u8[>..] = [];
    let db, scip_time = attach_swan(db_path, swan_db, root);
    guard scalar(db, "SELECT COUNT(*) FROM pragma_table_info('symbols', 'sw') WHERE name IN ('kind', 'language', 'def_file', 'def_line', 'in_repo')") == 5 else {
        abort("spread-wings: the Swan map's symbols have no kind and language; rebuild it with a current swan");
    }

    var stale: i64[>..] = [];
    stale_files(db, root, scip_time, """
        SELECT f.id, f.path, COALESCE((SELECT x.edited_mtime FROM sw.files x WHERE x.file = f.path), -1)
        FROM files f
    """, stale);
    sqlite::exec_or_die(db, "CREATE TEMP TABLE stale (file_id INTEGER PRIMARY KEY, path TEXT)");
    for id in stale { sqlite::exec_or_die(db, str("INSERT INTO stale SELECT id, path FROM files WHERE id = ", id)); }

    sqlite::exec_or_die(db, """
        -- Swan counts lines from 0, Spread-Wings from 1.
        CREATE TEMP TABLE gdefs AS
            SELECT f.path AS path, w.name AS name, w.row - 1 AS line FROM symbols w JOIN files f ON f.id = w.file_id;
        CREATE INDEX temp.gdefs_at ON gdefs (path, name, line);

        -- A link Swan can judge: it resolved a use of the linked name on the
        -- calling line.
        CREATE TEMP TABLE judged AS
            SELECT e.rowid AS eid,
                   COALESCE(MAX(s.in_repo = 1 AND s.def_file = df.path), 0) AS good,
                   COALESCE(MAX(s.in_repo = 1), 0) AS inside
            FROM call_edges e
            JOIN files cf ON cf.id = e.file_id
            JOIN symbols d ON d.id = e.callee
            JOIN files df ON df.id = d.file_id
            JOIN sw.occurrences o ON o.file = cf.path AND o.start_line = e.row - 1
                 AND o.is_def = 0 AND o.by_name = 0 AND o.is_import = 0
            JOIN sw.symbols s ON s.id = o.symbol_id AND s.name = d.name
            WHERE e.file_id NOT IN (SELECT file_id FROM stale)
            GROUP BY e.rowid;
        CREATE INDEX temp.judged_eid ON judged (eid);

        -- The definitions this repo's own call sites reach, by Swan.
        CREATE TEMP TABLE reached AS
            SELECT DISTINCT s.id AS sid, s.language AS language, s.kind AS kind,
                   s.def_file AS def_file, s.def_line AS def_line, s.name AS name
            FROM calls c JOIN files f ON f.id = c.file_id
            JOIN sw.occurrences o ON o.file = f.path AND o.start_line = c.row - 1
                 AND o.is_def = 0 AND o.by_name = 0 AND o.is_import = 0
            JOIN sw.symbols s ON s.id = o.symbol_id AND s.name = c.callee
                 AND s.in_repo = 1 AND s.def_file IS NOT NULL
            WHERE c.file_id NOT IN (SELECT file_id FROM stale)
              AND s.def_file NOT IN (SELECT path FROM stale);
    """);

    var out: u8[>..] = [];
    format(out, "{\n  \"root\": \"", root, "\",\n  \"files_changed_since_the_map\": ", stale.len, ",\n  \"links\": ");
    json_rows(db, """
        SELECT cf.lang, e.resolution, COUNT(*), COUNT(j.eid), COALESCE(SUM(j.good), 0),
               COALESCE(SUM(j.good = 0 AND j.inside = 1), 0), COALESCE(SUM(j.inside = 0), 0),
               COUNT(DISTINCT CASE WHEN j.eid IS NOT NULL THEN e.file_id || ':' || e.row || ':' || d.name END),
               COUNT(DISTINCT CASE WHEN j.good = 1 THEN e.file_id || ':' || e.row || ':' || d.name END)
        FROM call_edges e JOIN files cf ON cf.id = e.file_id JOIN symbols d ON d.id = e.callee
        LEFT JOIN judged j ON j.eid = e.rowid
        WHERE e.file_id NOT IN (SELECT file_id FROM stale)
        GROUP BY cf.lang, e.resolution ORDER BY cf.lang, COUNT(*) DESC, e.resolution
    """, ["language", "rule", "links", "judged", "right", "other_file", "outside", "calls_judged", "calls_with_the_right_link"], 2, out);
    out.append(",\n  \"definitions\": ");
    // Swan names a constructor `<constructor>` (Java: `<init>`) and an
    // accessor `<get>size`; the graph `constructor` and `size`.
    json_rows(db, """
        SELECT s.language, s.kind, COUNT(*),
               SUM(EXISTS (SELECT 1 FROM gdefs g WHERE g.path = s.def_file AND g.line = s.def_line
                           AND g.name = CASE WHEN s.name IN ('<constructor>', '<init>') THEN 'constructor'
                                             WHEN s.name LIKE '<get>%' OR s.name LIKE '<set>%' THEN substr(s.name, 6)
                                             ELSE s.name END))
        FROM sw.symbols s
        WHERE s.in_repo = 1 AND s.def_file IS NOT NULL AND s.language <> 'swan-syntax'
          AND s.kind IN ('function', 'method', 'constructor', 'getter', 'setter', 'class', 'interface',
                         'struct', 'enum', 'trait', 'type')
          AND s.def_file NOT IN (SELECT path FROM stale)
        GROUP BY s.language, s.kind ORDER BY s.language, COUNT(*) DESC, s.kind
    """, ["language", "kind", "in_swan", "in_graph"], 2, out);
    out.append(",\n  \"called\": ");
    json_rows(db, """
        SELECT r.language, r.kind, COUNT(*),
               SUM(EXISTS (SELECT 1 FROM gdefs g WHERE g.path = r.def_file AND g.name = r.name AND g.line = r.def_line))
        FROM reached r WHERE r.language <> 'swan-syntax'
        GROUP BY r.language, r.kind ORDER BY r.language, COUNT(*) DESC, r.kind
    """, ["language", "kind", "in_swan", "in_graph"], 2, out);
    out.append("\n}");
    print(out);
    sqlite::exec_or_die(db, "DROP TABLE stale; DROP TABLE gdefs; DROP TABLE judged; DROP TABLE reached;");
    sqlite::exec_or_die(db, "DETACH DATABASE sw");
    sqlite::close(db);
}
