// Spread-Wings: a broad code graph for agents, built from syntax alone.
//
//   spread-wings index <repo> <graph.db>     parse, link by name, find communities
//   spread-wings overview <graph.db>         communities and their main files
//   spread-wings find <graph.db> <name>      definitions by name
//   spread-wings neighbors <graph.db> <path> a file's imports and call links
//   spread-wings callers <graph.db> <name>   call sites of a name
//   spread-wings serve <graph.db>            the same over MCP (stdio)
//
// It never runs a repo's code: everything comes from tree-sitter parses, so
// any repo can be indexed with nothing to trust. Edges are matched by name
// or by path, not resolved by a compiler; Swan is the precise counterpart.

import std;
import json;
import sqlite from "shetautnetjer/goose-sqlite@c759de735ae936dcbc197bb9aae40e13565ef21c";
import treesitter from "shetautnetjer/goose-treesitter@59313e9da0b9f1cce8df83cabe53ed73fa92345c";
import .store;
import .extract;
import .treedefs;
import .graph;
import .decide;
import .compiler;
import .score;
import .survey;

let VERSION = "0.1.0";

// "1.25" -> 1.25 (std has no float parser).
fn parse_decimal(s: const u8[:]) -> f64, bool {
    let dot = find(s, ".");
    let whole, ok = parse_int(if dot >= 0 { s[..dot] } else { s });
    guard ok else { return 0.0, false; }
    var v = whole as f64;
    if dot >= 0 {
        var scale = 0.1;
        for c in s[dot + 1..] {
            guard c >= '0' && c <= '9' else { return 0.0, false; }
            v = v + (c - '0') * scale;
            scale = scale / 10.0;
        }
    }
    return v, true;
}

fn usage() {
    write_stderr("""
spread-wings 0.1.0: a broad code graph from syntax alone

  spread-wings index <repo> <graph.db> [--resolution N]   (Louvain resolution, default 1.5)
  spread-wings overview <graph.db>
  spread-wings find <graph.db> <name>
  spread-wings neighbors <graph.db> <path>
  spread-wings callers <graph.db> <name>
  spread-wings touches <graph.db> <name> [path]   what changing it reaches: files, tests, groups
  spread-wings serve <graph.db>
  spread-wings compiler <graph.db> <swan.db>   compiler answers from a Swan map, for every call site it covers
  spread-wings survey <repo>                   the projects a repo holds: where, which package manager, which versions each wants
  spread-wings score <graph.db> <swan.db>      what the graph's definitions and links are worth against a Swan map
  spread-wings decide <graph.db> [--max N] [--workers N]   Span-02 decisions for calls still by_name
                                            (OPENROUTER_API_KEY in the environment; default 5000 questions, 32 parallel requests)
""");
    exit(2);
}

extern fn sw_realpath(path: const u8[:], out: u8[>..]&) -> bool;

fn abs_dir(p: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    guard sw_realpath(p, out) else { abort(str("spread-wings: no such directory: ", p)); }
    return out;
}

fn index_main(repo_arg: const u8[:], db_path: const u8[:], gamma: f64) {
    let repo = abs_dir(repo_arg);
    guard is_dir(repo) else { abort(str("spread-wings: not a directory: ", repo)); }
    let t0 = clock();
    let db = open_fresh(db_path);
    sqlite::exec_or_die(db, "BEGIN");
    let n = extract_repo(db, repo);
    let t1 = clock();
    let imports = link_imports(db);
    link_calls(db);
    let rounds = communities(db, gamma);
    set_meta(db, "root", repo);
    set_meta(db, "version", VERSION);
    set_meta(db, "schema", SCHEMA_NUMBER);
    set_meta(db, "resolution", str(((gamma * 100.0 + 0.5) as i64)));
    sqlite::exec_or_die(db, "COMMIT");
    let t2 = clock();
    print(str("spread-wings: ", n, " files, ", scalar(db, "SELECT COUNT(*) FROM symbols"), " definitions, ",
              scalar(db, "SELECT COUNT(*) FROM calls"), " call sites, ", imports, " imports linked, ",
              scalar(db, "SELECT COUNT(*) FROM call_edges"), " call links, ",
              scalar(db, "SELECT COUNT(*) FROM communities"), " communities (", rounds, " rounds); parse ",
              ((t1 - t0) * 1000.0) as i64, " ms, link ", ((t2 - t1) * 1000.0) as i64, " ms -> ", db_path));
    sqlite::close(db);
}

// --- queries, as JSON ----------------------------------------------------------

fn jstr(out: u8[>..]&, key: const u8[:], v: const u8[:]) {
    json::format_string(out, key);
    out.push(':');
    json::format_string(out, v);
}

fn jint(out: u8[>..]&, key: const u8[:], v: i64) {
    json::format_string(out, key);
    out.push(':');
    json::format_int(out, v);
}

// A JSON array of the first text column of `sql` (with one optional int parameter).
fn text_list(db: i64, sql: const u8[:], p: i64, out: u8[>..]&) {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, sql);
    if p != 0 { sqlite::bind_int(st, 1, p); }
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

fn overview(db: i64, out: u8[>..]&) {
    var err: u8[>..] = [];
    var root: u8[>..] = [];
    get_meta(db, "root", root);
    out.push('{');
    jstr(out, "root", root); out.push(',');
    jint(out, "files", scalar(db, "SELECT COUNT(*) FROM files")); out.push(',');
    jint(out, "definitions", scalar(db, "SELECT COUNT(*) FROM symbols")); out.push(',');
    jint(out, "call_sites", scalar(db, "SELECT COUNT(*) FROM calls")); out.push(',');
    jint(out, "file_links", scalar(db, "SELECT COUNT(*) FROM file_edges")); out.push(',');
    out.append("\"evidence\":\"syntax only: links are matched by name or path, not compiler-resolved\",");
    out.append("\"communities\":[");
    let st = sqlite::prepare_or_die(db, "SELECT id, label, size, tests FROM communities ORDER BY id LIMIT 25");
    var first = true;
    while sqlite::step(st, err) == 1 {
        if !first { out.push(','); }
        first = false;
        let cid = sqlite::col_int(st, 0);
        var label: u8[>..] = [];
        sqlite::col_text(st, 1, label);
        out.push('{');
        jint(out, "id", cid); out.push(',');
        jstr(out, "label", label); out.push(',');
        jint(out, "code_files", sqlite::col_int(st, 2)); out.push(',');
        jint(out, "test_files", sqlite::col_int(st, 3)); out.push(',');
        out.append("\"main_files\":");
        // The files most linked to within and across communities.
        text_list(db, """
            SELECT f.path FROM files f
            LEFT JOIN (SELECT dst AS id, SUM(weight) AS w FROM file_edges GROUP BY dst) i ON i.id = f.id
            LEFT JOIN (SELECT src AS id, SUM(weight) AS w FROM file_edges GROUP BY src) o ON o.id = f.id
            WHERE f.community = ?1
            ORDER BY f.is_test, COALESCE(i.w, 0) + COALESCE(o.w, 0) DESC, f.path LIMIT 5
            """, cid, out);
        out.append(",\"most_called\":");
        text_list(db, """
            SELECT s.name FROM symbols s JOIN files f ON f.id = s.file_id
            JOIN call_edges e ON e.callee = s.id
            WHERE f.community = ?1
              AND (SELECT COUNT(DISTINCT t.file_id) FROM symbols t WHERE t.name = s.name) <= 3
            GROUP BY s.name ORDER BY COUNT(DISTINCT e.file_id) DESC, SUM(e.weight) DESC, s.name LIMIT 5
            """, cid, out);
        out.push('}');
    }
    sqlite::finalize(st);
    out.append("]}");
}

fn find_defs(db: i64, name: const u8[:], out: u8[>..]&) {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, """
        SELECT s.name, s.kind, f.path, s.row, f.community,
               (SELECT COUNT(*) FROM calls c WHERE c.callee = s.name) AS uses
        FROM symbols s JOIN files f ON f.id = s.file_id
        WHERE s.name = ?1 OR (length(?1) >= 3 AND s.name LIKE '%' || ?1 || '%')
        ORDER BY s.name != ?1, s.name, f.path LIMIT 50
        """);
    sqlite::bind_text(st, 1, name);
    out.push('[');
    var first = true;
    while sqlite::step(st, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var n: u8[>..] = [];
        var k: u8[>..] = [];
        var p: u8[>..] = [];
        sqlite::col_text(st, 0, n);
        sqlite::col_text(st, 1, k);
        sqlite::col_text(st, 2, p);
        out.push('{');
        jstr(out, "name", n); out.push(',');
        jstr(out, "kind", k); out.push(',');
        jstr(out, "path", p); out.push(',');
        jint(out, "line", sqlite::col_int(st, 3)); out.push(',');
        jint(out, "community", sqlite::col_int(st, 4)); out.push(',');
        jint(out, "call_sites_by_name", sqlite::col_int(st, 5));
        out.push('}');
    }
    sqlite::finalize(st);
    out.push(']');
}

fn neighbors(db: i64, path: const u8[:], out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, "SELECT id, community, lang FROM files WHERE path = ?1");
    sqlite::bind_text(st, 1, path);
    guard sqlite::step(st, err) == 1 else {
        sqlite::finalize(st);
        out.append("no such file in the graph: ");
        out.append(path);
        return false;
    }
    let fid = sqlite::col_int(st, 0);
    let cid = sqlite::col_int(st, 1);
    var lang: u8[>..] = [];
    sqlite::col_text(st, 2, lang);
    sqlite::finalize(st);
    out.push('{');
    jstr(out, "path", path); out.push(',');
    jstr(out, "language", lang); out.push(',');
    jint(out, "community", cid); out.push(',');
    out.append("\"defines\":");
    text_list(db, "SELECT name FROM symbols WHERE file_id = ?1 ORDER BY row", fid, out);
    out.append(",\"imports\":");
    text_list(db, "SELECT DISTINCT f.path FROM file_edges e JOIN files f ON f.id = e.dst WHERE e.src = ?1 AND e.kind = 'import' ORDER BY f.path", fid, out);
    out.append(",\"imported_by\":");
    text_list(db, "SELECT DISTINCT f.path FROM file_edges e JOIN files f ON f.id = e.src WHERE e.dst = ?1 AND e.kind = 'import' ORDER BY f.path", fid, out);
    out.append(",\"calls_into\":");
    text_list(db, "SELECT f.path FROM file_edges e JOIN files f ON f.id = e.dst WHERE e.src = ?1 AND e.kind = 'call' ORDER BY e.weight DESC, f.path", fid, out);
    out.append(",\"called_from\":");
    text_list(db, "SELECT f.path FROM file_edges e JOIN files f ON f.id = e.src WHERE e.dst = ?1 AND e.kind = 'call' ORDER BY e.weight DESC, f.path", fid, out);
    out.append(",\"evidence\":\"by name or path\"}");
    return true;
}

fn callers(db: i64, name: const u8[:], out: u8[>..]&) {
    var err: u8[>..] = [];
    let st = sqlite::prepare_or_die(db, """
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
        """);
    sqlite::bind_text(st, 1, name);
    out.append("{\"name\":");
    json::format_string(out, name);
    out.append(",\"evidence\":\"each site's resolution says how it was tied to a definition: own_type or type_name (the type the call names: this.f(), Type.f()), same_file, imported_name, module_alias or imported_file (import evidence), compiler (a Swan map), decided (Span-02, weight = probability), by_name (any definition with this name), or unlinked (a library, builtin or outside object)\",\"sites\":[");
    var first = true;
    while sqlite::step(st, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var p: u8[>..] = [];
        var inside: u8[>..] = [];
        sqlite::col_text(st, 0, p);
        sqlite::col_text(st, 2, inside);
        out.push('{');
        jstr(out, "path", p); out.push(',');
        jint(out, "line", sqlite::col_int(st, 1)); out.push(',');
        jstr(out, "in", inside); out.push(',');
        var res: u8[>..] = [];
        var tgt: u8[>..] = [];
        sqlite::col_text(st, 3, res);
        sqlite::col_text(st, 4, tgt);
        jstr(out, "resolution", res); out.push(',');
        jstr(out, "defined_in", tgt);
        out.push('}');
    }
    sqlite::finalize(st);
    out.append("]}");
}

// What changing a definition touches, in one answer: the files that define
// it, call it or import its file, which of those are tests, and which
// groups of the repo they sit in. The broad view to take before an edit;
// Swan then gives the exact sites and makes the edits. `path` narrows a
// name defined in several files to the one meant.
fn touches(db: i64, name: const u8[:], path: const u8[:], out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    sqlite::exec_or_die(db, "DROP TABLE IF EXISTS temp.t_defs; DROP TABLE IF EXISTS temp.t_touch;");
    let mk = sqlite::prepare_or_die(db, """
        CREATE TEMP TABLE t_defs AS
            SELECT s.id, s.file_id, s.row, s.kind FROM symbols s JOIN files f ON f.id = s.file_id
            WHERE s.name = ?1 AND (?2 = '' OR f.path = ?2)
        """);
    sqlite::bind_text(mk, 1, name);
    sqlite::bind_text(mk, 2, path);
    sqlite::step_done(mk);
    sqlite::finalize(mk);
    guard scalar(db, "SELECT COUNT(*) FROM temp.t_defs") > 0 else {
        format(out, "no definition named '", name, "'", if path.len > 0 { str(" in ", path) } else { str("") });
        return false;
    }
    sqlite::exec_or_die(db, """
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
    """);
    out.append("{\"name\":");
    json::format_string(out, name);
    out.append(",\"definitions\":[");
    let ds = sqlite::prepare_or_die(db, """
        SELECT f.path, d.row, d.kind, COALESCE(f.community, 0) FROM t_defs d JOIN files f ON f.id = d.file_id
        ORDER BY f.path, d.row
        """);
    var first = true;
    while sqlite::step(ds, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var p: u8[>..] = [];
        var k: u8[>..] = [];
        sqlite::col_text(ds, 0, p);
        sqlite::col_text(ds, 2, k);
        out.push('{');
        jstr(out, "path", p); out.push(',');
        jint(out, "line", sqlite::col_int(ds, 1)); out.push(',');
        jstr(out, "kind", k); out.push(',');
        jint(out, "community", sqlite::col_int(ds, 3));
        out.push('}');
    }
    sqlite::finalize(ds);
    out.append("],\"files\":[");
    let fs = sqlite::prepare_or_die(db, """
        SELECT f.path, t.defines, t.sites, t.guessed, t.imports, COALESCE(f.is_test, 0), COALESCE(f.community, 0)
        FROM t_touch t JOIN files f ON f.id = t.file_id
        ORDER BY t.defines DESC, f.is_test, t.sites DESC, f.path LIMIT 400
        """);
    first = true;
    while sqlite::step(fs, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var p: u8[>..] = [];
        sqlite::col_text(fs, 0, p);
        out.push('{');
        jstr(out, "path", p);
        out.append(",\"why\":[");
        var w = 0;
        if sqlite::col_int(fs, 1) > 0 { out.append("\"defines it\""); w++; }
        if sqlite::col_int(fs, 2) > 0 { if w > 0 { out.push(','); } out.append("\"calls it\""); w++; }
        if sqlite::col_int(fs, 4) > 0 { if w > 0 { out.push(','); } out.append("\"imports its file\""); }
        out.append("],");
        jint(out, "call_sites", sqlite::col_int(fs, 2)); out.push(',');
        jint(out, "matched_by_name_only", sqlite::col_int(fs, 3));
        out.append(",\"is_test\":");
        out.append(if sqlite::col_int(fs, 5) > 0 { "true" } else { "false" });
        out.push(',');
        jint(out, "community", sqlite::col_int(fs, 6));
        out.push('}');
    }
    sqlite::finalize(fs);
    out.append("],\"tests\":");
    text_list(db, "SELECT f.path FROM t_touch t JOIN files f ON f.id = t.file_id WHERE f.is_test = 1 ORDER BY f.path", 0, out);
    out.append(",\"communities\":[");
    let cs = sqlite::prepare_or_die(db, """
        SELECT COALESCE(f.community, 0), COALESCE(c.label, ''), COUNT(*)
        FROM t_touch t JOIN files f ON f.id = t.file_id LEFT JOIN communities c ON c.id = f.community
        GROUP BY f.community ORDER BY COUNT(*) DESC
        """);
    first = true;
    while sqlite::step(cs, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var l: u8[>..] = [];
        sqlite::col_text(cs, 1, l);
        out.push('{');
        jint(out, "id", sqlite::col_int(cs, 0)); out.push(',');
        jstr(out, "label", l); out.push(',');
        jint(out, "files", sqlite::col_int(cs, 2));
        out.push('}');
    }
    sqlite::finalize(cs);
    out.append("],\"summary\":{");
    jint(out, "definitions", scalar(db, "SELECT COUNT(*) FROM temp.t_defs")); out.push(',');
    jint(out, "files", scalar(db, "SELECT COUNT(*) FROM temp.t_touch")); out.push(',');
    jint(out, "test_files", scalar(db, "SELECT COUNT(*) FROM temp.t_touch t JOIN files f ON f.id = t.file_id WHERE f.is_test = 1")); out.push(',');
    jint(out, "communities", scalar(db, "SELECT COUNT(DISTINCT COALESCE(f.community, 0)) FROM temp.t_touch t JOIN files f ON f.id = t.file_id")); out.push(',');
    jint(out, "call_sites", scalar(db, "SELECT COALESCE(SUM(sites), 0) FROM temp.t_touch")); out.push(',');
    jint(out, "matched_by_name_only", scalar(db, "SELECT COALESCE(SUM(guessed), 0) FROM temp.t_touch"));
    out.append("},\"evidence\":\"from syntax: call sites tied by import evidence, a compiler map or a decision count as calls; matched_by_name_only counts the ones tied by name alone, which may be another definition's. A file that only imports the defining file may not use this name. For the exact sites and to make the edits, use Swan.\"}");
    sqlite::exec_or_die(db, "DROP TABLE temp.t_defs; DROP TABLE temp.t_touch;");
    return true;
}

// --- MCP over stdio ------------------------------------------------------------

let TOOLS = """
[
{"name":"overview","description":"The repo's communities (groups of files that import and call each other), each with its main files and most-called definitions. Start here to understand an unfamiliar codebase. Links are matched by name or path from syntax, not compiler-resolved.","inputSchema":{"type":"object","properties":{}}},
{"name":"find","description":"Definitions (functions, classes, structs, traits, interfaces) by exact name, or containing the name when it has 3+ characters, with file, line, community and how many call sites use that name.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
{"name":"neighbors","description":"One file's definitions, the files it imports and is imported by, and the files it calls into and is called from (by name).","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the repo root."}},"required":["path"]}},
{"name":"callers","description":"Call sites of a name, with file, line and the definition they sit in. Matched by name: calls to any definition with this name.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
{"name":"touches","description":"What changing a definition reaches, in one answer, before you edit: the files that define it, call it or import its file, which of them are tests, and which groups of the repo they are in. Pass path when the name is defined in several files. Broad and from syntax; use Swan for the exact sites and to make the edits.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"path":{"type":"string","description":"The file that defines the one you mean (optional)."}},"required":["name"]}}
]
""";

fn format_id(out: u8[>..]&, id: json::Node?) {
    guard id else { out.append("null"); return; }
    match id.val {
        Int i => json::format_int(out, i.v),
        Str s => json::format_string(out, s.s),
        _ => out.append("null"),
    }
}

fn arg_text(args: json::Node?, key: const u8[:]) -> const u8[:] {
    let v, ok = json::as_string(json::member(args, key));
    return if ok { v } else { "" };
}

fn serve_main(db_path: const u8[:]) {
    let db = open_map(db_path);
    loop {
        var line: u8[>..] = [];
        guard read_line(line) else { break; }
        guard trim(line).len > 0 else { continue; }
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, perr = json::parse(line, doc, decoded);
        var out: u8[>..] = [];
        guard root else {
            out.append("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":");
            json::format_string(out, perr);
            out.append("}}\n");
            write_stdout(out);
            flush_stdout();
            continue;
        }
        let method = arg_text(root, "method");
        let id = json::member(root, "id");
        guard id else { continue; }   // a notification
        let params = json::member(root, "params");
        out.append("{\"jsonrpc\":\"2.0\",\"id\":");
        format_id(out, id);
        if method == "initialize" {
            out.append(",\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"spread-wings\",\"version\":\"");
            out.append(VERSION);
            out.append("\"}}}");
        } else if method == "ping" {
            out.append(",\"result\":{}}");
        } else if method == "tools/list" {
            out.append(",\"result\":{\"tools\":");
            for c in TOOLS { if c != '\n' { out.push(c); } }   // one JSON-RPC message per line
            out.append("}}");
        } else if method == "tools/call" {
            var name: u8[>..] = [];
            name.append(arg_text(params, "name"));
            let targs = json::member(params, "arguments");
            var payload: u8[>..] = [];
            var ok = true;
            if name == "overview" { overview(db, payload); }
            else if name == "find" {
                let n = arg_text(targs, "name");
                if n.len == 0 { payload.append("name is required"); ok = false; } else { find_defs(db, n, payload); }
            } else if name == "neighbors" {
                let p = arg_text(targs, "path");
                if p.len == 0 { payload.append("path is required"); ok = false; } else { ok = neighbors(db, p, payload); }
            } else if name == "callers" {
                let n = arg_text(targs, "name");
                if n.len == 0 { payload.append("name is required"); ok = false; } else { callers(db, n, payload); }
            } else if name == "touches" {
                let n = arg_text(targs, "name");
                if n.len == 0 { payload.append("name is required"); ok = false; } else { ok = touches(db, n, arg_text(targs, "path"), payload); }
            } else { payload.append("unknown tool: "); payload.append(name); ok = false; }
            out.append(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
            json::format_string(out, payload);
            out.append("}],\"isError\":");
            out.append(if ok { "false" } else { "true" });
            out.append("}}");
        } else {
            out.append(",\"error\":{\"code\":-32601,\"message\":\"method not found\"}}");
        }
        out.push('\n');
        write_stdout(out);
        flush_stdout();
    }
    sqlite::close(db);
}

fn main() {
    let a = args();
    if a.len < 3 { usage(); }
    let cmd = a[1];
    if cmd == "index" && (a.len == 4 || (a.len == 6 && a[4] == "--resolution")) {
        var gamma = 1.5;   // measured: on a test-heavy repo, 1.5 splits code into its modules
        if a.len == 6 {
            let g, ok = parse_decimal(a[5]);
            guard ok && g > 0.0 && g <= 10.0 else { abort("spread-wings: --resolution needs a number between 0 and 10"); }
            gamma = g;
        }
        index_main(a[2], a[3], gamma);
        return;
    }
    if cmd == "serve" && a.len == 3 { serve_main(a[2]); return; }
    if cmd == "compiler" && a.len == 4 {
        compiler_main(a[2], a[3]);
        return;
    }
    if cmd == "decide-apply" && a.len == 3 {
        decide_apply_main(a[2]);
        return;
    }
    if cmd == "survey" && a.len == 3 {
        survey_main(a[2]);
        return;
    }
    if cmd == "score" && a.len == 4 {
        score_main(a[2], a[3]);
        return;
    }
    if cmd == "decide" {
        var maxq: i64 = 5000;
        var workers: i64 = 32;
        var k = 3;
        while k + 1 < a.len {
            let v, ok = parse_int(a[k + 1]);
            guard ok && v > 0 else { usage(); }
            if a[k] == "--max" { maxq = v; } else if a[k] == "--workers" { workers = min(v, 128); } else { usage(); }
            k = k + 2;
        }
        guard k == a.len else { usage(); }
        decide_main(a[2], maxq, workers);
        return;
    }
    let db = open_map(a[2]);
    var out: u8[>..] = [];
    var ok = true;
    if cmd == "overview" && a.len == 3 { overview(db, out); }
    else if cmd == "find" && a.len == 4 { find_defs(db, a[3], out); }
    else if cmd == "neighbors" && a.len == 4 { ok = neighbors(db, a[3], out); }
    else if cmd == "callers" && a.len == 4 { callers(db, a[3], out); }
    else if cmd == "touches" && (a.len == 4 || a.len == 5) { ok = touches(db, a[3], if a.len == 5 { a[4] } else { "" }, out); }
    else { usage(); }
    sqlite::close(db);
    out.push('\n');
    if ok { write_stdout(out); } else { write_stderr(out); exit(1); }
}
