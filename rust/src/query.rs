// The questions a graph answers, as JSON: overview, find, neighbors,
// callers, touches. From src/spread-wings.goose; the queries are its own.

use crate::db::Db;
use crate::sql;
use crate::store::get_meta;
use crate::util::*;

/// s as a JSON string: quoted, with '"', '\' and the control characters
/// escaped (what Goose's json::format_string writes).
pub fn jtext(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
    for &c in s {
        if c >= 0x20 && c != b'"' && c != b'\\' { out.push(c); continue; }
        match c {
            b'"' | b'\\' => { out.push(b'\\'); out.push(c); }
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            8 => out.extend_from_slice(b"\\b"),
            12 => out.extend_from_slice(b"\\f"),
            _ => {
                out.extend_from_slice(b"\\u00");
                out.push(b"0123456789abcdef"[(c >> 4) as usize]);
                out.push(b"0123456789abcdef"[(c & 15) as usize]);
            }
        }
    }
    out.push(b'"');
}

pub fn jstr(out: &mut Vec<u8>, key: &str, v: &[u8]) {
    jtext(out, key.as_bytes());
    out.push(b':');
    jtext(out, v);
}

pub fn jint(out: &mut Vec<u8>, key: &str, v: i64) {
    jtext(out, key.as_bytes());
    out.push(b':');
    push_int(out, v);
}

fn add(out: &mut Vec<u8>, s: &str) { out.extend_from_slice(s.as_bytes()); }

/// A JSON array of the first text column of `sql` (with one optional int parameter).
pub fn text_list(db: &Db, sql: &str, p: i64, out: &mut Vec<u8>) {
    let mut err = String::new();
    let st = db.prepare_or_die(sql.as_bytes());
    if p != 0 { st.bind_int(1, p); }
    out.push(b'[');
    let mut first = true;
    while st.step(&mut err) == 1 {
        if !first { out.push(b','); }
        first = false;
        jtext(out, &st.col_text(0));
    }
    out.push(b']');
}

pub fn overview(db: &Db, out: &mut Vec<u8>) {
    let mut err = String::new();
    let root = get_meta(db, b"root").unwrap_or_default();
    out.push(b'{');
    jstr(out, "root", &root); out.push(b',');
    jint(out, "files", db.scalar(b"SELECT COUNT(*) FROM files")); out.push(b',');
    jint(out, "definitions", db.scalar(b"SELECT COUNT(*) FROM symbols")); out.push(b',');
    jint(out, "call_sites", db.scalar(b"SELECT COUNT(*) FROM calls")); out.push(b',');
    jint(out, "file_links", db.scalar(b"SELECT COUNT(*) FROM file_edges")); out.push(b',');
    add(out, "\"evidence\":\"syntax only: links are matched by name or path, not compiler-resolved\",");
    add(out, "\"communities\":[");
    let st = db.prepare_or_die(b"SELECT id, label, size, tests FROM communities ORDER BY id LIMIT 25");
    let mut first = true;
    while st.step(&mut err) == 1 {
        if !first { out.push(b','); }
        first = false;
        let cid = st.col_int(0);
        out.push(b'{');
        jint(out, "id", cid); out.push(b',');
        jstr(out, "label", &st.col_text(1)); out.push(b',');
        jint(out, "code_files", st.col_int(2)); out.push(b',');
        jint(out, "test_files", st.col_int(3)); out.push(b',');
        add(out, "\"main_files\":");
        text_list(db, sql::SPREAD_WINGS_L349, cid, out);
        add(out, ",\"most_called\":");
        text_list(db, sql::SPREAD_WINGS_L357, cid, out);
        out.push(b'}');
    }
    add(out, "]}");
}

pub fn find_defs(db: &Db, name: &[u8], out: &mut Vec<u8>) {
    let mut err = String::new();
    let st = db.prepare_or_die(sql::SPREAD_WINGS_L372.as_bytes());
    st.bind_text(1, name);
    out.push(b'[');
    let mut first = true;
    while st.step(&mut err) == 1 {
        if !first { out.push(b','); }
        first = false;
        out.push(b'{');
        jstr(out, "name", &st.col_text(0)); out.push(b',');
        jstr(out, "kind", &st.col_text(1)); out.push(b',');
        jstr(out, "path", &st.col_text(2)); out.push(b',');
        jint(out, "line", st.col_int(3)); out.push(b',');
        jint(out, "community", st.col_int(4)); out.push(b',');
        jint(out, "call_sites_by_name", st.col_int(5));
        out.push(b'}');
    }
    out.push(b']');
}

pub fn neighbors(db: &Db, path: &[u8], out: &mut Vec<u8>) -> bool {
    let mut err = String::new();
    let (fid, cid, lang);
    {
        let st = db.prepare_or_die(b"SELECT id, community, lang FROM files WHERE path = ?1");
        st.bind_text(1, path);
        if st.step(&mut err) != 1 {
            add(out, "no such file in the graph: ");
            out.extend_from_slice(path);
            return false;
        }
        fid = st.col_int(0);
        cid = st.col_int(1);
        lang = st.col_text(2);
    }
    out.push(b'{');
    jstr(out, "path", path); out.push(b',');
    jstr(out, "language", &lang); out.push(b',');
    jint(out, "community", cid); out.push(b',');
    add(out, "\"defines\":");
    text_list(db, "SELECT name FROM symbols WHERE file_id = ?1 ORDER BY row", fid, out);
    add(out, ",\"imports\":");
    text_list(db, "SELECT DISTINCT f.path FROM file_edges e JOIN files f ON f.id = e.dst WHERE e.src = ?1 AND e.kind = 'import' ORDER BY f.path", fid, out);
    add(out, ",\"imported_by\":");
    text_list(db, "SELECT DISTINCT f.path FROM file_edges e JOIN files f ON f.id = e.src WHERE e.dst = ?1 AND e.kind = 'import' ORDER BY f.path", fid, out);
    add(out, ",\"calls_into\":");
    text_list(db, "SELECT f.path FROM file_edges e JOIN files f ON f.id = e.dst WHERE e.src = ?1 AND e.kind = 'call' ORDER BY e.weight DESC, f.path", fid, out);
    add(out, ",\"called_from\":");
    text_list(db, "SELECT f.path FROM file_edges e JOIN files f ON f.id = e.src WHERE e.dst = ?1 AND e.kind = 'call' ORDER BY e.weight DESC, f.path", fid, out);
    add(out, ",\"evidence\":\"by name or path\"}");
    true
}

pub fn callers(db: &Db, name: &[u8], out: &mut Vec<u8>) {
    let mut err = String::new();
    let st = db.prepare_or_die(sql::SPREAD_WINGS_L439.as_bytes());
    st.bind_text(1, name);
    add(out, "{\"name\":");
    jtext(out, name);
    add(out, ",\"evidence\":\"each site's resolution says how it was tied to a definition: own_type or type_name (the type the call names: this.f(), Type.f()), same_file, imported_name, module_alias or imported_file (import evidence), compiler (a Swan map), decided (Span-02, weight = probability), by_name (any definition with this name), or unlinked (a library, builtin or outside object)\",\"sites\":[");
    let mut first = true;
    while st.step(&mut err) == 1 {
        if !first { out.push(b','); }
        first = false;
        out.push(b'{');
        jstr(out, "path", &st.col_text(0)); out.push(b',');
        jint(out, "line", st.col_int(1)); out.push(b',');
        jstr(out, "in", &st.col_text(2)); out.push(b',');
        jstr(out, "resolution", &st.col_text(3)); out.push(b',');
        jstr(out, "defined_in", &st.col_text(4));
        out.push(b'}');
    }
    add(out, "]}");
}

/// What changing a definition touches, in one answer: the files that define
/// it, call it or import its file, which of those are tests, and which
/// groups of the repo they sit in. `path` narrows a name defined in several
/// files to the one meant.
pub fn touches(db: &Db, name: &[u8], path: &[u8], out: &mut Vec<u8>) -> bool {
    let mut err = String::new();
    db.exec_or_die(b"DROP TABLE IF EXISTS temp.t_defs; DROP TABLE IF EXISTS temp.t_touch;");
    {
        let mk = db.prepare_or_die(sql::SPREAD_WINGS_L487.as_bytes());
        mk.bind_text(1, name);
        mk.bind_text(2, path);
        mk.step_done();
    }
    if !(db.scalar(b"SELECT COUNT(*) FROM temp.t_defs") > 0) {
        add(out, "no definition named '");
        out.extend_from_slice(name);
        add(out, "'");
        if !path.is_empty() { add(out, " in "); out.extend_from_slice(path); }
        return false;
    }
    db.exec_or_die(sql::SPREAD_WINGS_L500.as_bytes());
    add(out, "{\"name\":");
    jtext(out, name);
    add(out, ",\"definitions\":[");
    {
        let ds = db.prepare_or_die(sql::SPREAD_WINGS_L516.as_bytes());
        let mut first = true;
        while ds.step(&mut err) == 1 {
            if !first { out.push(b','); }
            first = false;
            out.push(b'{');
            jstr(out, "path", &ds.col_text(0)); out.push(b',');
            jint(out, "line", ds.col_int(1)); out.push(b',');
            jstr(out, "kind", &ds.col_text(2)); out.push(b',');
            jint(out, "community", ds.col_int(3));
            out.push(b'}');
        }
    }
    add(out, "],\"files\":[");
    {
        let fs = db.prepare_or_die(sql::SPREAD_WINGS_L537.as_bytes());
        let mut first = true;
        while fs.step(&mut err) == 1 {
            if !first { out.push(b','); }
            first = false;
            out.push(b'{');
            jstr(out, "path", &fs.col_text(0));
            add(out, ",\"why\":[");
            let mut w = 0;
            if fs.col_int(1) > 0 { add(out, "\"defines it\""); w += 1; }
            if fs.col_int(2) > 0 { if w > 0 { out.push(b','); } add(out, "\"calls it\""); w += 1; }
            if fs.col_int(4) > 0 { if w > 0 { out.push(b','); } add(out, "\"imports its file\""); }
            add(out, "],");
            jint(out, "call_sites", fs.col_int(2)); out.push(b',');
            jint(out, "matched_by_name_only", fs.col_int(3));
            add(out, ",\"is_test\":");
            add(out, if fs.col_int(5) > 0 { "true" } else { "false" });
            out.push(b',');
            jint(out, "community", fs.col_int(6));
            out.push(b'}');
        }
    }
    add(out, "],\"tests\":");
    text_list(db, "SELECT f.path FROM t_touch t JOIN files f ON f.id = t.file_id WHERE f.is_test = 1 ORDER BY f.path", 0, out);
    add(out, ",\"communities\":[");
    {
        let cs = db.prepare_or_die(sql::SPREAD_WINGS_L568.as_bytes());
        let mut first = true;
        while cs.step(&mut err) == 1 {
            if !first { out.push(b','); }
            first = false;
            out.push(b'{');
            jint(out, "id", cs.col_int(0)); out.push(b',');
            jstr(out, "label", &cs.col_text(1)); out.push(b',');
            jint(out, "files", cs.col_int(2));
            out.push(b'}');
        }
    }
    add(out, "],\"summary\":{");
    jint(out, "definitions", db.scalar(b"SELECT COUNT(*) FROM temp.t_defs")); out.push(b',');
    jint(out, "files", db.scalar(b"SELECT COUNT(*) FROM temp.t_touch")); out.push(b',');
    jint(out, "test_files", db.scalar(b"SELECT COUNT(*) FROM temp.t_touch t JOIN files f ON f.id = t.file_id WHERE f.is_test = 1")); out.push(b',');
    jint(out, "communities", db.scalar(b"SELECT COUNT(DISTINCT COALESCE(f.community, 0)) FROM temp.t_touch t JOIN files f ON f.id = t.file_id")); out.push(b',');
    jint(out, "call_sites", db.scalar(b"SELECT COALESCE(SUM(sites), 0) FROM temp.t_touch")); out.push(b',');
    jint(out, "matched_by_name_only", db.scalar(b"SELECT COALESCE(SUM(guessed), 0) FROM temp.t_touch"));
    add(out, "},\"evidence\":\"from syntax: call sites tied by import evidence, a compiler map or a decision count as calls; matched_by_name_only counts the ones tied by name alone, which may be another definition's. A file that only imports the defining file may not use this name. For the exact sites and to make the edits, use Swan.\"}");
    db.exec_or_die(b"DROP TABLE temp.t_defs; DROP TABLE temp.t_touch;");
    true
}
