// From facts to edges, and edges to communities. From src/graph.goose, kept
// line for line; every script is the Goose program's own text (sql.rs).

use crate::db::{Db, Stmt};
use crate::sql;
use crate::store::open_marks;
use crate::util::*;

fn strip_ext(p: &[u8]) -> &[u8] {
    let dot = rfind(p, b".");
    let slash = rfind(p, b"/");
    if dot > slash { &p[..dot as usize] } else { p }
}

/// `a/./b/../c` -> `a/c`, for a path relative to the repo root. None when it
/// climbs out of the repo.
fn normalize(p: &[u8]) -> Option<Vec<u8>> {
    let mut parts: Vec<&[u8]> = Vec::new();
    let mut n: i64 = 0;
    for seg in p.split(|&c| c == b'/') {
        if seg.is_empty() || seg == b"." {
        } else if seg == b".." {
            if n > 0 { parts.pop(); n -= 1; } else { n = -1000000; }
        } else {
            parts.push(seg);
            n += 1;
        }
    }
    if n < 0 { return None; }
    Some(parts.join(&b'/'))
}

fn file_id(st: &Stmt, path: &[u8]) -> i64 {
    let mut err = String::new();
    st.reset();
    st.bind_text(1, path);
    if st.step(&mut err) == 1 { st.col_int(0) } else { 0 }
}

/// The first of the candidate paths that is an indexed file, else 0.
fn first_file(st: &Stmt, like_st: &Stmt, pkg_st: &Stmt, candidates: &[u8]) -> i64 {
    let mut found: i64 = 0;
    for c in candidates.split(|&x| x == b'\n') {
        if found == 0 && !c.is_empty() {
            // "%/x/src/lib.rs": any indexed path ending in /x/src/lib.rs.
            // ">pkg/mod.py": a path ending in /pkg/mod.py whose folder before
            // it is not itself a Python package (see PKG_SUFFIX_SQL).
            if c[0] == b'%' { found = file_id(like_st, c); }
            else if c[0] == b'>' { found = file_id(pkg_st, &c[1..]); }
            else { found = file_id(st, c); }
        }
    }
    found
}

fn put(out: &mut Vec<u8>, parts: &[&[u8]]) {
    for p in parts { out.extend_from_slice(p); }
}

/// Candidate files for one import, best first, one per line.
fn import_candidates(lang: &[u8], importer: &[u8], module: &[u8], out: &mut Vec<u8>) {
    let slash = rfind(importer, b"/");
    let dir: &[u8] = if slash >= 0 { &importer[..slash as usize] } else { b"" };
    if lang == b"python" {
        let mut m = module;
        let mut up = 0;
        while !m.is_empty() && m[0] == b'.' { up += 1; m = &m[1..]; }
        let rel: Vec<u8> = m.iter().map(|&c| if c == b'.' { b'/' } else { c }).collect();
        let base: Vec<u8>;
        if up > 0 {
            let mut joined: Vec<u8> = dir.to_vec();
            for _ in 1..up { joined.extend_from_slice(b"/.."); }
            joined.push(b'/');
            joined.extend_from_slice(&rel);
            base = match normalize(&joined) { Some(b) => b, None => return };
        } else {
            base = rel;
        }
        if base.is_empty() { return; }
        put(out, &[&base, b".py\n", &base, b"/__init__.py\n"]);
        // A top-level package under src/ or the importer's own folder.
        put(out, &[b"src/", &base, b".py\n", b"src/", &base, b"/__init__.py\n"]);
        if !dir.is_empty() { put(out, &[dir, b"/", &base, b".py\n"]); }
        // A package kept in some other folder (python/mypkg, packages/x/mypkg):
        // by its path below that folder. A lone module name (`import utils`)
        // is tried only as a package, since any utils.py would match.
        if up == 0 {
            if find(&base, b"/") > 0 { put(out, &[b">", &base, b".py\n"]); }
            put(out, &[b">", &base, b"/__init__.py\n"]);
        }
        return;
    }
    if lang == b"goose" {
        // `import .x;` and `import .a.b;` are x.goose and a/b.goose beside the
        // importer. No leading dot: the standard library or a fetched package.
        if !(module.len() > 1 && module[0] == b'.') { return; }
        let rel: Vec<u8> = module[1..].iter().map(|&c| if c == b'.' { b'/' } else { c }).collect();
        if !dir.is_empty() { put(out, &[dir, b"/", &rel, b".goose\n"]); } else { put(out, &[&rel, b".goose\n"]); }
        return;
    }
    if lang == b"rust" {
        // crate::a::b, self::a, super::a: the module files a.rs, a/mod.rs,
        // a/b.rs near the importer's crate root (the folder holding src/).
        let mut m = module;
        let mut root: Vec<u8> = Vec::new();
        let src_at = find(importer, b"src/");
        if src_at >= 0 { root.extend_from_slice(&importer[..src_at as usize + 4]); }
        let mut from_dir: Vec<u8> = Vec::new();
        if starts_with(m, b"mod::") {
            // `mod x;` in lib.rs, main.rs or mod.rs is x.rs beside it; in
            // foo.rs it is foo/x.rs.
            let name = &m[5..];
            let base_name = if slash >= 0 { &importer[slash as usize + 1..] } else { importer };
            let mut d: Vec<u8> = Vec::new();
            if !dir.is_empty() { put(&mut d, &[dir, b"/"]); }
            if !(base_name == b"lib.rs" || base_name == b"main.rs" || base_name == b"mod.rs") {
                put(&mut d, &[strip_ext(base_name), b"/"]);
            }
            put(out, &[&d, name, b".rs\n", &d, name, b"/mod.rs\n"]);
            return;
        }
        if starts_with(m, b"crate::") { m = &m[7..]; from_dir.extend_from_slice(&root); }
        else if starts_with(m, b"self::") { m = &m[6..]; if !dir.is_empty() { put(&mut from_dir, &[dir, b"/"]); } }
        else if starts_with(m, b"super::") {
            m = &m[7..];
            let up = rfind(dir, b"/");
            if up >= 0 { put(&mut from_dir, &[&dir[..up as usize], b"/"]); }
        } else {
            // Another crate: a workspace member named like it (pitl_core is
            // crates/pitl-core/src/lib.rs); anything else is external.
            let c = find(m, b"::");
            let crate_name = if c > 0 { &m[..c as usize] } else { m };
            let dashed: Vec<u8> = crate_name.iter().map(|&ch| if ch == b'_' { b'-' } else { ch }).collect();
            put(out, &[b"%/", &dashed, b"/src/lib.rs\n", b"%/", crate_name, b"/src/lib.rs\n", &dashed, b"/src/lib.rs\n", crate_name, b"/src/lib.rs\n"]);
            return;
        }
        let mut path: Vec<u8> = Vec::new();
        for sg in m.split(|&c| c == b':') {
            if !sg.is_empty() {
                if !path.is_empty() { path.push(b'/'); }
                path.extend_from_slice(sg);
            }
        }
        // Longest path first: a/b.rs, then a.rs, a/mod.rs.
        loop {
            put(out, &[&from_dir, &path, b".rs\n", &from_dir, &path, b"/mod.rs\n"]);
            let cut = rfind(&path, b"/");
            if !(cut > 0) { break; }
            path.truncate(cut as usize);
        }
        return;
    }
    // TypeScript and JavaScript: relative paths only; packages stay external.
    if !(!module.is_empty() && module[0] == b'.') { return; }
    let mut joined: Vec<u8> = Vec::new();
    if !dir.is_empty() { put(&mut joined, &[dir, b"/", module]); } else { joined.extend_from_slice(module); }
    let base = match normalize(&joined) { Some(b) => b, None => return };
    put(out, &[&base, b"\n"]); // `./store.js` naming the file itself
    for e in [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".d.ts", "/index.ts", "/index.tsx", "/index.js"] {
        put(out, &[&base, e.as_bytes(), b"\n"]);
    }
    put(out, &[strip_ext(&base), b".ts\n", strip_ext(&base), b".tsx\n"]); // `./m.js` written for `m.ts`
}

fn add_alias(st: &Stmt, file: i64, alias: &[u8], dst: i64) {
    st.reset();
    st.bind_int(1, file);
    st.bind_text(2, alias);
    st.bind_int(3, dst);
    st.step_done();
}

/// Ties each import to the file it names. With only_changed (update), only
/// the imports of the files read again (temp.u_changed): theirs are new rows.
pub fn link_imports(db: &Db, only_changed: bool) -> i64 {
    let mut err = String::new();
    // The imports to tie are listed first, then read from the list (see the
    // Goose source for why).
    db.exec_or_die(&open_marks(sql::GRAPH_L221.as_bytes(), b"only", only_changed));
    let q = db.prepare_or_die(b"SELECT file_id, path, lang, module, r, names FROM temp.imp_todo ORDER BY rowid");
    let ins_alias = db.prepare_or_die(b"INSERT INTO aliases (file_id, alias, dst) VALUES (?1, ?2, ?3)");
    let set_dst = db.prepare_or_die(b"UPDATE imports SET dst = ?2 WHERE rowid = ?1");
    let find_st = db.prepare_or_die(b"SELECT id FROM files WHERE path = ?1");
    // (Of two paths as short, the first by name: said outright, so that the
    // answer does not hang on the order rows happen to be read in.)
    let like_st = db.prepare_or_die(b"SELECT id FROM files WHERE path LIKE ?1 ORDER BY length(path), path LIMIT 1");
    db.exec_or_die(sql::PKG_SUFFIX_SQL.as_bytes());
    let pkg_st = db.prepare_or_die(b"SELECT id FROM pysuf WHERE suffix = ?1 ORDER BY len, ord, id LIMIT 1");
    let ins = db.prepare_or_die(b"INSERT INTO file_edges (src, dst, kind, weight) VALUES (?1, ?2, 'import', 1.0)");
    let mut n: i64 = 0;
    while q.step(&mut err) == 1 {
        let src = q.col_int(0);
        let path = q.col_text(1);
        let lang = q.col_text(2);
        let module = q.col_text(3);
        let mut cands: Vec<u8> = Vec::new();
        import_candidates(&lang, &path, &module, &mut cands);
        let dst = first_file(&find_st, &like_st, &pkg_st, &cands);
        let names = q.col_text(5);
        // Names that stand for a whole module: `import a.b as x` and
        // `import * as x` (marked '@'), `from pkg import mod` where pkg/mod is
        // a module file, and Rust `use a::b;` where b is a module file.
        if names.len() > 1 && names[0] == b'@' && dst != 0 {
            add_alias(&ins_alias, src, &names[1..], dst);
        } else if lang == b"python" && !names.is_empty() {
            for nm in names.split(|&c| c == b',') {
                if !nm.is_empty() {
                    // `mod>x`: module mod bound as x.
                    let gt = find(nm, b">");
                    let modname = if gt > 0 { &nm[..gt as usize] } else { nm };
                    let bound = if gt > 0 { &nm[gt as usize + 1..] } else { nm };
                    let mut sub: Vec<u8> = Vec::new();
                    let mut full = module.clone();
                    if !(!module.is_empty() && module[module.len() - 1] == b'.') { full.push(b'.'); }
                    full.extend_from_slice(modname);
                    import_candidates(&lang, &path, &full, &mut sub);
                    let mdst = first_file(&find_st, &like_st, &pkg_st, &sub);
                    if mdst != 0 && mdst != src && !bound.is_empty() { add_alias(&ins_alias, src, bound, mdst); }
                }
            }
        } else if lang == b"rust" && dst != 0 && !names.is_empty() && find(&names, b",") < 0 && find(&module, b"::{") < 0 {
            // `use crate::state;` binds `state` when state is the file itself.
            let last = rfind(&module, b"::");
            let seg = if last >= 0 { &module[last as usize + 2..] } else { &module[..] };
            if seg == &names[..] { add_alias(&ins_alias, src, &names, dst); }
        }
        if dst != 0 && dst != src {
            set_dst.reset();
            set_dst.bind_int(1, q.col_int(4));
            set_dst.bind_int(2, dst);
            set_dst.step_done();
            ins.reset();
            ins.bind_int(1, src);
            ins.bind_int(2, dst);
            ins.step_done();
            n += 1;
        }
    }
    drop(q);
    drop(find_st);
    drop(like_st);
    drop(pkg_st);
    db.exec_or_die(b"DROP TABLE pysuf; DROP TABLE temp.imp_todo");
    n
}

/// Each call site is tied to the definitions its name could mean, by the
/// strongest evidence the code gives (the rules are the script's own).
/// With only_dirty (update), only the calls listed in temp.dirty are tied.
pub fn link_calls(db: &Db, only_dirty: bool) {
    make_roots(db);
    db.exec_or_die(&open_marks(sql::LINK_CALLS_SQL.as_bytes(), b"dirty", only_dirty));
    call_file_edges(db, only_dirty);
}

/// The repo's own top-level names: an import whose first segment is none of
/// them comes from outside the repo.
pub fn make_roots(db: &Db) {
    db.exec_or_die(sql::GRAPH_L330.as_bytes());
}

pub fn roots_text(db: &Db) -> Vec<u8> {
    make_roots(db);
    let mut err = String::new();
    let mut out: Vec<u8> = Vec::new();
    {
        let st = db.prepare_or_die(b"SELECT seg FROM temp.roots ORDER BY seg");
        while st.step(&mut err) == 1 {
            out.extend_from_slice(&st.col_text(0));
            out.push(b'\n');
        }
    }
    db.exec_or_die(b"DROP TABLE temp.roots");
    out
}

/// File links from call links. With only_dirty (update), those out of the
/// files in temp.dirty_files, in place of the ones they had.
pub fn call_file_edges(db: &Db, only_dirty: bool) {
    db.exec_or_die(&open_marks(sql::GRAPH_L832.as_bytes(), b"dirty", only_dirty));
}

/// One level of Louvain's local moving on a graph in CSR form (off, nbr, w):
/// each node moves to the neighboring community with the best modularity
/// gain until no node moves. Returns true if any node moved. (The sums are
/// taken in the Goose program's order: the last digit of a sum hangs on it.)
fn local_moving(n: usize, off: &[i64], nbr: &[i64], w: &[f64], comm: &mut [i64], gamma: f64) -> bool {
    let mut k: Vec<f64> = vec![0.0; n];
    let mut tot: Vec<f64> = vec![0.0; n];
    let mut m2 = 0.0;
    for i in 0..n {
        let mut d = 0.0;
        for e in off[i]..off[i + 1] { d = d + w[e as usize]; }
        k[i] = d;
        m2 = m2 + d;
    }
    if !(m2 > 0.0) { return false; }
    for i in 0..n { tot[comm[i] as usize] = tot[comm[i] as usize] + k[i]; }
    let mut wc: Vec<f64> = vec![0.0; n];
    let mut touched: Vec<usize> = Vec::new();
    let mut moved_any = false;
    let mut pass = 0;
    loop {
        let mut moved = false;
        for i in 0..n {
            let c0 = comm[i] as usize;
            touched.clear();
            for e in off[i]..off[i + 1] {
                let j = nbr[e as usize] as usize;
                if j != i {
                    let c = comm[j] as usize;
                    if wc[c] == 0.0 { touched.push(c); }
                    wc[c] = wc[c] + w[e as usize];
                }
            }
            tot[c0] = tot[c0] - k[i];
            let mut best = c0;
            let mut best_gain = wc[c0] - gamma * tot[c0] * k[i] / m2;
            for &c in &touched {
                let gain = wc[c] - gamma * tot[c] * k[i] / m2;
                if gain > best_gain + 1e-12 {
                    best = c;
                    best_gain = gain;
                }
            }
            tot[best] = tot[best] + k[i];
            if best != c0 { comm[i] = best as i64; moved = true; }
            for &c in &touched { wc[c] = 0.0; }
        }
        pass += 1;
        if moved { moved_any = true; }
        if !(moved && pass < 50) { break; }
    }
    moved_any
}

/// Loads `table` (a, b, w; both directions, 0-based dense ids below n) as CSR.
fn load_csr(db: &Db, table: &str, n: usize, off: &mut Vec<i64>, nbr: &mut Vec<i64>, w: &mut Vec<f64>) {
    let mut err = String::new();
    off.clear();
    nbr.clear();
    w.clear();
    off.resize(n + 1, 0);
    // Weights as integers in thousandths, as the Goose program reads them.
    let st = db.prepare_or_die(format!("SELECT a, b, CAST(ROUND(w * 1000) AS INTEGER) FROM {} ORDER BY a, b", table).as_bytes());
    let mut row_a: Vec<i64> = Vec::new();
    while st.step(&mut err) == 1 {
        row_a.push(st.col_int(0));
        nbr.push(st.col_int(1));
        w.push(st.col_int(2) as f64 / 1000.0);
    }
    for a in row_a { off[a as usize + 1] = off[a as usize + 1] + 1; }
    for i in 0..n { off[i + 1] = off[i + 1] + off[i]; }
}

/// Louvain over the undirected file graph (imports and by-name calls,
/// weighted): local moving, then each community becomes one node, until
/// nothing moves. Deterministic: same repo, same communities.
pub fn communities(db: &Db, gamma: f64) -> i64 {
    let n = db.scalar(b"SELECT COUNT(*) FROM files") as usize;
    db.exec_or_die(b"DROP TABLE IF EXISTS temp.ford; CREATE TEMP TABLE ford (id INTEGER PRIMARY KEY, ord INTEGER)");
    if db.scalar(b"SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'stamps'") == 1
        && db.scalar(b"SELECT COUNT(*) FROM stamps s JOIN files f ON f.id = s.file_id WHERE s.ord IS NOT NULL") == n as i64
    {
        db.exec_or_die(b"INSERT INTO temp.ford SELECT file_id, ROW_NUMBER() OVER (ORDER BY ord, file_id) - 1 FROM stamps WHERE file_id IN (SELECT id FROM files)");
    } else {
        db.exec_or_die(b"INSERT INTO temp.ford SELECT id, ROW_NUMBER() OVER (ORDER BY id) - 1 FROM files");
    }
    let mut ids: Vec<i64> = Vec::new(); // node number -> file row
    {
        let mut ford_err = String::new();
        let ford_st = db.prepare_or_die(b"SELECT id FROM temp.ford ORDER BY ord");
        while ford_st.step(&mut ford_err) == 1 { ids.push(ford_st.col_int(0)); }
    }
    // Tests are grouped with the code they exercise, not with each other.
    db.exec_or_die(sql::GRAPH_L956.as_bytes());
    let mut member: Vec<i64> = (0..n as i64).collect(); // file index -> current community
    let mut size = n;
    let mut levels: i64 = 0;
    while levels < 20 && size > 1 {
        let mut off: Vec<i64> = Vec::new();
        let mut nbr: Vec<i64> = Vec::new();
        let mut w: Vec<f64> = Vec::new();
        load_csr(db, "temp.g", size, &mut off, &mut nbr, &mut w);
        let mut comm: Vec<i64> = (0..size as i64).collect();
        if !local_moving(size, &off, &nbr, &w, &mut comm, gamma) { break; }
        levels += 1;
        // Renumber the communities 0..c-1 in node order.
        let mut renum: Vec<i64> = vec![-1; size];
        let mut c: i64 = 0;
        for i in 0..size {
            if renum[comm[i] as usize] < 0 { renum[comm[i] as usize] = c; c += 1; }
        }
        for f in 0..n { member[f] = renum[comm[member[f] as usize] as usize]; }
        // The next level's graph: one node per community, edges summed.
        db.exec_or_die(b"DROP TABLE IF EXISTS temp.map; CREATE TEMP TABLE map (node INTEGER PRIMARY KEY, c INTEGER)");
        {
            let ins = db.prepare_or_die(b"INSERT INTO temp.map (node, c) VALUES (?1, ?2)");
            for i in 0..size {
                ins.reset();
                ins.bind_int(1, i as i64);
                ins.bind_int(2, renum[comm[i] as usize]);
                ins.step_done();
            }
        }
        db.exec_or_die(sql::GRAPH_L1005.as_bytes());
        if !((c as usize) < size) { break; }
        size = c as usize;
    }
    {
        let up = db.prepare_or_die(b"UPDATE files SET community = ?2 WHERE id = ?1");
        for f in 0..n {
            up.reset();
            up.bind_int(1, ids[f]);
            up.bind_int(2, member[f]);
            up.step_done();
        }
    }
    // Each test file joins the code community it links to most.
    db.exec_or_die(sql::GRAPH_L1027.as_bytes());
    let rounds = levels;
    // Number the communities by their code files (unlinked tests last) and
    // name each after its most linked code file.
    db.exec_or_die(sql::GRAPH_L1043.as_bytes());
    rounds
}
