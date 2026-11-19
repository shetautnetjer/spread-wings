// The program's scripts and fixed texts: the SQL that builds and reads the
// graph, the patterns that read each language, the usage text and the list
// of MCP tools. Each stands with the comment written above it, and says
// where it stood in the Goose sources the program was first written in
// (retired 2026-11-18; their last form is commit d7a8db1).
//
// A change to what `index` writes for some repo (a pattern, a link script)
// raises RULES_NUMBER in store.rs; a check in tests/test.sh holds the
// fixtures' graphs to it.

// (was src/compiler.goose:96)
pub const COMPILER_SITES_SQL: &str = r#"
        -- Every call site, linked or not: a line of a file and the name
        -- called there.
        CREATE TEMP TABLE sites AS
            SELECT c.file_id, c.row, c.callee, f.path, MIN(c.in_symbol) AS caller, COUNT(*) AS ncalls
            FROM calls c JOIN files f ON f.id = c.file_id
            GROUP BY c.file_id, c.row, c.callee;
        CREATE TEMP TABLE nsites AS SELECT COUNT(*) AS n FROM sites;
        CREATE INDEX temp.sites_at ON sites (file_id, row, callee);
    "#;

// (was src/compiler.goose:109)
pub const COMPILER_STALE_SQL: &str = r#"
        SELECT f.id, f.path, COALESCE((SELECT x.edited_mtime FROM sw.files x WHERE x.file = f.path), -1)
        FROM files f WHERE f.id IN (SELECT DISTINCT file_id FROM sites)
    "#;

// (was src/compiler.goose:116)
pub const COMPILER_APPLY_SQL: &str = r#"
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
    "#;

// (was src/decide.goose:101)
// Each still-ambiguous call site, grouped by the function it sits in.
pub const DECIDE_SITES_SQL: &str = r#"
        SELECT DISTINCT c.file_id, c.row, c.callee, COALESCE(c.text, c.callee), c.in_symbol, f.path,
               COALESCE(s.row, 0), COALESCE(s.end_row, 0)
        FROM calls c JOIN files f ON f.id = c.file_id
        LEFT JOIN symbols s ON s.id = c.in_symbol
        WHERE EXISTS (SELECT 1 FROM call_edges e JOIN symbols t ON t.id = e.callee
                      WHERE e.file_id = c.file_id AND e.row = c.row AND t.name = c.callee AND e.resolution = 'by_name')
        ORDER BY c.file_id, c.in_symbol, c.row, c.callee
        "#;

// (was src/decide.goose:110)
pub const DECIDE_CANDIDATES_SQL: &str = r#"
        SELECT DISTINCT t.id, t.name, COALESCE(t.container, ''), tf.path, COALESCE(t.sig, '')
        FROM call_edges e JOIN symbols t ON t.id = e.callee JOIN files tf ON tf.id = t.file_id
        WHERE e.file_id = ?1 AND e.row = ?2 AND t.name = ?3 AND e.resolution = 'by_name'
        ORDER BY t.id
        "#;

// (was src/decide.goose:136)
pub const DECIDE_ROWS_SQL: &str = r#"
        SELECT DISTINCT c.row FROM calls c
        WHERE c.file_id = ?1 AND c.in_symbol = ?2 AND c.row >= ?3
          AND EXISTS (SELECT 1 FROM call_edges e JOIN symbols t ON t.id = e.callee
                      WHERE e.file_id = c.file_id AND e.row = c.row AND t.name = c.callee AND e.resolution = 'by_name')
        ORDER BY c.row
        "#;

// (was src/decide.goose:435)
pub const DECIDE_DROP_SQL: &str = r#"
        DELETE FROM decisions WHERE target > 0 AND NOT EXISTS (
            SELECT 1 FROM call_edges e WHERE e.file_id = decisions.file_id AND e.row = decisions.row
              AND e.callee = decisions.target AND e.resolution = 'by_name');
        CREATE TEMP TABLE clash AS
            SELECT DISTINCT a.file_id, a.row, a.callee FROM decisions a JOIN decisions b
              ON b.file_id = a.file_id AND b.row = a.row AND b.callee = a.callee AND b.rowid <> a.rowid
            WHERE a.target <> b.target OR a.p < 600 OR b.p < 600;
        DELETE FROM decisions WHERE EXISTS (
            SELECT 1 FROM clash c WHERE c.file_id = decisions.file_id AND c.row = decisions.row AND c.callee = decisions.callee);
        DROP TABLE clash;
    "#;

// (was src/decide.goose:448)
pub const DECIDE_APPLY_SQL: &str = r#"
        -- Sure about one definition: it becomes the only link, weight p.
        DELETE FROM call_edges WHERE resolution = 'by_name' AND rowid IN (
            SELECT e.rowid FROM call_edges e JOIN symbols t ON t.id = e.callee
            JOIN decisions d ON d.file_id = e.file_id AND d.row = e.row AND d.callee = t.name
            WHERE d.p >= 600 AND (d.target = 0 OR e.callee != d.target));
        UPDATE call_edges SET resolution = 'decided', weight = (
            SELECT d.p / 1000.0 FROM decisions d JOIN symbols t ON t.id = call_edges.callee
            WHERE d.file_id = call_edges.file_id AND d.row = call_edges.row AND d.callee = t.name AND d.target = call_edges.callee)
        WHERE resolution = 'by_name' AND EXISTS (
            SELECT 1 FROM decisions d WHERE d.file_id = call_edges.file_id AND d.row = call_edges.row
              AND d.target = call_edges.callee AND d.p >= 600);
        DELETE FROM file_edges WHERE kind = 'call';
    "#;

// (was src/extract.goose:25)
pub const PATTERNS_PYTHON: &str = r#"
function	NAME	def $NAME($$$A): $$$B
function	NAME	def $NAME($$$A) -> $R: $$$B
function	NAME	async def $NAME($$$A): $$$B
function	NAME	async def $NAME($$$A) -> $R: $$$B
class	NAME	class $NAME($$$A): $$$B
class	NAME	class $NAME: $$$B
import	M	import $M
import	M	from $M import $$$X
call	F	$F($$$A)
assign	X	$X = $F($$$A)
assign	X	with $F($$$A) as $X: $$$B
iter	X	for $X in $F($$$A): $$$B
bind	X	$X = $V
bind	X	$X: $T = $V
bind	X	for $X in $I: $$$B
bind	X	with $E as $X: $$$B
"#;

// (was src/extract.goose:48)
pub const PATTERNS_RUST: &str = r#"
import	P	use $P;
import	P	pub use $P;
call	F	$F($$$A)
"#;

// (was src/extract.goose:55)
// javascript, typescript, tsx
pub const PATTERNS_JS: &str = r#"
import	M	require($M)
call	F	$F($$$A)
assign	X	const $X = $F($$$A)
assign	X	let $X = $F($$$A)
bind	X	$X = $V
bind	X	let $X = $V
"#;

// (was src/extract.goose:358)
// What the records of a file need once they are all written. Each
// statement looks only within one file, so `update` runs them for the
// files it read again (temp.u_changed) and index for every file.
pub const SETTLE_SQL: &str = r#"
    -- Two patterns can match one definition (a const arrow and a call can
    -- overlap): keep one row per place.
    DELETE FROM symbols WHERE id NOT IN (
        SELECT MIN(id) FROM symbols /*only: WHERE file_id IN (SELECT id FROM temp.u_changed) */
        GROUP BY file_id, start, name)
        /*only: AND file_id IN (SELECT id FROM temp.u_changed) */;
    -- A method's container: the class, struct, trait, interface, impl or
    -- (TypeScript) object type it sits in. A function inside another
    -- function is no method, whatever class is further out: the
    -- innermost definition around it decides.
    UPDATE symbols SET container = (
        SELECT CASE WHEN c.kind = 'function' THEN NULL ELSE c.name END FROM symbols c
        WHERE c.file_id = symbols.file_id AND c.id != symbols.id
          AND c.kind IN ('class', 'struct', 'trait', 'interface', 'impl', 'type', 'function')
          AND c.start <= symbols.start AND symbols.end_ <= c.end_
        ORDER BY c.end_ - c.start LIMIT 1)
    WHERE kind = 'function' /*only: AND file_id IN (SELECT id FROM temp.u_changed) */;
    -- A call site sits in the innermost definition that spans it.
    UPDATE calls SET in_symbol = COALESCE((
        SELECT s.id FROM symbols s
        WHERE s.file_id = calls.file_id AND s.start <= calls.start AND calls.start < s.end_
          AND s.kind IN ('function', 'impl')
        ORDER BY s.end_ - s.start LIMIT 1), 0)
        /*only: WHERE file_id IN (SELECT id FROM temp.u_changed) */;
    -- A binding whose value was read (`x = f()`) is also matched by the
    -- catch-all pattern; the unknown-value twin goes.
    DELETE FROM assigns WHERE value = '?' AND EXISTS (
        SELECT 1 FROM assigns b WHERE b.file_id = assigns.file_id AND b.name = assigns.name
          AND b.start = assigns.start AND b.value <> '?')
        /*only: AND file_id IN (SELECT id FROM temp.u_changed) */;
    UPDATE assigns SET in_symbol = COALESCE((
        SELECT s.id FROM symbols s
        WHERE s.file_id = assigns.file_id AND s.start <= assigns.start AND assigns.start < s.end_
          AND s.kind IN ('function', 'impl')
        ORDER BY s.end_ - s.start LIMIT 1), 0)
        /*only: WHERE file_id IN (SELECT id FROM temp.u_changed) */;
    -- A definition's own text also matches the call pattern in some
    -- grammars; a call at a definition's exact start is not one.
    DELETE FROM calls WHERE EXISTS (
        SELECT 1 FROM symbols s WHERE s.file_id = calls.file_id AND s.start = calls.start)
        /*only: AND file_id IN (SELECT id FROM temp.u_changed) */;
"#;

// (was src/graph.goose:86)
// A Python module below a folder that is a place imports start from: the
// path ends in /<module path>, and the folder holding the module's first
// segment has no __init__.py (if it had one, the module's real name would
// start with that folder's). So `import mypkg.core` finds
// python/mypkg/core.py, and does not find a/b/mypkg/core.py when a/b is a
// package. pysuf holds every such ending of every Python path, so one
// import is one indexed lookup; the shortest path wins, and of two as short
// the one the walk met first (`ord`: a file's row number says that only in
// a graph no update has added files to).
pub const PKG_SUFFIX_SQL: &str = r#"
    CREATE TEMP TABLE pysuf (suffix TEXT, id INTEGER, len INTEGER, ord INTEGER);
    WITH RECURSIVE s(id, path, rest) AS (
        SELECT id, path, substr(path, instr(path, '/') + 1) FROM files
        WHERE lang = 'python' AND instr(path, '/') > 0
        UNION ALL
        SELECT id, path, substr(rest, instr(rest, '/') + 1) FROM s WHERE instr(rest, '/') > 0)
    INSERT INTO pysuf SELECT rest, id, length(path), COALESCE((SELECT t.ord FROM stamps t WHERE t.file_id = s.id), s.id) FROM s
        WHERE NOT EXISTS (SELECT 1 FROM files g
                          WHERE g.path = substr(s.path, 1, length(s.path) - length(s.rest)) || '__init__.py');
    CREATE INDEX pysuf_suffix ON pysuf(suffix, len, ord, id);
"#;

// (was src/graph.goose:221)
// The imports to tie are listed first, then read from the list: the
// loop below writes each one's file into the row it came from, and a
// row found through an index on what is being written (which is how
// the imports of a few files are found) can come round a second time.
pub const IMPORTS_TODO_SQL: &str = r#"
        DROP TABLE IF EXISTS temp.imp_todo;
        CREATE TEMP TABLE imp_todo AS
            SELECT i.file_id, f.path, f.lang, i.module, i.rowid AS r, COALESCE(i.names, '') AS names
            FROM imports i JOIN files f ON f.id = i.file_id
            /*only: WHERE i.file_id IN (SELECT id FROM temp.u_changed) */
            ORDER BY i.rowid;
    "#;

// (was src/graph.goose:330)
pub const ROOTS_SQL: &str = r#"
        DROP TABLE IF EXISTS temp.roots;
        CREATE TEMP TABLE roots AS
            SELECT DISTINCT substr(path, 1, instr(path || '/', '/') - 1) AS seg FROM files
            UNION SELECT DISTINCT replace(substr(path, 1, instr(path || '/', '/') - 1), '-', '_') FROM files
            UNION SELECT DISTINCT replace(path, '.py', '') FROM files WHERE instr(path, '/') = 0
            UNION SELECT DISTINCT substr(substr(path, 5), 1, instr(substr(path, 5) || '/', '/') - 1)
                  FROM files WHERE path LIKE 'src/%'
            -- every folder that is a Python package, wherever it is kept
            UNION SELECT DISTINCT replace(d, rtrim(d, replace(d, '/', '')), '')
                  FROM (SELECT substr(path, 1, length(path) - 12) AS d FROM files WHERE substr(path, -12) = '/__init__.py')
            UNION SELECT 'crate' UNION SELECT 'self' UNION SELECT 'super' UNION SELECT '';
    "#;

// (was src/graph.goose:359)
pub const LINK_CALLS_SQL: &str = r#"
        CREATE TEMP TABLE defs AS
            SELECT s.id AS sid, s.file_id AS sfile, s.name AS name FROM symbols s
            WHERE s.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface');
        -- One index, by name and then file: with a second one on the name
        -- alone, SQLite took that for "the definitions of this name in that
        -- imported file" and read every definition of the name for each
        -- import of each call (13 s of morluto/rea's 29 s link step once a
        -- common method name had 600 definitions).
        CREATE INDEX defs_name_file ON defs(name, sfile);
        CREATE TEMP TABLE ndefs AS SELECT name, COUNT(*) AS n FROM defs GROUP BY name;
        CREATE INDEX ndefs_name ON ndefs(name);
        -- Candidate definitions per call site. A name defined in at most 50
        -- places: all of them. A commoner name (`_write`, `main`, `run`): only
        -- the definitions in the caller's own file and in files it imports,
        -- which is all the import rules below can use. (Before, such a call
        -- had no candidates at all, so even `helper()` beside `def helper`
        -- went unlinked: 2,814 calls on Graphify's repo.)
        CREATE TEMP TABLE cands AS
            SELECT c.rowid AS cid, c.file_id AS cfile, c.callee AS name, d.sid, d.sfile, k.n
            FROM calls c JOIN ndefs k ON k.name = c.callee AND k.n <= 50
            JOIN defs d ON d.name = c.callee
            /*dirty: WHERE c.rowid IN (SELECT cid FROM temp.dirty) */
            UNION ALL
            SELECT c.rowid, c.file_id, c.callee, d.sid, d.sfile, k.n
            FROM calls c JOIN ndefs k ON k.name = c.callee AND k.n > 50
            JOIN defs d ON d.name = c.callee AND d.sfile = c.file_id
            /*dirty: WHERE c.rowid IN (SELECT cid FROM temp.dirty) */
            UNION ALL
            -- (CROSS JOIN keeps this order: the few common names first.)
            SELECT DISTINCT c.rowid, c.file_id, c.callee, d.sid, d.sfile, k.n
            FROM ndefs k CROSS JOIN calls c ON c.callee = k.name
            CROSS JOIN imports i ON i.file_id = c.file_id AND i.dst > 0 AND i.dst <> c.file_id
            CROSS JOIN defs d ON d.name = c.callee AND d.sfile = i.dst
            WHERE k.n > 50 /*dirty: AND c.rowid IN (SELECT cid FROM temp.dirty) */;
        CREATE INDEX cands_cid ON cands(cid);
        -- A call reaches a definition of its own language: a TypeScript
        -- `open()` is not the Rust `fn open` of the same repo. TypeScript,
        -- TSX and JavaScript are one language here.
        DELETE FROM cands WHERE
            (SELECT CASE WHEN lang IN ('typescript', 'tsx', 'javascript') THEN 'js' ELSE lang END FROM files WHERE id = cfile)
            <> (SELECT CASE WHEN lang IN ('typescript', 'tsx', 'javascript') THEN 'js' ELSE lang END FROM files WHERE id = sfile);
        -- A call on an object (`x.f()`) is not a call of a plain function, in
        -- the languages where a module's function is not reached with a dot:
        -- Rust (`m::f()`), and TypeScript and JavaScript unless the name
        -- before the dot is imported from the function's file (`import * as
        -- m`, `import m from`). (Against Swan, same day: morluto/rea 19,901
        -- such TypeScript links, 471 right; relate 9,381 Rust links, 14 right.)
        DELETE FROM cands WHERE sid IN (SELECT id FROM symbols WHERE COALESCE(container, '') = '')
          AND cid IN (SELECT k.rowid FROM calls k JOIN files f ON f.id = k.file_id
                      WHERE f.lang IN ('typescript', 'tsx', 'javascript', 'rust')
                        AND length(COALESCE(k.text, '')) > length(k.callee) + 1
                        AND substr(k.text, -(length(k.callee) + 1)) = '.' || k.callee /*dirty: AND k.rowid IN (SELECT cid FROM temp.dirty) */)
          AND NOT EXISTS (SELECT 1 FROM calls k JOIN imports i ON i.file_id = k.file_id AND i.dst = cands.sfile
                          WHERE k.rowid = cands.cid
                            AND instr(',' || REPLACE(COALESCE(i.names, ''), '@', '') || ',',
                                      ',' || substr(k.text, 1, instr(k.text, '.') - 1) || ',') > 0);
        -- A method call on a local object is not a call to a module-level
        -- function of that name: `seen.add(x)` where `seen = set()`, or
        -- `G.add_edge(...)` on a parameter G, beside `def add(...)` in the
        -- file. When the receiver is a variable bound in the function (or at
        -- module level) or one of its parameters, only methods are candidates.
        -- (PyCharm on Graphify's repo: 4 of 300 sampled import/same-file links
        -- were this mistake.)
        DELETE FROM cands WHERE sid IN (SELECT id FROM symbols WHERE COALESCE(container, '') = '')
          AND cid IN (
            SELECT k.rowid FROM calls k
            WHERE instr(COALESCE(k.text, ''), '.') > 1 /*dirty: AND k.rowid IN (SELECT cid FROM temp.dirty) */
              AND (EXISTS (SELECT 1 FROM assigns a WHERE a.file_id = k.file_id AND a.in_symbol IN (k.in_symbol, 0)
                           AND a.name = substr(k.text, 1, instr(k.text, '.') - 1))
                   OR EXISTS (SELECT 1 FROM symbols s WHERE s.id = k.in_symbol
                              AND instr(COALESCE(s.params, ''), ',' || substr(k.text, 1, instr(k.text, '.') - 1) || ',') > 0)));
        CREATE TEMP TABLE chosen (cid INTEGER, sid INTEGER, resolution TEXT);
        CREATE TEMP TABLE done (cid INTEGER PRIMARY KEY);

        -- A bare call of a name the function itself binds (a parameter, or a
        -- variable assigned in it) is a call of that value, whatever else
        -- shares the name: `def run(render): render(x)`, `install, uninstall
        -- = PAIR[name]; install()`. The function's scope comes before the
        -- file's definitions and imports. Recorded, not linked, never asked.
        UPDATE calls SET note = 'local_value'
        WHERE in_symbol > 0 AND rowid IN (SELECT cid FROM cands)
          AND instr(COALESCE(text, callee), '.') = 0 AND instr(COALESCE(text, callee), '::') = 0
          -- unless the function also defines it (`def name(...)` nested
          -- after a loop variable `name`): the definition is what is called
          AND NOT EXISTS (SELECT 1 FROM symbols o JOIN symbols d ON d.file_id = o.file_id AND d.name = calls.callee
                          WHERE o.id = calls.in_symbol AND d.id != o.id AND d.row >= o.row AND d.end_row <= o.end_row)
          AND (EXISTS (SELECT 1 FROM assigns b WHERE b.file_id = calls.file_id AND b.name = calls.callee
                       AND b.in_symbol = calls.in_symbol)
               OR EXISTS (SELECT 1 FROM symbols s WHERE s.id = calls.in_symbol
                          AND instr(COALESCE(s.params, ''), ',' || calls.callee || ',') > 0));
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'local_value'
            /*dirty: AND rowid IN (SELECT cid FROM temp.dirty) */;

        -- A bare call (`f(x)`) is not a call of a method: a method is reached
        -- through an object or a type. (Against Swan on relatedb/relate,
        -- 2026-11-18: 2,309 Rust links from a bare call to a method, 150
        -- right, most of those to a function nested in a method, which is
        -- no method.)
        -- (After the rule above: a parameter called bare is noted as the
        -- value it is, whatever else has its name.)
        DELETE FROM cands WHERE sid IN (SELECT id FROM symbols WHERE COALESCE(container, '') <> '')
          AND cid IN (SELECT k.rowid FROM calls k
                      WHERE instr(COALESCE(k.text, k.callee), '.') = 0 AND instr(COALESCE(k.text, k.callee), '::') = 0 /*dirty: AND k.rowid IN (SELECT cid FROM temp.dirty) */);

        -- The type the call itself names. `this.f()`, `self.f()` and
        -- `Self::f()` are the f of the type the calling method belongs to;
        -- `Pair::new()` and `Session.create()` the f of that type (a name
        -- with a capital and a small letter: `LOGGER.info()` is a call on a
        -- value). The definitions of the caller's own file first, then any.
        -- (Against Swan, 2026-11-18, links whose type matched: relatedb/relate
        -- Rust 8,405 of 8,480 right; morluto/rea TypeScript 1,642 of 1,669.)
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'own_type' FROM cands c JOIN calls k ON k.rowid = c.cid
            JOIN symbols me ON me.id = k.in_symbol JOIN symbols d ON d.id = c.sid
            WHERE c.cid NOT IN (SELECT cid FROM done) AND k.qual IN ('this', 'self', 'Self')
              AND COALESCE(me.container, '') <> '' AND d.container = me.container AND c.sfile = c.cfile;
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'own_type' FROM cands c JOIN calls k ON k.rowid = c.cid
            JOIN symbols me ON me.id = k.in_symbol JOIN symbols d ON d.id = c.sid
            WHERE c.cid NOT IN (SELECT cid FROM done) AND k.qual IN ('this', 'self', 'Self')
              AND COALESCE(me.container, '') <> '' AND d.container = me.container;
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'type_name' FROM cands c JOIN calls k ON k.rowid = c.cid JOIN symbols d ON d.id = c.sid
            WHERE c.cid NOT IN (SELECT cid FROM done) AND k.qual GLOB '[A-Z]*[a-z]*' AND k.qual <> 'Self'
              AND d.container = k.qual AND c.sfile = c.cfile;
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'type_name' FROM cands c JOIN calls k ON k.rowid = c.cid JOIN symbols d ON d.id = c.sid
            WHERE c.cid NOT IN (SELECT cid FROM done) AND k.qual GLOB '[A-Z]*[a-z]*' AND k.qual <> 'Self'
              AND d.container = k.qual;
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;
        -- A type is named and none of the candidates is that type's: f
        -- belongs to a type this repo does not define (`Vec::new()`,
        -- `Promise.all()`) or comes to it from a trait or a parent, and the
        -- methods of other types are not what is called. (relate: 5,211 such
        -- Rust links, 248 right; rea: 1,277 TypeScript links, 3 right.)
        DELETE FROM cands WHERE cid NOT IN (SELECT cid FROM done)
          AND cid IN (SELECT k.rowid FROM calls k WHERE k.qual GLOB '[A-Z]*[a-z]*' AND k.qual <> 'Self' /*dirty: AND k.rowid IN (SELECT cid FROM temp.dirty) */)
          AND sid IN (SELECT id FROM symbols WHERE COALESCE(container, '') <> '');

        INSERT INTO chosen SELECT cid, sid, 'same_file' FROM cands WHERE sfile = cfile AND cid NOT IN (SELECT cid FROM done);
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- A function imported under another name (`from .global_graph import
        -- global_add as _global_add`): a bare call of the new name is a call
        -- of the original, in the file the import names. The imports' names
        -- hold `orig>bound` for these.
        CREATE TEMP TABLE fn_alias AS
            WITH RECURSIVE sp(file_id, dst, tok, rest) AS (
                SELECT file_id, dst, '', names || ',' FROM imports WHERE dst > 0 AND instr(names, '>') > 0
                UNION ALL SELECT file_id, dst, substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1)
                FROM sp WHERE rest <> '')
            SELECT DISTINCT file_id, dst, substr(tok, 1, instr(tok, '>') - 1) AS orig, substr(tok, instr(tok, '>') + 1) AS bound
            FROM sp WHERE instr(tok, '>') > 1;
        INSERT INTO chosen
            SELECT k.rowid, d.sid, 'imported_name' FROM calls k
            JOIN fn_alias a ON a.file_id = k.file_id AND a.bound = k.callee
            JOIN defs d ON d.name = a.orig AND d.sfile = a.dst
            WHERE k.rowid NOT IN (SELECT cid FROM done) AND instr(COALESCE(k.text, k.callee), '.') = 0
              -- (EXISTS, not IN: a filter on the rows the joins above give.
              -- As a list to start from, it had SQLite read the renamed
              -- imports once per listed call: 1.2 s for 64,385 calls.)
              /*dirty: AND EXISTS (SELECT 1 FROM temp.dirty z WHERE z.cid = k.rowid) */;
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;
        DROP TABLE fn_alias;

        INSERT INTO chosen
            SELECT c.cid, c.sid, 'imported_name' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done)
              -- the imported name is the module-level definition, called
              -- bare: `from m import add` says nothing about `seen.add(x)`
              -- or about a method named add in m.
              AND (SELECT instr(COALESCE(k.text, k.callee), '.') FROM calls k WHERE k.rowid = c.cid) = 0
              AND (SELECT COALESCE(y.container, '') FROM symbols y WHERE y.id = c.sid) = ''
              AND EXISTS (SELECT 1 FROM imports i WHERE i.file_id = c.cfile AND i.dst = c.sfile
                          AND (',' || i.names || ',') LIKE ('%,' || c.name || ',%'));
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- Files that pass a name on (`from .base import f` in a module that
        -- only re-exports f), up to three files deep: prov(file, name, sfile)
        -- means importing name from file reaches sfile's definition.
        CREATE TEMP TABLE pend AS SELECT DISTINCT name FROM cands WHERE cid NOT IN (SELECT cid FROM done);
        CREATE TEMP TABLE prov AS SELECT d.sfile AS file_id, d.name AS name, d.sfile AS sfile, 0 AS hop
            FROM defs d WHERE d.name IN (SELECT name FROM pend);
        CREATE INDEX prov_file ON prov(file_id, name);
        INSERT INTO prov SELECT DISTINCT i.file_id, p.name, p.sfile, 1 FROM prov p
            JOIN imports i ON i.dst = p.file_id
            WHERE p.hop = 0 AND i.file_id != p.sfile
              AND (',' || i.names || ',') LIKE ('%,' || p.name || ',%')
              AND NOT EXISTS (SELECT 1 FROM prov q WHERE q.file_id = i.file_id AND q.name = p.name AND q.sfile = p.sfile);
        INSERT INTO prov SELECT DISTINCT i.file_id, p.name, p.sfile, 2 FROM prov p
            JOIN imports i ON i.dst = p.file_id
            WHERE p.hop = 1 AND i.file_id != p.sfile
              AND (',' || i.names || ',') LIKE ('%,' || p.name || ',%')
              AND NOT EXISTS (SELECT 1 FROM prov q WHERE q.file_id = i.file_id AND q.name = p.name AND q.sfile = p.sfile);
        INSERT INTO prov SELECT DISTINCT i.file_id, p.name, p.sfile, 3 FROM prov p
            JOIN imports i ON i.dst = p.file_id
            WHERE p.hop = 2 AND i.file_id != p.sfile
              AND (',' || i.names || ',') LIKE ('%,' || p.name || ',%')
              AND NOT EXISTS (SELECT 1 FROM prov q WHERE q.file_id = i.file_id AND q.name = p.name AND q.sfile = p.sfile);

        INSERT INTO chosen
            SELECT c.cid, c.sid, 'imported_name' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM imports i JOIN prov p ON p.file_id = i.dst AND p.name = c.name
                          WHERE i.file_id = c.cfile AND p.sfile = c.sfile AND p.hop >= 1
                            AND (',' || i.names || ',') LIKE ('%,' || c.name || ',%'));
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- Called through a name bound to a module: `llm.f()` after
        -- `from graphify import llm`, `x.f()` after `import a.b as x`,
        -- `state::f()` after `use crate::state;`.
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'module_alias' FROM cands c JOIN calls k ON k.rowid = c.cid
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM aliases a WHERE a.file_id = c.cfile AND a.dst = c.sfile
                          AND (k.text = a.alias || '.' || c.name OR k.text = a.alias || '::' || c.name));
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- The same through a module that re-exports the name
        -- (`extract._cpp_preprocess`, defined in extractors/fortran.py).
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'module_alias' FROM cands c JOIN calls k ON k.rowid = c.cid
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM aliases a JOIN prov p ON p.file_id = a.dst AND p.name = c.name
                          WHERE a.file_id = c.cfile AND p.sfile = c.sfile AND p.hop >= 1
                            AND (k.text = a.alias || '.' || c.name OR k.text = a.alias || '::' || c.name));
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- A builtin method name (dict.get, list.append, str.join, Path.resolve,
        -- Array.push, Option.unwrap, ...) called on an object, when no
        -- candidate definition is in a file the caller imports: a library or
        -- builtin call, not this repo's. Recorded on the call, not linked.
        -- (Checked against Span-02's answers on Graphify's repo; see
        -- docs/DESIGN.md.)
        UPDATE calls SET note = 'builtin_method'
        WHERE rowid IN (SELECT cid FROM cands)
          AND rowid NOT IN (SELECT cid FROM done)
          AND (instr(COALESCE(text, ''), '.') > 0 OR instr(COALESCE(text, ''), '::') > 0)
          AND callee IN ('get', 'set', 'items', 'keys', 'values', 'add', 'append', 'extend', 'insert',
                         'pop', 'remove', 'update', 'clear', 'copy', 'join', 'split', 'strip', 'replace',
                         'format', 'startswith', 'endswith', 'lower', 'upper', 'encode', 'decode', 'read',
                         'write', 'close', 'open', 'resolve', 'exists', 'unlink', 'mkdir', 'glob', 'iterdir',
                         'read_text', 'write_text', 'push', 'map', 'filter', 'forEach', 'reduce', 'find',
                         'includes', 'has', 'delete', 'then', 'catch', 'slice', 'splice', 'toString',
                         'unwrap', 'expect', 'clone', 'iter', 'collect', 'len', 'is_empty', 'contains',
                         'to_string', 'as_str', 'into', 'from', 'next', 'sort', 'reverse', 'count', 'index',
                         'match', 'search', 'sub', 'group', 'patch', 'assert_called_once', 'assert_called_with')
          AND NOT EXISTS (SELECT 1 FROM cands k JOIN imports i ON i.file_id = k.cfile AND i.dst = k.sfile
                          WHERE k.cid = calls.rowid)
          AND NOT EXISTS (SELECT 1 FROM cands k JOIN aliases a ON a.file_id = k.cfile AND a.dst = k.sfile
                          WHERE k.cid = calls.rowid);
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'builtin_method'
            /*dirty: AND rowid IN (SELECT cid FROM temp.dirty) */;

        -- Names bound by an import from outside the repo (`import shutil`,
        -- `import networkx as nx`, `from unittest.mock import patch`,
        -- `use std::fs`, `import React from "react"`): an import with no file,
        -- whose first segment isn't one of the repo's own top-level names.
        -- (temp.roots: make_roots, before this script.)
        CREATE TEMP TABLE ext (file_id INTEGER, name TEXT, module TEXT);
        WITH RECURSIVE
            imp AS (SELECT file_id, module, COALESCE(names, '') AS names,
                           replace(replace(module, '::', '.'), '/', '.') || '.' AS m
                    FROM imports WHERE dst IS NULL OR dst = 0),
            outside AS (SELECT file_id, module, names, substr(m, 1, instr(m, '.') - 1) AS seg FROM imp
                        WHERE substr(m, 1, instr(m, '.') - 1) NOT IN (SELECT seg FROM roots)),
            sp(file_id, module, name, rest) AS (
                SELECT file_id, module, '', names || ',' FROM outside
                UNION ALL SELECT file_id, module, substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1)
                FROM sp WHERE rest <> '')
        INSERT INTO ext
            SELECT file_id, CASE WHEN substr(name, 1, 1) = '@' THEN substr(name, 2) ELSE name END, module FROM sp
            WHERE name <> '' AND instr(name, '>') = 0
            UNION SELECT file_id, seg, module FROM outside WHERE names = '';
        CREATE INDEX ext_file ON ext(file_id, name);

        -- A call through such a name (`shutil.rmtree`, `nx.Graph`, `patch(...)`):
        -- not this repo's. Recorded on the call, not linked.
        UPDATE calls SET note = 'external'
        WHERE rowid IN (SELECT cid FROM cands)
          AND rowid NOT IN (SELECT cid FROM done)
          AND EXISTS (SELECT 1 FROM ext x WHERE x.file_id = calls.file_id AND x.name =
                CASE WHEN instr(replace(COALESCE(text, callee), '::', '.'), '.') > 0
                     THEN substr(replace(text, '::', '.'), 1, instr(replace(text, '::', '.'), '.') - 1)
                     ELSE callee END);
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'external'
            /*dirty: AND rowid IN (SELECT cid FROM temp.dirty) */;

        -- A bare call to a Python builtin (`set()`, `len()`, `sorted()`) the
        -- file neither defines nor imports.
        UPDATE calls SET note = 'builtin'
        WHERE rowid IN (SELECT cid FROM cands)
          AND rowid NOT IN (SELECT cid FROM done)
          AND instr(COALESCE(text, callee), '.') = 0
          AND (SELECT lang FROM files WHERE id = calls.file_id) = 'python'
          AND callee IN ('set', 'dict', 'list', 'tuple', 'str', 'int', 'float', 'bool', 'bytes', 'frozenset',
                         'len', 'print', 'open', 'sorted', 'reversed', 'min', 'max', 'sum', 'any', 'all', 'map',
                         'filter', 'zip', 'enumerate', 'range', 'isinstance', 'issubclass', 'getattr', 'setattr',
                         'hasattr', 'delattr', 'type', 'iter', 'next', 'repr', 'round', 'abs', 'super', 'vars',
                         'id', 'hash', 'format', 'input', 'object', 'property', 'staticmethod', 'classmethod',
                         'divmod', 'pow', 'ord', 'chr', 'callable', 'exec', 'eval', 'compile', 'globals',
                         'locals', 'dir', 'slice', 'bytearray', 'memoryview', 'complex')
          AND NOT EXISTS (SELECT 1 FROM imports i WHERE i.file_id = calls.file_id
                          AND (',' || i.names || ',') LIKE ('%,' || calls.callee || ',%'));
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'builtin'
            /*dirty: AND rowid IN (SELECT cid FROM temp.dirty) */;

        -- Variables holding outside objects: `G = nx.Graph()`, `m = re.match(...)`,
        -- `with open(p) as f`, `parser = ArgumentParser()`, or a parameter
        -- typed `G: nx.Graph`. A variable counts only when every binding of
        -- it in that scope is from an outside module, an outside name, a
        -- builtin or another such variable. Every binding: the extractor
        -- also records the ones whose value it can't read (`x = other`, a
        -- tuple target, `for x in`, `with e as x`, `except E as x`) with the
        -- value `?`, which is never outside. The scope is the function; for
        -- a module-level variable it is the whole file, since a function can
        -- rebind it (`global x`). Two rounds, so `PAT = re.compile(...)`
        -- then `m = PAT.match(...)` both count.
        -- Each binding: the root of its value (`nx` in `nx.Graph`), whether the
        -- value is one bare name, and whether the name is bound by iterating
        -- the value (`for m in PAT.finditer(s)`, stored as `iter:PAT.finditer`).
        -- ok: the binding is from outside; lib: from a library, not a builtin
        -- container (what a `list()` yields can be anything, the repo's own
        -- objects included, so iterating one proves nothing).
        CREATE TEMP TABLE asg AS SELECT file_id, in_symbol, name,
            CASE WHEN instr(v, '.') > 0 THEN substr(v, 1, instr(v, '.') - 1) ELSE v END AS vroot,
            instr(v, '.') = 0 AS bare, it, 0 AS ok, 0 AS lib
            FROM (SELECT file_id, in_symbol, name, value LIKE 'iter:%' AS it,
                         CASE WHEN value LIKE 'iter:%' THEN substr(value, 6) ELSE value END AS v FROM assigns
                         /*dirty: WHERE file_id IN (SELECT id FROM temp.dirty_files) */);
        -- importlib.import_module / reload and __import__ return modules,
        -- which can be this repo's own: never outside objects, under any
        -- name they were imported as (`import importlib as il`).
        DELETE FROM ext WHERE name IN ('importlib', '__import__', 'import_module', 'reload')
                           OR module = 'importlib' OR module LIKE 'importlib.%';
        CREATE INDEX asg_root ON asg(file_id, vroot);
        CREATE INDEX asg_scope ON asg(file_id, in_symbol, name);
        CREATE INDEX asg_name ON asg(file_id, name, in_symbol);
        -- Repo functions whose return annotation is an outside type
        -- (`def build_from_json(...) -> nx.Graph:`): what they return is an
        -- outside object too. Per file for a name the file defines itself,
        -- else only when every definition of the name in the repo agrees.
        CREATE TEMP TABLE retdef AS
            SELECT d.name, d.sfile, EXISTS (
                SELECT 1 FROM symbols s JOIN ext x ON x.file_id = s.file_id
                WHERE s.id = d.sid AND s.sig IS NOT NULL AND instr(s.sig, '->') > 0 AND instr(s.sig, x.name) > 0
                  AND (s.sig GLOB '*-> ' || x.name || '[^A-Za-z0-9_]*' OR s.sig GLOB '*-> "' || x.name || '[^A-Za-z0-9_]*'
                       OR s.sig GLOB '*-> Optional[[]' || x.name || '[^A-Za-z0-9_]*')) AS out
            FROM defs d /*dirty: WHERE d.name IN (SELECT vroot FROM asg) */;
        CREATE INDEX retdef_name ON retdef(name, sfile);
        CREATE TEMP TABLE extvar (file_id INTEGER, in_symbol INTEGER, name TEXT, lib INTEGER);
        CREATE INDEX extvar_name ON extvar(file_id, name, in_symbol);

        -- Round one: bound from an outside import, from a repo function that
        -- returns an outside type, or (not when iterating) from a builtin.
        UPDATE asg SET ok = 1, lib = 1 WHERE EXISTS (SELECT 1 FROM ext x WHERE x.file_id = asg.file_id AND x.name = asg.vroot);
        UPDATE asg SET ok = 1, lib = 1 WHERE ok = 0 AND it = 0 AND bare
            AND CASE WHEN EXISTS (SELECT 1 FROM retdef r WHERE r.name = asg.vroot AND r.sfile = asg.file_id)
                     THEN NOT EXISTS (SELECT 1 FROM retdef r WHERE r.name = asg.vroot AND r.sfile = asg.file_id AND r.out = 0)
                     ELSE EXISTS (SELECT 1 FROM retdef r WHERE r.name = asg.vroot)
                          AND NOT EXISTS (SELECT 1 FROM retdef r WHERE r.name = asg.vroot AND r.out = 0) END;
        -- ... or from a parameter typed with an outside name (`g: nx.Graph`,
        -- then `for node in g.nodes()` or `h = g.copy()`).
        UPDATE asg SET ok = 1, lib = 1 WHERE ok = 0 AND in_symbol > 0 AND EXISTS (
            SELECT 1 FROM symbols s JOIN ext x ON x.file_id = s.file_id
            WHERE s.id = asg.in_symbol AND s.sig IS NOT NULL
              AND instr(COALESCE(s.params, ''), ',' || asg.vroot || ',') > 0 AND instr(s.sig, x.name) > 0
              AND (s.sig GLOB '*[( ]' || asg.vroot || ': ' || x.name || '[^A-Za-z0-9_]*'
                   OR s.sig GLOB '*[( ]' || asg.vroot || ': "' || x.name || '[^A-Za-z0-9_]*'
                   OR s.sig GLOB '*[( ]' || asg.vroot || ': Optional[[]' || x.name || '[^A-Za-z0-9_]*'));
        UPDATE asg SET ok = 1 WHERE ok = 0 AND it = 0 AND bare AND vroot IN ('set', 'dict', 'list', 'tuple', 'str', 'int', 'float', 'bool', 'bytes', 'frozenset', 'open', 'sorted',
                       'reversed', 'map', 'filter', 'zip', 'enumerate', 'range', 'iter', 'type', 'object', 'super')
            AND NOT EXISTS (SELECT 1 FROM defs d WHERE d.sfile = asg.file_id AND d.name = asg.vroot);
        INSERT INTO extvar
            SELECT a.file_id, a.in_symbol, a.name, MIN(a.lib) FROM asg a
            GROUP BY a.file_id, a.in_symbol, a.name
            HAVING MIN(a.ok) = 1
               AND (a.in_symbol <> 0 OR NOT EXISTS (SELECT 1 FROM asg b WHERE b.file_id = a.file_id AND b.name = a.name AND b.ok = 0));
        -- Round two: bound from such a variable (`m = PAT.match(...)`), or by
        -- iterating a library one (`for m in PAT.finditer(...)`,
        -- `for u, v in G.edges()`).
        UPDATE asg SET ok = 1,
               lib = (SELECT MIN(v.lib) FROM extvar v WHERE v.file_id = asg.file_id AND v.name = asg.vroot
                      AND v.in_symbol IN (asg.in_symbol, 0))
            WHERE ok = 0 AND EXISTS (SELECT 1 FROM extvar v WHERE v.file_id = asg.file_id AND v.name = asg.vroot
                                     AND v.in_symbol IN (asg.in_symbol, 0) AND (asg.it = 0 OR v.lib = 1));
        INSERT INTO extvar
            SELECT a.file_id, a.in_symbol, a.name, MIN(a.lib) FROM asg a
            WHERE NOT EXISTS (SELECT 1 FROM extvar v WHERE v.file_id = a.file_id AND v.in_symbol = a.in_symbol AND v.name = a.name)
            GROUP BY a.file_id, a.in_symbol, a.name
            HAVING MIN(a.ok) = 1
               AND (a.in_symbol <> 0 OR NOT EXISTS (SELECT 1 FROM asg b WHERE b.file_id = a.file_id AND b.name = a.name AND b.ok = 0));

        UPDATE calls SET note = 'outside_object'
        WHERE rowid IN (SELECT cid FROM cands)
          AND rowid NOT IN (SELECT cid FROM done)
          AND instr(replace(COALESCE(text, ''), '::', '.'), '.') > 0
          AND (
            EXISTS (SELECT 1 FROM extvar v WHERE v.file_id = calls.file_id
                    AND v.name = substr(text, 1, instr(text, '.') - 1)
                    AND (v.in_symbol = calls.in_symbol
                         -- a module-level variable, unless the function has
                         -- its own: a local binding, or a parameter of that name
                         OR (v.in_symbol = 0 AND NOT EXISTS (SELECT 1 FROM asg b WHERE b.file_id = calls.file_id
                                AND b.in_symbol = calls.in_symbol AND b.name = v.name)
                             AND NOT EXISTS (SELECT 1 FROM symbols s WHERE s.id = calls.in_symbol
                                AND instr(COALESCE(s.params, ''), ',' || v.name || ',') > 0))))
            -- a parameter typed with an outside name: `(G: nx.Graph`, `, g: Graph)`.
            -- The type must end there: `g: GraphView` is not `Graph`.
            OR EXISTS (SELECT 1 FROM symbols s JOIN ext x ON x.file_id = s.file_id
                       WHERE s.id = calls.in_symbol AND s.sig IS NOT NULL
                         AND instr(COALESCE(s.params, ''), ',' || substr(text, 1, instr(text, '.') - 1) || ',') > 0
                         AND instr(s.sig, x.name) > 0
                         AND (s.sig GLOB '*[( ]' || substr(text, 1, instr(text, '.') - 1) || ': ' || x.name || '[^A-Za-z0-9_]*'
                              OR s.sig GLOB '*[( ]' || substr(text, 1, instr(text, '.') - 1) || ': "' || x.name || '[^A-Za-z0-9_]*'
                              OR s.sig GLOB '*[( ]' || substr(text, 1, instr(text, '.') - 1) || ': Optional[[]' || x.name || '[^A-Za-z0-9_]*')));
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'outside_object'
            /*dirty: AND rowid IN (SELECT cid FROM temp.dirty) */;

        -- The caller's file imports a file that defines the name. Weaker
        -- than the rules above (the import names the file, not this name),
        -- so it comes after them: `m.render()` on a regex match is an
        -- outside call even when the file imports a module with a render().
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'imported_file' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM imports i WHERE i.file_id = c.cfile AND i.dst = c.sfile);
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- A bare call of a name that is a parameter of the function, or a
        -- variable bound in it or at module level (`compute(...)` where
        -- compute was passed in, `ids = lambda ...`): the callee is whatever
        -- value that name holds, not some definition elsewhere that shares
        -- the name. Recorded, not linked, and never a question.
        UPDATE calls SET note = 'local_value'
        WHERE rowid IN (SELECT cid FROM cands)
          AND rowid NOT IN (SELECT cid FROM done)
          AND instr(COALESCE(text, callee), '.') = 0 AND instr(COALESCE(text, callee), '::') = 0
          AND (EXISTS (SELECT 1 FROM asg b WHERE b.file_id = calls.file_id AND b.name = calls.callee
                       AND b.in_symbol IN (calls.in_symbol, 0))
               OR EXISTS (SELECT 1 FROM symbols s WHERE s.id = calls.in_symbol
                          AND instr(COALESCE(s.params, ''), ',' || calls.callee || ',') > 0));
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'local_value'
            /*dirty: AND rowid IN (SELECT cid FROM temp.dirty) */;

        -- Not for `self.f()` / `this.f()`: when the caller's own type has no
        -- f here and no imported file does, f comes from a parent or a
        -- trait outside the repo, not from whatever else is called f.
        -- (relate: 911 such Rust links, none right.)
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'by_name' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done) AND c.n <= 8
              AND c.cid NOT IN (SELECT k.rowid FROM calls k WHERE k.qual IN ('this', 'self', 'Self') /*dirty: AND k.rowid IN (SELECT cid FROM temp.dirty) */);

        INSERT INTO call_edges (caller, callee, file_id, row, weight, by_name, resolution)
            SELECT c.in_symbol, ch.sid, c.file_id, c.row,
                   1.0 / COUNT(*) OVER (PARTITION BY ch.cid), 1, ch.resolution
            FROM chosen ch JOIN calls c ON c.rowid = ch.cid;

        DROP TABLE defs; DROP TABLE ndefs; DROP TABLE cands; DROP TABLE chosen; DROP TABLE done;
        DROP TABLE pend; DROP TABLE prov; DROP TABLE roots; DROP TABLE ext; DROP TABLE asg; DROP TABLE extvar; DROP TABLE retdef;
"#;

// (was src/graph.goose:832)
pub const CALL_FILE_EDGES_SQL: &str = r#"
        /*dirty: DELETE FROM file_edges WHERE kind = 'call' AND src IN (SELECT id FROM temp.dirty_files); */
        -- File links from calls count for less than an import: weight 0.3,
        -- and by_name links only for names defined in at most 3 files, so
        -- generic names (`new`, `parse`) don't tie unrelated files together.
        -- (Summed smallest first: a sum of fractions hangs, in its last
        -- digit, on the order they are added in, and the rows of a graph
        -- update has touched are not in the order index writes them.)
        INSERT INTO file_edges (src, dst, kind, weight)
            SELECT e.file_id, s.file_id, 'call', 0.3 * SUM(e.weight ORDER BY e.weight)
            FROM call_edges e JOIN symbols s ON s.id = e.callee
            WHERE s.file_id != e.file_id
              /*dirty: AND e.file_id IN (SELECT id FROM temp.dirty_files) */
              AND (e.resolution != 'by_name'
                   OR (SELECT COUNT(DISTINCT d.file_id) FROM symbols d WHERE d.name = s.name AND d.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface')) <= 3)
            GROUP BY e.file_id, s.file_id;
    "#;

// (was src/graph.goose:956)
// Tests are grouped with the code they exercise, not with each other:
// communities come from the code files alone, and each test file then
// joins the community it links to most.
pub const GROUPS_START_SQL: &str = r#"
        UPDATE files SET is_test = 1 WHERE
            path LIKE 'tests/%' OR path LIKE 'test/%' OR path LIKE '%/tests/%' OR path LIKE '%/test/%'
            OR path LIKE '%/__tests__/%' OR path LIKE '__tests__/%'
            OR path GLOB '*/test_*.py' OR path GLOB 'test_*.py' OR path GLOB '*_test.py' OR path GLOB '*_tests.rs'
            OR path GLOB '*.test.[jt]s' OR path GLOB '*.test.[jt]sx' OR path GLOB '*.spec.[jt]s' OR path GLOB '*.spec.[jt]sx'
            OR path GLOB '*/conftest.py' OR path = 'conftest.py';
        UPDATE files SET community = (SELECT o.ord FROM temp.ford o WHERE o.id = files.id);
        DROP TABLE IF EXISTS temp.g;
        -- (Sums smallest first, here and below: see call_file_edges.)
        CREATE TEMP TABLE g AS
            SELECT oa.ord AS a, ob.ord AS b, SUM(e.w ORDER BY e.w) AS w FROM (
                SELECT src AS a, dst AS b, weight AS w FROM file_edges
                UNION ALL SELECT dst, src, weight FROM file_edges) e
            JOIN temp.ford oa ON oa.id = e.a JOIN temp.ford ob ON ob.id = e.b
            WHERE e.a IN (SELECT id FROM files WHERE is_test = 0) AND e.b IN (SELECT id FROM files WHERE is_test = 0)
            GROUP BY oa.ord, ob.ord;
    "#;

// (was src/graph.goose:1005)
pub const GROUPS_NEXT_LEVEL_SQL: &str = r#"
            CREATE TEMP TABLE g2 AS
                SELECT ma.c AS a, mb.c AS b, SUM(g.w) AS w
                FROM temp.g g JOIN temp.map ma ON ma.node = g.a JOIN temp.map mb ON mb.node = g.b
                GROUP BY ma.c, mb.c;
            DROP TABLE temp.g;
            ALTER TABLE temp.g2 RENAME TO g;
        "#;

// (was src/graph.goose:1027)
// Each test file joins the code community it links to most (imports
// and calls, either way); a test linked to no code shares one community
// of unlinked tests.
pub const TEST_VOTES_SQL: &str = r#"
        CREATE TEMP TABLE test_votes AS
            SELECT t.id AS tid, c.community AS cm, SUM(e.w ORDER BY e.w) AS w FROM (
                SELECT src AS a, dst AS b, weight AS w FROM file_edges
                UNION ALL SELECT dst, src, weight FROM file_edges) e
            JOIN files t ON t.id = e.a AND t.is_test = 1
            JOIN files c ON c.id = e.b AND c.is_test = 0
            GROUP BY t.id, c.community;
        UPDATE files SET community = COALESCE((
            SELECT cm FROM test_votes v WHERE v.tid = files.id ORDER BY w DESC, cm LIMIT 1), -1)
        WHERE is_test = 1;
        DROP TABLE test_votes;
    "#;

// (was src/graph.goose:1043)
// Number the communities by their code files (unlinked tests last) and
// name each after its most linked code file.
pub const GROUPS_NUMBER_SQL: &str = r#"
        DELETE FROM communities;
        CREATE TEMP TABLE ranked_c AS
            SELECT community AS old,
                   ROW_NUMBER() OVER (ORDER BY community = -1, SUM(is_test = 0) DESC, COUNT(*) DESC, MIN(path)) AS new,
                   SUM(is_test = 0) AS size, SUM(is_test = 1) AS tests
            FROM files GROUP BY community;
        UPDATE files SET community = (SELECT new FROM ranked_c WHERE old = files.community);
        INSERT INTO communities (id, label, size, tests)
            SELECT r.new, CASE WHEN r.old = -1 THEN 'tests linked to no code' ELSE (
                SELECT f.path FROM files f
                LEFT JOIN (SELECT dst AS id, SUM(weight ORDER BY weight) AS w FROM file_edges GROUP BY dst) i ON i.id = f.id
                LEFT JOIN (SELECT src AS id, SUM(weight ORDER BY weight) AS w FROM file_edges GROUP BY src) o ON o.id = f.id
                WHERE f.community = r.new
                ORDER BY f.is_test, COALESCE(i.w, 0) + COALESCE(o.w, 0) DESC, f.path LIMIT 1) END, r.size, r.tests
            FROM ranked_c r;
        DROP TABLE ranked_c;
        DROP TABLE temp.ford;
    "#;

// (was src/score.goose:70)
pub const SCORE_STALE_SQL: &str = r#"
        SELECT f.id, f.path, COALESCE((SELECT x.edited_mtime FROM sw.files x WHERE x.file = f.path), -1)
        FROM files f
    "#;

// (was src/score.goose:77)
pub const SCORE_JUDGE_SQL: &str = r#"
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
    "#;

// (was src/score.goose:115)
pub const SCORE_LINKS_SQL: &str = r#"
        SELECT cf.lang, e.resolution, COUNT(*), COUNT(j.eid), COALESCE(SUM(j.good), 0),
               COALESCE(SUM(j.good = 0 AND j.inside = 1), 0), COALESCE(SUM(j.inside = 0), 0),
               COUNT(DISTINCT CASE WHEN j.eid IS NOT NULL THEN e.file_id || ':' || e.row || ':' || d.name END),
               COUNT(DISTINCT CASE WHEN j.good = 1 THEN e.file_id || ':' || e.row || ':' || d.name END)
        FROM call_edges e JOIN files cf ON cf.id = e.file_id JOIN symbols d ON d.id = e.callee
        LEFT JOIN judged j ON j.eid = e.rowid
        WHERE e.file_id NOT IN (SELECT file_id FROM stale)
        GROUP BY cf.lang, e.resolution ORDER BY cf.lang, COUNT(*) DESC, e.resolution
    "#;

// (was src/score.goose:128)
// Swan names a constructor `<constructor>` (Java: `<init>`) and an
// accessor `<get>size`; the graph `constructor` and `size`.
pub const SCORE_DEFS_SQL: &str = r#"
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
    "#;

// (was src/score.goose:142)
pub const SCORE_CALLED_SQL: &str = r#"
        SELECT r.language, r.kind, COUNT(*),
               SUM(EXISTS (SELECT 1 FROM gdefs g WHERE g.path = r.def_file AND g.name = r.name AND g.line = r.def_line))
        FROM reached r WHERE r.language <> 'swan-syntax'
        GROUP BY r.language, r.kind ORDER BY r.language, COUNT(*) DESC, r.kind
    "#;

// (was src/spread-wings.goose:50)
pub const USAGE: &str = r#"
spread-wings 0.1.0: a broad code graph from syntax alone

  spread-wings index <repo> <graph.db> [--resolution N]   (Louvain resolution, default 1.5)
  spread-wings update <repo> <graph.db> [--resolution N]  bring the graph up to date: reads only the files that
                                            changed, ties again only the calls they reach (builds it when it is not there)
  spread-wings watch <repo> <graph.db> [--every S]        stay awake: update the graph when files change, and say on
                                            one line each time what changed and what it reaches (looks every S seconds
                                            besides, 30 by default; ends when the process that started it ends)
  spread-wings overview <graph.db>
  spread-wings find <graph.db> <name>
  spread-wings neighbors <graph.db> <path>
  spread-wings callers <graph.db> <name>
  spread-wings touches <graph.db> <name> [path]   what changing it reaches: files, tests, groups
  spread-wings serve <graph.db>
  spread-wings compiler <graph.db> <swan.db> [--into <copy.db>]   compiler answers from a Swan map, for every call
                                            site it covers; with --into, put into a copy, the graph left as it is
  spread-wings survey <repo>                   the projects a repo holds: where, which package manager, which versions each wants
  spread-wings score <graph.db> <swan.db>      what the graph's definitions and links are worth against a Swan map
  spread-wings decide <graph.db> [--max N] [--workers N]   Span-02 decisions for calls still by_name
                                            (OPENROUTER_API_KEY in the environment; default 5000 questions, 32 parallel requests)
"#;

// (was src/spread-wings.goose:349)
// The files most linked to within and across communities. (Sums
// smallest first, here and below, so that two files as much linked
// come out in the same order whatever order the rows were written
// in: a graph `update` has touched is not in index's row order.)
pub const MAIN_FILES_SQL: &str = r#"
            SELECT f.path FROM files f
            LEFT JOIN (SELECT dst AS id, SUM(weight ORDER BY weight) AS w FROM file_edges GROUP BY dst) i ON i.id = f.id
            LEFT JOIN (SELECT src AS id, SUM(weight ORDER BY weight) AS w FROM file_edges GROUP BY src) o ON o.id = f.id
            WHERE f.community = ?1
            ORDER BY f.is_test, COALESCE(i.w, 0) + COALESCE(o.w, 0) DESC, f.path LIMIT 5
            "#;

// (was src/spread-wings.goose:357)
pub const MOST_CALLED_SQL: &str = r#"
            SELECT s.name FROM symbols s JOIN files f ON f.id = s.file_id
            JOIN call_edges e ON e.callee = s.id
            WHERE f.community = ?1
              AND (SELECT COUNT(DISTINCT t.file_id) FROM symbols t WHERE t.name = s.name) <= 3
            GROUP BY s.name ORDER BY COUNT(DISTINCT e.file_id) DESC, SUM(e.weight ORDER BY e.weight) DESC, s.name LIMIT 5
            "#;

// (was src/spread-wings.goose:372)
pub const FIND_SQL: &str = r#"
        SELECT s.name, s.kind, f.path, s.row, f.community,
               (SELECT COUNT(*) FROM calls c WHERE c.callee = s.name) AS uses
        FROM symbols s JOIN files f ON f.id = s.file_id
        WHERE s.name = ?1 OR (length(?1) >= 3 AND s.name LIKE '%' || ?1 || '%')
        ORDER BY s.name != ?1, s.name, f.path LIMIT 50
        "#;

// (was src/spread-wings.goose:439)
pub const CALLERS_SQL: &str = r#"
        SELECT f.path, c.row, COALESCE(s.name, ''),
               COALESCE((SELECT group_concat(DISTINCT e.resolution) FROM call_edges e
                         WHERE e.file_id = c.file_id AND e.row = c.row
                           AND e.callee IN (SELECT id FROM symbols WHERE name = ?1)), 'unlinked'),
               COALESCE((SELECT group_concat(DISTINCT tf.path) FROM call_edges e
                         JOIN symbols t ON t.id = e.callee JOIN files tf ON tf.id = t.file_id
                         WHERE e.file_id = c.file_id AND e.row = c.row AND t.name = ?1), '')
        FROM calls c
        JOIN files f ON f.id = c.file_id LEFT JOIN symbols s ON s.id = c.in_symbol
        WHERE c.callee = ?1 ORDER BY f.path, c.row LIMIT 500
        "#;

// (was src/spread-wings.goose:487)
pub const TOUCH_DEFS_SQL: &str = r#"
        CREATE TEMP TABLE t_defs AS
            SELECT s.id, s.file_id, s.row, s.kind FROM symbols s JOIN files f ON f.id = s.file_id
            WHERE s.name = ?1 AND (?2 = '' OR f.path = ?2)
        "#;

// (was src/spread-wings.goose:500)
pub const TOUCH_FILES_SQL: &str = r#"
        CREATE TEMP TABLE t_touch AS
            SELECT file_id, MAX(d) AS defines, SUM(c) AS sites, SUM(g) AS guessed, MAX(i) AS imports FROM (
                SELECT file_id, 1 AS d, 0 AS c, 0 AS g, 0 AS i FROM t_defs
                UNION ALL
                SELECT e.file_id, 0, 1, e.resolution = 'by_name', 0
                FROM (SELECT DISTINCT file_id, row, resolution FROM call_edges
                      WHERE callee IN (SELECT id FROM t_defs)) e
                UNION ALL
                SELECT file_id, 0, 0, 0, 1 FROM (SELECT DISTINCT file_id FROM imports
                                                 WHERE dst IN (SELECT file_id FROM t_defs)))
            GROUP BY file_id;
    "#;

// (was src/spread-wings.goose:516)
pub const TOUCH_DEFS_LIST_SQL: &str = r#"
        SELECT f.path, d.row, d.kind, COALESCE(f.community, 0) FROM t_defs d JOIN files f ON f.id = d.file_id
        ORDER BY f.path, d.row
        "#;

// (was src/spread-wings.goose:537)
pub const TOUCH_FILES_LIST_SQL: &str = r#"
        SELECT f.path, t.defines, t.sites, t.guessed, t.imports, COALESCE(f.is_test, 0), COALESCE(f.community, 0)
        FROM t_touch t JOIN files f ON f.id = t.file_id
        ORDER BY t.defines DESC, f.is_test, t.sites DESC, f.path LIMIT 400
        "#;

// (was src/spread-wings.goose:568)
pub const TOUCH_GROUPS_SQL: &str = r#"
        SELECT COALESCE(f.community, 0), COALESCE(c.label, ''), COUNT(*)
        FROM t_touch t JOIN files f ON f.id = t.file_id LEFT JOIN communities c ON c.id = f.community
        GROUP BY f.community ORDER BY COUNT(*) DESC
        "#;

// (was src/spread-wings.goose:600)
pub const TOOLS: &str = r#"
[
{"name":"overview","description":"The repo's communities (groups of files that import and call each other), each with its main files and most-called definitions. Start here to understand an unfamiliar codebase. Links are matched by name or path from syntax, not compiler-resolved.","inputSchema":{"type":"object","properties":{}}},
{"name":"find","description":"Definitions (functions, classes, structs, traits, interfaces) by exact name, or containing the name when it has 3+ characters, with file, line, community and how many call sites use that name.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
{"name":"neighbors","description":"One file's definitions, the files it imports and is imported by, and the files it calls into and is called from (by name).","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the repo root."}},"required":["path"]}},
{"name":"callers","description":"Call sites of a name, with file, line and the definition they sit in. Matched by name: calls to any definition with this name.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
{"name":"touches","description":"What changing a definition reaches, in one answer, before you edit: the files that define it, call it or import its file, which of them are tests, and which groups of the repo they are in. Pass path when the name is defined in several files. Broad and from syntax; use Swan for the exact sites and to make the edits.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"path":{"type":"string","description":"The file that defines the one you mean (optional)."}},"required":["name"]}}
]
"#;

// (was src/store.goose:9)
pub const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY, path TEXT UNIQUE, lang TEXT, dir TEXT,
    community INTEGER, is_test INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS symbols (
    id INTEGER PRIMARY KEY, file_id INTEGER, name TEXT, kind TEXT,
    row INTEGER, start INTEGER, end_ INTEGER, end_row INTEGER, sig TEXT, container TEXT,
    params TEXT);   -- a function's parameter names, ",a,b,c," ("" for none): what its body binds on entry
CREATE TABLE IF NOT EXISTS imports (file_id INTEGER, module TEXT, row INTEGER, names TEXT, dst INTEGER);
CREATE TABLE IF NOT EXISTS calls (
    file_id INTEGER, row INTEGER, start INTEGER, callee TEXT, in_symbol INTEGER, text TEXT,
    note TEXT,
    qual TEXT);     -- the name right before the callee's: `Pair` of `Pair::new`, `this` of `this.push`; "" for none
CREATE TABLE IF NOT EXISTS assigns (
    file_id INTEGER, row INTEGER, start INTEGER, name TEXT, value TEXT, in_symbol INTEGER);
CREATE INDEX IF NOT EXISTS assigns_scope ON assigns(file_id, name);
CREATE TABLE IF NOT EXISTS aliases (file_id INTEGER, alias TEXT, dst INTEGER);
CREATE TABLE IF NOT EXISTS file_edges (src INTEGER, dst INTEGER, kind TEXT, weight REAL);
CREATE TABLE IF NOT EXISTS call_edges (
    caller INTEGER, callee INTEGER, file_id INTEGER, row INTEGER, weight REAL, by_name INTEGER,
    resolution TEXT);
CREATE TABLE IF NOT EXISTS decisions (
    file_id INTEGER, row INTEGER, callee TEXT, choice TEXT, target INTEGER, p INTEGER);
CREATE TABLE IF NOT EXISTS communities (id INTEGER PRIMARY KEY, label TEXT, size INTEGER, tests INTEGER);
-- What index last saw of each file, for `update`: its place in the walk
-- (0 for the first file), and its size, times and a hash of its content.
-- mtime and ctime are 0 when the file was written so close to the run that
-- a later write could carry the same times: such a file is read again.
CREATE TABLE IF NOT EXISTS stamps (
    file_id INTEGER PRIMARY KEY, ord INTEGER, size INTEGER, mtime INTEGER, ctime INTEGER, hash INTEGER);
CREATE INDEX IF NOT EXISTS symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS symbols_file ON symbols(file_id);
CREATE INDEX IF NOT EXISTS calls_callee ON calls(callee);
CREATE INDEX IF NOT EXISTS calls_file ON calls(file_id);
CREATE INDEX IF NOT EXISTS file_edges_src ON file_edges(src);
CREATE INDEX IF NOT EXISTS imports_file ON imports(file_id, dst);
CREATE INDEX IF NOT EXISTS aliases_file ON aliases(file_id, dst);
CREATE INDEX IF NOT EXISTS calls_site ON calls(file_id, row);
CREATE INDEX IF NOT EXISTS file_edges_dst ON file_edges(dst);
"#;

// (was src/update.goose:47)
// The names on the import lines in temp.u_lines, into temp.u_names: `f`,
// both sides of `orig>bound`, the x of `@x`.
pub const IMPORT_NAMES_SQL: &str = r#"
    WITH RECURSIVE sp(tok, rest) AS (
        SELECT '', names || ',' FROM temp.u_lines
        UNION ALL SELECT substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1) FROM sp WHERE rest <> '')
    INSERT OR IGNORE INTO temp.u_names
        SELECT replace(tok, '@', '') FROM sp WHERE tok <> '' AND tok <> '@' AND instr(tok, '>') = 0
        UNION SELECT substr(tok, 1, instr(tok, '>') - 1) FROM sp WHERE instr(tok, '>') > 1
        UNION SELECT substr(tok, instr(tok, '>') + 1) FROM sp WHERE instr(tok, '>') > 0 AND substr(tok, instr(tok, '>') + 1) <> '';
    DELETE FROM temp.u_lines;
"#;

// (was src/update.goose:61)
// What the files in temp.u_set (read again, or gone) held, kept before
// their rows go: each definition as other files' calls can tell it (name,
// kind, the type it belongs to, its signature line), and each import line.
pub const KEEP_OLD_SQL: &str = r#"
    CREATE TEMP TABLE u_old_sym AS
        SELECT id, file_id, name, kind, COALESCE(container, '') AS container, COALESCE(sig, '') AS sig, start
        FROM symbols WHERE file_id IN (SELECT id FROM temp.u_set) AND name IS NOT NULL;
    CREATE TEMP TABLE u_old_imp AS
        SELECT file_id, COALESCE(module, '') AS module, COALESCE(names, '') AS names, COALESCE(dst, 0) AS dst
        FROM imports WHERE file_id IN (SELECT id FROM temp.u_set);
    CREATE TEMP TABLE u_dsts (id INTEGER PRIMARY KEY);
    -- The files with a link into one of them, as things stood (REACH_SQL).
    CREATE TEMP TABLE u_reach (id INTEGER PRIMARY KEY);
    INSERT OR IGNORE INTO temp.u_reach SELECT src FROM file_edges WHERE dst IN (SELECT id FROM temp.u_set);
"#;

// (was src/update.goose:77)
// What the change reaches: the files, not changed themselves, that import
// or call into a file that changed, was added or is gone, before the
// change or now. Where to look next, and the tests among them to run.
pub const REACH_SQL: &str = r#"
    INSERT OR IGNORE INTO temp.u_reach SELECT src FROM file_edges WHERE dst IN (SELECT id FROM temp.u_set);
    DELETE FROM temp.u_reach WHERE id IN (SELECT id FROM temp.u_set) OR id NOT IN (SELECT id FROM files);
"#;

// (was src/update.goose:84)
// The files something imports from, or names as a module (temp.u_dsts):
// taken before the change and again after the imports are tied.
pub const IMPORTED_FILES_SQL: &str = r#"
    INSERT OR IGNORE INTO temp.u_dsts SELECT DISTINCT dst FROM imports WHERE dst > 0;
    INSERT OR IGNORE INTO temp.u_dsts SELECT DISTINCT dst FROM aliases WHERE dst > 0;
"#;

// (was src/update.goose:97)
// After the files read again have their new rows: the names whose
// definitions in them are not what they were (temp.u_chg, by file). A name
// defined in at most 50 places, before or now, can be tied from anywhere,
// and goes to temp.u_names: every call of it is tied again. A name defined
// in more than 50 places before and now is only ever tied to the
// definitions in the caller's own file and in the files it imports
// (LINK_CALLS_SQL), so a change to it in a file reaches the calls of it in
// the files that import that file and no others (temp.u_near).
pub const COMPARE_SQL: &str = r#"
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
"#;

// (was src/update.goose:134)
// After their imports are tied: the import lines a file read again gained
// or lost. One that names a file of the repo, in a file that something
// imports from, passes names on, and the names on it go to temp.u_lines
// (an import from outside the repo passes nothing on, nor does a file
// nothing imports from). And in a file whose import lines are not what
// they were, the functions that say what they return.
pub const COMPARE_IMPORTS_SQL: &str = r#"
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
"#;

// (was src/update.goose:159)
// The links of every name whose definitions are as they were (not in
// temp.u_all), moved from a definition's old row to its new one. Definitions alike in name, kind, type and
// signature line are the same to any call from outside the file, so the
// old ones are paired with the new ones in the order they stand in it.
pub const MOVE_LINKS_SQL: &str = r#"
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
"#;

// (was src/update.goose:180)
// Every row of the files in temp.u_set (read again, or gone), and the files
// in temp.u_gone themselves.
pub const DROP_ROWS_SQL: &str = r#"
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
"#;

// (was src/update.goose:197)
// After every import was tied again (a file was added or removed): the
// files not read again whose imports, or names for whole modules, now land
// somewhere else than before (temp.u_imp, temp.u_ali).
pub const REIMPORTED_SQL: &str = r#"
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
"#;

// (was src/update.goose:219)
// The calls to tie again (temp.dirty), by the list at the top of update.rs,
// the files they are in (temp.dirty_files), and their links and notes taken
// away. temp.u_names holds the names every call of which is redone,
// temp.u_near those redone in the files that import the changed file,
// temp.u_all every name whose definitions or passing on changed, and
// temp.u_files the files whose every call is redone.
pub const DIRTY_SQL: &str = r#"
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
"#;

// (was src/update.goose:264)
// How many of the file links update redid (those out of the files read
// again, and the call links out of the files with calls tied again) are not
// what they were (temp.u_fe): 0 when the same links, with the same weights,
// are back.
pub const FILE_LINKS_SAME_SQL: &str = r#"
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
"#;

// (was src/update.goose:317)
pub const UPDATE_TEMP_SQL: &str = r#"
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
    "#;

// (was src/update.goose:357)
pub const UPDATE_WALK_SQL: &str = r#"
        SELECT w.ord, f.id, s.hash IS NOT NULL, COALESCE(s.hash, 0),
               s.file_id IS NULL OR s.mtime = 0 OR s.size IS NOT w.size OR s.mtime IS NOT w.mtime OR s.ctime IS NOT w.ctime
        FROM temp.u_walk w JOIN files f ON f.path = w.path LEFT JOIN stamps s ON s.file_id = f.id
        ORDER BY w.ord
    "#;

// (was src/update.goose:434)
pub const KEEP_IMPORTS_SQL: &str = r#"
            CREATE TEMP TABLE u_imp AS SELECT rowid AS r, file_id, COALESCE(dst, 0) AS dst FROM imports
                WHERE file_id NOT IN (SELECT id FROM temp.u_set);
            CREATE TEMP TABLE u_ali AS SELECT file_id, alias, dst FROM aliases
                WHERE file_id NOT IN (SELECT id FROM temp.u_set);
        "#;

// (was src/update.goose:455)
// Every file's place in the walk: a file added or removed moves the rest.
pub const RENUMBER_WALK_SQL: &str = r#"
            UPDATE stamps SET ord = (SELECT w.ord FROM temp.u_walk w JOIN files f ON f.path = w.path
                                     WHERE f.id = stamps.file_id);
        "#;

// (was src/update.goose:491)
pub const KEEP_CALL_LINKS_SQL: &str = r#"
            INSERT INTO temp.u_fe SELECT src, dst, kind, weight FROM file_edges
                WHERE kind = 'call' AND src IN (SELECT id FROM temp.dirty_files) AND src NOT IN (SELECT id FROM temp.u_set);
        "#;

// (was src/update.goose:523)
pub const REACHED_TESTS_SQL: &str = r#"
        SELECT path FROM files WHERE is_test = 1
          AND (id IN (SELECT id FROM temp.u_reach) OR id IN (SELECT id FROM temp.u_changed))
        ORDER BY path LIMIT 200
    "#;
