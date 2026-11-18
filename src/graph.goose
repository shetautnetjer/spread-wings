// From facts to edges, and edges to communities. Every edge here is
// matched by name or by path, not resolved by a compiler: `by_name` says so,
// and a name with several definitions spreads its weight across them.

import std;
import sqlite;
import .store;

// Calls link to functions, classes, structs, enums, traits and interfaces.
// A name defined more than 8 times is too common to link by name (`new`,
// `get`, `run`): its calls stay as facts without edges.

fn strip_ext(p: const u8[:]) -> const u8[:] {
    let dot = rfind(p, ".");
    let slash = rfind(p, "/");
    if dot > slash { return p[..dot]; }
    return p;
}

// `a/./b/../c` -> `a/c`, for a path relative to the repo root. "" when it
// climbs out of the repo.
fn normalize(p: const u8[:], out: u8[>..]&) -> bool {
    var parts: u8[>..] = [];   // kept segments, '\n' separated
    var n = 0;
    each_split(p, '/') { seg =>
        if seg.len == 0 || seg == "." {
        } else if seg == ".." {
            if n > 0 {
                let cut = rfind(parts[..parts.len - 1], "\n");
                parts.resize(if cut >= 0 { cut + 1 } else { 0 }, 0);
                n--;
            } else {
                n = -1000000;
            }
        } else {
            parts.append(seg);
            parts.push('\n');
            n++;
        }
    };
    guard n >= 0 else { return false; }
    out.clear();
    each_split(parts, '\n') { seg =>
        if seg.len > 0 {
            if out.len > 0 { out.push('/'); }
            out.append(seg);
        }
    };
    return true;
}

fn file_id(st: i64, path: const u8[:]) -> i64 {
    var err: u8[>..] = [];
    sqlite::reset(st);
    sqlite::bind_text(st, 1, path);
    var id: i64 = 0;
    if sqlite::step(st, err) == 1 { id = sqlite::col_int(st, 0); }
    return id;
}

// The first of the candidate paths that is an indexed file, else 0.
fn first_file(st: i64, like_st: i64, pkg_st: i64, candidates: const u8[:]) -> i64 {
    var found: i64 = 0;
    each_split(candidates, '\n') { c =>
        if found == 0 && c.len > 0 {
            // "%/x/src/lib.rs": any indexed path ending in /x/src/lib.rs.
            // ">pkg/mod.py": a path ending in /pkg/mod.py whose folder before
            // it is not itself a Python package (see PKG_SUFFIX_SQL).
            if c[0] == '%' { found = file_id(like_st, c); }
            else if c[0] == '>' { found = file_id(pkg_st, c[1..]); }
            else { found = file_id(st, c); }
        }
    };
    return found;
}

// A Python module below a folder that is a place imports start from: the
// path ends in /<module path>, and the folder holding the module's first
// segment has no __init__.py (if it had one, the module's real name would
// start with that folder's). So `import mypkg.core` finds
// python/mypkg/core.py, and does not find a/b/mypkg/core.py when a/b is a
// package. pysuf holds every such ending of every Python path, so one
// import is one indexed lookup; the shortest path wins, and of two as short
// the one the walk met first (`ord`: a file's row number says that only in
// a graph no update has added files to).
let PKG_SUFFIX_SQL = """
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
""";

// Candidate files for one import, best first, one per line.
fn import_candidates(lang: const u8[:], importer: const u8[:], module: const u8[:], out: u8[>..]&) {
    let slash = rfind(importer, "/");
    let dir = if slash >= 0 { importer[..slash] } else { "" };
    var base: u8[>..] = [];
    if lang == "python" {
        var m = module;
        var up = 0;
        while m.len > 0 && m[0] == '.' { up++; m = m[1..]; }
        var rel: u8[>..] = [];
        for c in m { rel.push(if c == '.' { '/' } else { c }); }
        if up > 0 {
            var start: u8[>..] = [];
            start.append(dir);
            for k in 1..up { start.append("/.."); }
            var joined: u8[>..] = [];
            format(joined, start, "/", rel);
            guard normalize(joined, base) else { return; }
        } else {
            base.append(rel);
        }
        guard base.len > 0;
        format(out, base, ".py\n", base, "/__init__.py\n");
        // A top-level package under src/ or the importer's own folder.
        format(out, "src/", base, ".py\n", "src/", base, "/__init__.py\n");
        if dir.len > 0 { format(out, dir, "/", base, ".py\n"); }
        // A package kept in some other folder (python/mypkg, packages/x/mypkg):
        // by its path below that folder. A lone module name (`import utils`)
        // is tried only as a package, since any utils.py would match.
        if up == 0 {
            if find(base, "/") > 0 { format(out, ">", base, ".py\n"); }
            format(out, ">", base, "/__init__.py\n");
        }
        return;
    }
    if lang == "goose" {
        // `import .x;` and `import .a.b;` are x.goose and a/b.goose beside the
        // importer. No leading dot: the standard library or a fetched package.
        guard module.len > 1 && module[0] == '.' else { return; }
        var rel: u8[>..] = [];
        for c in module[1..] { rel.push(if c == '.' { '/' } else { c }); }
        if dir.len > 0 { format(out, dir, "/", rel, ".goose\n"); } else { format(out, rel, ".goose\n"); }
        return;
    }
    if lang == "rust" {
        // crate::a::b, self::a, super::a: the module files a.rs, a/mod.rs,
        // a/b.rs near the importer's crate root (the folder holding src/).
        var m = module;
        var root: u8[>..] = [];
        let src_at = find(importer, "src/");
        if src_at >= 0 { root.append(importer[..src_at + 4]); }
        var segs: u8[>..] = [];
        var from_dir: u8[>..] = [];
        if starts_with(m, "mod::") {
            // `mod x;` in lib.rs, main.rs or mod.rs is x.rs beside it; in
            // foo.rs it is foo/x.rs.
            let name = m[5..];
            let base_name = if slash >= 0 { importer[slash + 1..] } else { importer };
            var d: u8[>..] = [];
            if dir.len > 0 { format(d, dir, "/"); }
            if !(base_name == "lib.rs" || base_name == "main.rs" || base_name == "mod.rs") {
                format(d, strip_ext(base_name), "/");
            }
            format(out, d, name, ".rs\n", d, name, "/mod.rs\n");
            return;
        }
        if starts_with(m, "crate::") { m = m[7..]; from_dir.append(root); }
        else if starts_with(m, "self::") { m = m[6..]; if dir.len > 0 { format(from_dir, dir, "/"); } }
        else if starts_with(m, "super::") {
            m = m[7..];
            let up = rfind(dir, "/");
            if up >= 0 { format(from_dir, dir[..up], "/"); }
        } else {
            // Another crate: a workspace member named like it (pitl_core is
            // crates/pitl-core/src/lib.rs); anything else is external.
            let c = find(m, "::");
            let crate_name = if c > 0 { m[..c] } else { m };
            var dashed: u8[>..] = [];
            for ch in crate_name { dashed.push(if ch == '_' { '-' } else { ch }); }
            format(out, "%/", dashed, "/src/lib.rs\n", "%/", crate_name, "/src/lib.rs\n", dashed, "/src/lib.rs\n", crate_name, "/src/lib.rs\n");
            return;
        }
        each_split(m, ':') { s => if s.len > 0 { if segs.len > 0 { segs.push('/'); } segs.append(s); } };
        // Longest path first: a/b.rs, then a.rs, a/mod.rs.
        var path: u8[>..] = [];
        path.append(segs);
        loop {
            format(out, from_dir, path, ".rs\n", from_dir, path, "/mod.rs\n");
            let cut = rfind(path, "/");
            guard cut > 0 else { break; }
            path.resize(cut, 0);
        }
        return;
    }
    // TypeScript and JavaScript: relative paths only; packages stay external.
    guard module.len > 0 && module[0] == '.';
    var joined: u8[>..] = [];
    if dir.len > 0 { format(joined, dir, "/", module); } else { joined.append(module); }
    guard normalize(joined, base) else { return; }
    format(out, base, "\n");   // `./store.js` naming the file itself
    for e in [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".d.ts", "/index.ts", "/index.tsx", "/index.js"] {
        format(out, base, e, "\n");
    }
    format(out, strip_ext(base), ".ts\n", strip_ext(base), ".tsx\n");   // `./m.js` written for `m.ts`
}

fn add_alias(st: i64, file: i64, alias: const u8[:], dst: i64) {
    sqlite::reset(st);
    sqlite::bind_int(st, 1, file);
    sqlite::bind_text(st, 2, alias);
    sqlite::bind_int(st, 3, dst);
    sqlite::step_done(st);
}

// Ties each import to the file it names. With only_changed (update), only
// the imports of the files read again (temp.u_changed): theirs are new rows.
fn link_imports(db: i64, only_changed: bool = false) -> i64 {
    var err: u8[>..] = [];
    // The imports to tie are listed first, then read from the list: the
    // loop below writes each one's file into the row it came from, and a
    // row found through an index on what is being written (which is how
    // the imports of a few files are found) can come round a second time.
    sqlite::exec_or_die(db, open_marks("""
        DROP TABLE IF EXISTS temp.imp_todo;
        CREATE TEMP TABLE imp_todo AS
            SELECT i.file_id, f.path, f.lang, i.module, i.rowid AS r, COALESCE(i.names, '') AS names
            FROM imports i JOIN files f ON f.id = i.file_id
            /*only: WHERE i.file_id IN (SELECT id FROM temp.u_changed) */
            ORDER BY i.rowid;
    """, "only", only_changed));
    let q = sqlite::prepare_or_die(db, "SELECT file_id, path, lang, module, r, names FROM temp.imp_todo ORDER BY rowid");
    let ins_alias = sqlite::prepare_or_die(db, "INSERT INTO aliases (file_id, alias, dst) VALUES (?1, ?2, ?3)");
    let set_dst = sqlite::prepare_or_die(db, "UPDATE imports SET dst = ?2 WHERE rowid = ?1");
    let find_st = sqlite::prepare_or_die(db, "SELECT id FROM files WHERE path = ?1");
    // (Of two paths as short, the first by name: said outright, so that the
    // answer does not hang on the order rows happen to be read in.)
    let like_st = sqlite::prepare_or_die(db, "SELECT id FROM files WHERE path LIKE ?1 ORDER BY length(path), path LIMIT 1");
    sqlite::exec_or_die(db, PKG_SUFFIX_SQL);
    let pkg_st = sqlite::prepare_or_die(db, "SELECT id FROM pysuf WHERE suffix = ?1 ORDER BY len, ord, id LIMIT 1");
    let ins = sqlite::prepare_or_die(db, "INSERT INTO file_edges (src, dst, kind, weight) VALUES (?1, ?2, 'import', 1.0)");
    var n: i64 = 0;
    while sqlite::step(q, err) == 1 {
        let src = sqlite::col_int(q, 0);
        var path: u8[>..] = [];
        var lang: u8[>..] = [];
        var module: u8[>..] = [];
        sqlite::col_text(q, 1, path);
        sqlite::col_text(q, 2, lang);
        sqlite::col_text(q, 3, module);
        var cands: u8[>..] = [];
        import_candidates(lang, path, module, cands);
        let dst = first_file(find_st, like_st, pkg_st, cands);
        var names: u8[>..] = [];
        sqlite::col_text(q, 5, names);
        // Names that stand for a whole module: `import a.b as x` and
        // `import * as x` (marked '@'), `from pkg import mod` where pkg/mod is
        // a module file, and Rust `use a::b;` where b is a module file.
        if names.len > 1 && names[0] == '@' && dst != 0 {
            add_alias(ins_alias, src, names[1..], dst);
        } else if lang == "python" && names.len > 0 {
            each_split(names, ',') { n =>
                if n.len > 0 {
                    // `mod>x`: module mod bound as x.
                    let gt = find(n, ">");
                    let modname = if gt > 0 { n[..gt] } else { n };
                    let bound = if gt > 0 { n[gt + 1..] } else { n };
                    var sub: u8[>..] = [];
                    import_candidates(lang, path, str(module, if module.len > 0 && module[module.len - 1] == '.' { "" } else { "." }, modname), sub);
                    let mdst = first_file(find_st, like_st, pkg_st, sub);
                    if mdst != 0 && mdst != src && bound.len > 0 { add_alias(ins_alias, src, bound, mdst); }
                }
            };
        } else if lang == "rust" && dst != 0 && names.len > 0 && find(names, ",") < 0 && find(module, "::{") < 0 {
            // `use crate::state;` binds `state` when state is the file itself.
            let last = rfind(module, "::");
            let seg = if last >= 0 { module[last + 2..] } else { module };
            if seg == names[..] { add_alias(ins_alias, src, names, dst); }
        }
        if dst != 0 && dst != src {
            sqlite::reset(set_dst);
            sqlite::bind_int(set_dst, 1, sqlite::col_int(q, 4));
            sqlite::bind_int(set_dst, 2, dst);
            sqlite::step_done(set_dst);
            sqlite::reset(ins);
            sqlite::bind_int(ins, 1, src);
            sqlite::bind_int(ins, 2, dst);
            sqlite::step_done(ins);
            n++;
        }
    }
    sqlite::finalize(q);
    sqlite::finalize(find_st);
    sqlite::finalize(like_st);
    sqlite::finalize(pkg_st);
    sqlite::exec_or_die(db, "DROP TABLE pysuf; DROP TABLE temp.imp_todo");
    sqlite::finalize(set_dst);
    sqlite::finalize(ins_alias);
    sqlite::finalize(ins);
    return n;
}

// Each call site is tied to the definitions its name could mean, by the
// strongest evidence the code gives, first match wins:
//   own_type       `this.f()` / `self.f()` / `Self::f()`: the f of the type
//                  the calling method belongs to;
//   type_name      `Type::f()` / `Type.f()`: the f of the type named;
//   same_file      a definition with that name in the caller's own file;
//   imported_name  the caller's file imports that name from a file that
//                  defines it (`from m import f`, `import { f }`, `use m::F`);
//   imported_file  the caller's file imports a file that defines it;
//   by_name        any definition with that name (only for names defined in
//                  at most 8 places).
// Several definitions at one level share the call's weight. The rule used
// is stored on the link as `resolution`.
//
// With only_dirty (update), only the calls listed in temp.dirty are tied,
// with temp.dirty_files holding the files they are in: every other call
// keeps the links and the note it has. What a call's answer hangs on, and
// so which calls update must list, is set out in update.goose.
fn link_calls(db: i64, only_dirty: bool = false) {
    make_roots(db);
    sqlite::exec_or_die(db, open_marks(LINK_CALLS_SQL, "dirty", only_dirty));
    call_file_edges(db, only_dirty);
}

// The repo's own top-level names: an import whose first segment is none of
// them comes from outside the repo. They hang on the paths of the files
// alone, so update compares roots_text before and after: when a file added
// or removed changes them, any call may be outside that was not, and all
// are tied again.
fn make_roots(db: i64) {
    sqlite::exec_or_die(db, """
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
    """);
}

fn roots_text(db: i64) -> u8[>..] {
    make_roots(db);
    var err: u8[>..] = [];
    var out: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, "SELECT seg FROM temp.roots ORDER BY seg");
    while sqlite::step(st, err) == 1 {
        sqlite::col_text(st, 0, out);
        out.push('\n');
    }
    sqlite::finalize(st);
    sqlite::exec_or_die(db, "DROP TABLE temp.roots");
    return out;
}

let LINK_CALLS_SQL = """
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
""";

// File links from call links. With only_dirty (update), those out of the
// files in temp.dirty_files, in place of the ones they had: a file's links
// out hang on its own calls' links and, for a link by name, on how many
// files define the name, and a name defined in more or fewer files than
// before has had every call of it tied again.
fn call_file_edges(db: i64, only_dirty: bool = false) {
    sqlite::exec_or_die(db, open_marks("""
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
    """, "dirty", only_dirty));
}

// One level of Louvain's local moving on a graph in CSR form (off, nbr, w):
// each node moves to the neighboring community with the best modularity
// gain until no node moves. Returns true if any node moved.
fn local_moving(n: i64, off: const i64[:], nbr: const i64[:], w: const f64[:], comm: i64[>..]&, gamma: f64) -> bool {
    var k: f64[>..] = [];
    var tot: f64[>..] = [];
    k.resize(n, 0.0);
    tot.resize(n, 0.0);
    var m2 = 0.0;
    for i in 0..n {
        var d = 0.0;
        for e in off[i]..off[i + 1] { d = d + w[e]; }
        k[i] = d;
        m2 = m2 + d;
    }
    guard m2 > 0.0 else { return false; }
    for i in 0..n { tot[comm[i]] = tot[comm[i]] + k[i]; }
    var wc: f64[>..] = [];
    wc.resize(n, 0.0);
    var touched: i64[>..] = [];
    var moved_any = false;
    var pass = 0;
    loop {
        var moved = false;
        for i in 0..n {
            let c0 = comm[i];
            touched.clear();
            for e in off[i]..off[i + 1] {
                let j = nbr[e];
                if j != i {
                    let c = comm[j];
                    if wc[c] == 0.0 { touched.push(c); }
                    wc[c] = wc[c] + w[e];
                }
            }
            tot[c0] = tot[c0] - k[i];
            var best = c0;
            var best_gain = wc[c0] - gamma * tot[c0] * k[i] / m2;
            for c in touched {
                let gain = wc[c] - gamma * tot[c] * k[i] / m2;
                if gain > best_gain + 1e-12 {
                    best = c;
                    best_gain = gain;
                }
            }
            tot[best] = tot[best] + k[i];
            if best != c0 { comm[i] = best; moved = true; }
            for c in touched { wc[c] = 0.0; }
        }
        pass++;
        if moved { moved_any = true; }
        guard moved && pass < 50 else { break; }
    }
    return moved_any;
}

// Loads `table` (a, b, w; both directions, 0-based dense ids below n) as CSR.
fn load_csr(db: i64, table: const u8[:], n: i64, off: i64[>..]&, nbr: i64[>..]&, w: f64[>..]&) {
    var err: u8[>..] = [];
    off.clear();
    nbr.clear();
    w.clear();
    off.resize(n + 1, 0);
    // Weights as integers in thousandths: goose-sqlite reads ints and text.
    let st = sqlite::prepare_or_die(db, str("SELECT a, b, CAST(ROUND(w * 1000) AS INTEGER) FROM ", table, " ORDER BY a, b"));
    var row_a: i64[>..] = [];
    while sqlite::step(st, err) == 1 {
        let a = sqlite::col_int(st, 0);
        row_a.push(a);
        nbr.push(sqlite::col_int(st, 1));
        w.push(sqlite::col_int(st, 2) / 1000.0);
    }
    sqlite::finalize(st);
    for a in row_a { off[a + 1] = off[a + 1] + 1; }
    for i in 0..n { off[i + 1] = off[i + 1] + off[i]; }
}

// Louvain over the undirected file graph (imports and by-name calls,
// weighted): local moving, then each community becomes one node, until
// nothing moves. Deterministic: same repo, same communities.
// gamma is Louvain's resolution: 1 is plain modularity; higher splits the
// graph into more, smaller communities.
//
// A file's node number is its place in the walk (temp.ford), not its row
// number: a graph update has added files to or taken files from has rows
// out of that order and gaps between them, and the moves below go node by
// node. In a graph straight from index the two are the same. A graph from
// before stamps were kept has no places: its row numbers serve.
fn communities(db: i64, gamma: f64) -> i64 {
    let n = scalar(db, "SELECT COUNT(*) FROM files");
    sqlite::exec_or_die(db, "DROP TABLE IF EXISTS temp.ford; CREATE TEMP TABLE ford (id INTEGER PRIMARY KEY, ord INTEGER)");
    if scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'stamps'") == 1
       && scalar(db, "SELECT COUNT(*) FROM stamps s JOIN files f ON f.id = s.file_id WHERE s.ord IS NOT NULL") == n {
        sqlite::exec_or_die(db, "INSERT INTO temp.ford SELECT file_id, ROW_NUMBER() OVER (ORDER BY ord, file_id) - 1 FROM stamps WHERE file_id IN (SELECT id FROM files)");
    } else {
        sqlite::exec_or_die(db, "INSERT INTO temp.ford SELECT id, ROW_NUMBER() OVER (ORDER BY id) - 1 FROM files");
    }
    var ids: i64[>..] = [];   // node number -> file row
    var ford_err: u8[>..] = [];
    let ford_st = sqlite::prepare_or_die(db, "SELECT id FROM temp.ford ORDER BY ord");
    while sqlite::step(ford_st, ford_err) == 1 { ids.push(sqlite::col_int(ford_st, 0)); }
    sqlite::finalize(ford_st);
    // Tests are grouped with the code they exercise, not with each other:
    // communities come from the code files alone, and each test file then
    // joins the community it links to most.
    sqlite::exec_or_die(db, """
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
    """);
    var member: i64[>..] = [];   // file index -> current community (a node of the current level)
    for i in 0..n { member.push(i); }
    var size = n;
    var levels: i64 = 0;
    while levels < 20 && size > 1 {
        var off: i64[>..] = [];
        var nbr: i64[>..] = [];
        var w: f64[>..] = [];
        load_csr(db, "temp.g", size, off, nbr, w);
        var comm: i64[>..] = [];
        for i in 0..size { comm.push(i); }
        guard local_moving(size, off, nbr, w, comm, gamma) else { break; }
        levels++;
        // Renumber the communities 0..c-1 in node order.
        var renum: i64[>..] = [];
        renum.resize(size, -1);
        var c = 0;
        for i in 0..size {
            if renum[comm[i]] < 0 { renum[comm[i]] = c; c++; }
        }
        for f in 0..n { member[f] = renum[comm[member[f]]]; }
        // The next level's graph: one node per community, edges summed.
        sqlite::exec_or_die(db, "DROP TABLE IF EXISTS temp.map; CREATE TEMP TABLE map (node INTEGER PRIMARY KEY, c INTEGER)");
        let ins = sqlite::prepare_or_die(db, "INSERT INTO temp.map (node, c) VALUES (?1, ?2)");
        for i in 0..size {
            sqlite::reset(ins);
            sqlite::bind_int(ins, 1, i);
            sqlite::bind_int(ins, 2, renum[comm[i]]);
            sqlite::step_done(ins);
        }
        sqlite::finalize(ins);
        sqlite::exec_or_die(db, """
            CREATE TEMP TABLE g2 AS
                SELECT ma.c AS a, mb.c AS b, SUM(g.w) AS w
                FROM temp.g g JOIN temp.map ma ON ma.node = g.a JOIN temp.map mb ON mb.node = g.b
                GROUP BY ma.c, mb.c;
            DROP TABLE temp.g;
            ALTER TABLE temp.g2 RENAME TO g;
        """);
        guard c < size else { break; }
        size = c;
    }
    let up = sqlite::prepare_or_die(db, "UPDATE files SET community = ?2 WHERE id = ?1");
    for f in 0..n {
        sqlite::reset(up);
        sqlite::bind_int(up, 1, ids[f]);
        sqlite::bind_int(up, 2, member[f]);
        sqlite::step_done(up);
    }
    sqlite::finalize(up);
    // Each test file joins the code community it links to most (imports
    // and calls, either way); a test linked to no code shares one community
    // of unlinked tests.
    sqlite::exec_or_die(db, """
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
    """);
    var rounds = levels;
    // Number the communities by their code files (unlinked tests last) and
    // name each after its most linked code file.
    sqlite::exec_or_die(db, """
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
    """);
    return rounds;
}
