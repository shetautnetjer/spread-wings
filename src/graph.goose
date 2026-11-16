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

fn link_imports(db: i64) -> i64 {
    var err: u8[>..] = [];
    let q = sqlite::prepare_or_die(db, "SELECT i.file_id, f.path, f.lang, i.module FROM imports i JOIN files f ON f.id = i.file_id");
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
        if dst != 0 && dst != src {
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
    sqlite::finalize(ins);
    return n;
}

fn link_calls(db: i64) {
    sqlite::exec_or_die(db, """
        -- A definition with the callee's name in the same file wins outright.
        INSERT INTO call_edges (caller, callee, file_id, row, weight, by_name)
        SELECT c.in_symbol, s.id, c.file_id, c.row, 1.0, 1
        FROM calls c JOIN symbols s ON s.file_id = c.file_id AND s.name = c.callee AND s.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface');
        -- Otherwise every definition with that name elsewhere, the weight shared.
        WITH counts AS (SELECT name, COUNT(*) AS n FROM symbols WHERE kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface') GROUP BY name)
        INSERT INTO call_edges (caller, callee, file_id, row, weight, by_name)
        SELECT c.in_symbol, s.id, c.file_id, c.row, 1.0 / k.n, 1
        FROM calls c
        JOIN counts k ON k.name = c.callee AND k.n <= 8
        JOIN symbols s ON s.name = c.callee AND s.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface')
        WHERE NOT EXISTS (SELECT 1 FROM symbols t WHERE t.file_id = c.file_id AND t.name = c.callee AND t.kind IN ('function', 'class', 'struct', 'enum', 'trait', 'interface'));
        -- File links from calls count for less than an import: a call is
        -- matched by name, an import names its file. Names defined in more
        -- than 3 files (`new`, `parse`) are too generic to tie files together.
        INSERT INTO file_edges (src, dst, kind, weight)
        SELECT e.file_id, s.file_id, 'call', 0.3 * SUM(e.weight)
        FROM call_edges e JOIN symbols s ON s.id = e.callee
        WHERE s.file_id != e.file_id
          AND (SELECT COUNT(DISTINCT t.file_id) FROM symbols t WHERE t.name = s.name) <= 3
        GROUP BY e.file_id, s.file_id;
    """);
}

// One level of Louvain's local moving on a graph in CSR form (off, nbr, w):
// each node moves to the neighboring community with the best modularity
// gain until no node moves. Returns true if any node moved.
fn local_moving(n: i64, off: const i64[:], nbr: const i64[:], w: const f64[:], comm: i64[>..]&) -> bool {
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
            var best_gain = wc[c0] - tot[c0] * k[i] / m2;
            for c in touched {
                let gain = wc[c] - tot[c] * k[i] / m2;
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
        w.push(sqlite::col_int(st, 2) as f64 / 1000.0);
    }
    sqlite::finalize(st);
    for a in row_a { off[a + 1] = off[a + 1] + 1; }
    for i in 0..n { off[i + 1] = off[i + 1] + off[i]; }
}

// Louvain over the undirected file graph (imports and by-name calls,
// weighted): local moving, then each community becomes one node, until
// nothing moves. Deterministic: same repo, same communities.
fn communities(db: i64) -> i64 {
    let n = scalar(db, "SELECT COUNT(*) FROM files");
    sqlite::exec_or_die(db, """
        UPDATE files SET community = id - 1;
        DROP TABLE IF EXISTS temp.g;
        CREATE TEMP TABLE g AS
            SELECT a - 1 AS a, b - 1 AS b, SUM(w) AS w FROM (
                SELECT src AS a, dst AS b, weight AS w FROM file_edges
                UNION ALL SELECT dst, src, weight FROM file_edges)
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
        guard local_moving(size, off, nbr, w, comm) else { break; }
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
    var rounds = levels;
    // Number the communities by size and name each after its most common folder.
    sqlite::exec_or_die(db, """
        DELETE FROM communities;
        CREATE TEMP TABLE ranked_c AS
            SELECT community AS old, ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, MIN(path)) AS new, COUNT(*) AS size
            FROM files GROUP BY community;
        UPDATE files SET community = (SELECT new FROM ranked_c WHERE old = files.community);
        -- Named after its most linked file: "pitl-core/src/state.rs".
        INSERT INTO communities (id, label, size)
            SELECT r.new, (
                SELECT f.path FROM files f
                LEFT JOIN (SELECT dst AS id, SUM(weight) AS w FROM file_edges GROUP BY dst) i ON i.id = f.id
                LEFT JOIN (SELECT src AS id, SUM(weight) AS w FROM file_edges GROUP BY src) o ON o.id = f.id
                WHERE f.community = r.new
                ORDER BY COALESCE(i.w, 0) + COALESCE(o.w, 0) DESC, f.path LIMIT 1), r.size
            FROM ranked_c r;
        DROP TABLE ranked_c;
    """);
    return rounds;
}
