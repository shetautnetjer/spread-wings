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
fn first_file(st: i64, like_st: i64, candidates: const u8[:]) -> i64 {
    var found: i64 = 0;
    each_split(candidates, '\n') { c =>
        if found == 0 && c.len > 0 {
            // "%/x/src/lib.rs": any indexed path ending in /x/src/lib.rs.
            if c[0] == '%' { found = file_id(like_st, c); } else { found = file_id(st, c); }
        }
    };
    return found;
}

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

fn link_imports(db: i64) -> i64 {
    var err: u8[>..] = [];
    let q = sqlite::prepare_or_die(db, "SELECT i.file_id, f.path, f.lang, i.module, i.rowid, COALESCE(i.names, '') FROM imports i JOIN files f ON f.id = i.file_id");
    let ins_alias = sqlite::prepare_or_die(db, "INSERT INTO aliases (file_id, alias, dst) VALUES (?1, ?2, ?3)");
    let set_dst = sqlite::prepare_or_die(db, "UPDATE imports SET dst = ?2 WHERE rowid = ?1");
    let find_st = sqlite::prepare_or_die(db, "SELECT id FROM files WHERE path = ?1");
    let like_st = sqlite::prepare_or_die(db, "SELECT id FROM files WHERE path LIKE ?1 ORDER BY length(path) LIMIT 1");
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
        let dst = first_file(find_st, like_st, cands);
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
                    var sub: u8[>..] = [];
                    import_candidates(lang, path, str(module, if module.len > 0 && module[module.len - 1] == '.' { "" } else { "." }, n), sub);
                    let mdst = first_file(find_st, like_st, sub);
                    if mdst != 0 && mdst != src { add_alias(ins_alias, src, n, mdst); }
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
    sqlite::finalize(set_dst);
    sqlite::finalize(ins_alias);
    sqlite::finalize(ins);
    return n;
}

// Each call site is tied to the definitions its name could mean, by the
// strongest evidence the code gives, first match wins:
//   same_file      a definition with that name in the caller's own file;
//   imported_name  the caller's file imports that name from a file that
//                  defines it (`from m import f`, `import { f }`, `use m::F`);
//   imported_file  the caller's file imports a file that defines it;
//   by_name        any definition with that name (only for names defined in
//                  at most 8 places).
// Several definitions at one level share the call's weight. The rule used
// is stored on the link as `resolution`.
fn link_calls(db: i64) {
    sqlite::exec_or_die(db, """
        CREATE TEMP TABLE defs AS
            SELECT s.id AS sid, s.file_id AS sfile, s.name AS name FROM symbols s
            WHERE s.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface');
        CREATE INDEX defs_name ON defs(name);
        CREATE TEMP TABLE ndefs AS SELECT name, COUNT(*) AS n FROM defs GROUP BY name;
        CREATE INDEX ndefs_name ON ndefs(name);
        -- Candidate definitions per call site, for names defined in at most 50 places.
        CREATE TEMP TABLE cands AS
            SELECT c.rowid AS cid, c.file_id AS cfile, c.callee AS name, d.sid, d.sfile, k.n
            FROM calls c JOIN ndefs k ON k.name = c.callee AND k.n <= 50
            JOIN defs d ON d.name = c.callee;
        CREATE INDEX cands_cid ON cands(cid);
        CREATE TEMP TABLE chosen (cid INTEGER, sid INTEGER, resolution TEXT);
        CREATE TEMP TABLE done (cid INTEGER PRIMARY KEY);

        INSERT INTO chosen SELECT cid, sid, 'same_file' FROM cands WHERE sfile = cfile;
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        INSERT INTO chosen
            SELECT c.cid, c.sid, 'imported_name' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM imports i WHERE i.file_id = c.cfile AND i.dst = c.sfile
                          AND (',' || i.names || ',') LIKE ('%,' || c.name || ',%'));
        INSERT OR IGNORE INTO done SELECT cid FROM chosen;

        -- Imported from a file that only re-exports it: follow one hop.
        INSERT INTO chosen
            SELECT c.cid, c.sid, 'imported_name' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM imports i JOIN imports j ON j.file_id = i.dst
                          WHERE i.file_id = c.cfile AND j.dst = c.sfile
                            AND (',' || i.names || ',') LIKE ('%,' || c.name || ',%')
                            AND (',' || j.names || ',') LIKE ('%,' || c.name || ',%'));
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

        INSERT INTO chosen
            SELECT c.cid, c.sid, 'imported_file' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done)
              AND EXISTS (SELECT 1 FROM imports i WHERE i.file_id = c.cfile AND i.dst = c.sfile);
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
        INSERT OR IGNORE INTO done SELECT rowid FROM calls WHERE note = 'builtin_method';

        INSERT INTO chosen
            SELECT c.cid, c.sid, 'by_name' FROM cands c
            WHERE c.cid NOT IN (SELECT cid FROM done) AND c.n <= 8;

        INSERT INTO call_edges (caller, callee, file_id, row, weight, by_name, resolution)
            SELECT c.in_symbol, ch.sid, c.file_id, c.row,
                   1.0 / COUNT(*) OVER (PARTITION BY ch.cid), 1, ch.resolution
            FROM chosen ch JOIN calls c ON c.rowid = ch.cid;

        DROP TABLE defs; DROP TABLE ndefs; DROP TABLE cands; DROP TABLE chosen; DROP TABLE done;
    """);
    call_file_edges(db);
}

// File links from call links.
fn call_file_edges(db: i64) {
    sqlite::exec_or_die(db, """
        -- File links from calls count for less than an import: weight 0.3,
        -- and by_name links only for names defined in at most 3 files, so
        -- generic names (`new`, `parse`) don't tie unrelated files together.
        INSERT INTO file_edges (src, dst, kind, weight)
            SELECT e.file_id, s.file_id, 'call', 0.3 * SUM(e.weight)
            FROM call_edges e JOIN symbols s ON s.id = e.callee
            WHERE s.file_id != e.file_id
              AND (e.resolution != 'by_name'
                   OR (SELECT COUNT(DISTINCT d.file_id) FROM symbols d WHERE d.name = s.name AND d.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface')) <= 3)
            GROUP BY e.file_id, s.file_id;
    """);
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
fn communities(db: i64, gamma: f64) -> i64 {
    let n = scalar(db, "SELECT COUNT(*) FROM files");
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
        UPDATE files SET community = id - 1;
        DROP TABLE IF EXISTS temp.g;
        CREATE TEMP TABLE g AS
            SELECT a - 1 AS a, b - 1 AS b, SUM(w) AS w FROM (
                SELECT src AS a, dst AS b, weight AS w FROM file_edges
                UNION ALL SELECT dst, src, weight FROM file_edges)
            WHERE a IN (SELECT id FROM files WHERE is_test = 0) AND b IN (SELECT id FROM files WHERE is_test = 0)
            GROUP BY a, b;
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
        sqlite::bind_int(up, 1, f + 1);
        sqlite::bind_int(up, 2, member[f]);
        sqlite::step_done(up);
    }
    sqlite::finalize(up);
    // Each test file joins the code community it links to most (imports
    // and calls, either way); a test linked to no code shares one community
    // of unlinked tests.
    sqlite::exec_or_die(db, """
        CREATE TEMP TABLE test_votes AS
            SELECT t.id AS tid, c.community AS cm, SUM(e.w) AS w FROM (
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
                LEFT JOIN (SELECT dst AS id, SUM(weight) AS w FROM file_edges GROUP BY dst) i ON i.id = f.id
                LEFT JOIN (SELECT src AS id, SUM(weight) AS w FROM file_edges GROUP BY src) o ON o.id = f.id
                WHERE f.community = r.new
                ORDER BY f.is_test, COALESCE(i.w, 0) + COALESCE(o.w, 0) DESC, f.path LIMIT 1) END, r.size, r.tests
            FROM ranked_c r;
        DROP TABLE ranked_c;
    """);
    return rounds;
}
