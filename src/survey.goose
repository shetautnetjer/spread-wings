// The survey: which projects a repo holds, where, and what each expects.
//
// A repo is rarely one project at its top. It is a workspace of packages, a
// Python service beside a web client, a Rust crate with a fuzz crate inside
// it; each with its own manifest, package manager and wanted versions. A
// tool that assumes one project at the top gets the others wrong or misses
// them (Swan, 2026-11-17/18: a nested cargo crate had no rows, a package
// with its own tsconfig lost its imports, Go below the top was run from the
// top).
//
// `spread-wings survey <repo>` reads the files that say these things and
// reports them, one entry per project:
//   node    package.json: name, package manager (the `packageManager` field,
//           else the lock file here or above), wanted Node/bun (.nvmrc,
//           .node-version, volta, mise.toml, .tool-versions; `engines` as
//           the range it is, under node.requires),
//           workspace root and membership, whether node_modules is there,
//           the test script, the TypeScript version and tsconfig files
//   python  pyproject.toml, setup.py, setup.cfg or requirements.txt: name,
//           manager (uv, poetry, pdm, pipenv, pip), wanted Python
//           (.python-version, requires-python), the virtualenv and its Python
//   rust    Cargo.toml: package, workspace, wanted toolchain
//           (rust-toolchain[.toml], rust-version)
//   go      go.mod: module, Go version, go.work above it
//   java    pom.xml or a Gradle build; deno: deno.json
// A version or manager set in a folder holds for the folders below it until
// one of them says otherwise; each value names the file it came from.
//
// It only reads. No package manager, interpreter or build file of the repo
// is run, so it needs no trust and takes milliseconds. It does not check
// that a wanted version is installed on this machine, and it does not read
// .gitignore: folders the walk always skips (node_modules, target, dist,
// build, hidden ones) are the only ones left out.

import std;
import os;
import json;

// ---- facts: "key \t value \t from \n"; a later line overrides an earlier.

fn field(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in trim(s) {
        if out.len >= 200 { break; }
        out.push(if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c });
    }
    return out;
}

fn fact_add(facts: u8[>..]&, key: const u8[:], value: const u8[:], from: const u8[:]) {
    let v = field(value);
    guard v.len > 0 else { return; }
    format(facts, key, "\t", v, "\t", from, "\n");
}

fn fact_get(facts: const u8[:], key: const u8[:], value: u8[>..]&, from: u8[>..]&) -> bool {
    var found = false;
    each_split(facts, '\n') { line =>
        let t1 = find(line, "\t");
        if t1 > 0 && line[..t1] == key {
            let rest = line[t1 + 1..];
            let t2 = find(rest, "\t");
            if t2 >= 0 {
                value.clear();
                value.append(rest[..t2]);
                from.clear();
                from.append(rest[t2 + 1..]);
                found = true;
            }
        }
    };
    return found;
}

// ---- reading TOML and friends, as far as these files need.

fn bracket_delta(s: const u8[:]) -> i64 {
    var d = 0;
    for c in s {
        if c == '[' || c == '{' { d++; }
        else if c == ']' || c == '}' { d--; }
    }
    return d;
}

// Each `key = value` of a TOML text with the section it is in. A value that
// opens a list or table and closes it on a later line is given whole.
fn toml_each<F>(text: const u8[:]) {
    var section: u8[>..] = [];
    var pend_key: u8[>..] = [];
    var pend_val: u8[>..] = [];
    var depth = 0;
    each_split(text, '\n') { raw =>
        let line = trim(raw);
        if depth > 0 {
            pend_val.push(' ');
            pend_val.append(line);
            depth = depth + bracket_delta(line);
            if depth <= 0 {
                F(section[..], pend_key[..], pend_val[..]);
                pend_key.clear();
                pend_val.clear();
                depth = 0;
            }
        } else if line.len == 0 || line[0] == '#' {
        } else if line[0] == '[' {
            var s = line;
            let hash = find(s, "#");
            if hash > 0 { s = trim(s[..hash]); }
            while s.len > 0 && s[0] == '[' { s = s[1..]; }
            while s.len > 0 && s[s.len - 1] == ']' { s = s[..s.len - 1]; }
            section.clear();
            section.append(trim(s));
        } else {
            let eq = find(line, "=");
            if eq > 0 {
                let d = bracket_delta(line[eq + 1..]);
                if d > 0 {
                    pend_key.append(trim(line[..eq]));
                    pend_val.append(trim(line[eq + 1..]));
                    depth = d;
                } else {
                    F(section[..], trim(line[..eq]), trim(line[eq + 1..]));
                }
            }
        }
    };
}

// The first string of a value: `"22"`, `["3.12", "3.11"]`, `{ version =
// "22" }`, or a bare `22`.
fn first_string(v: const u8[:]) -> const u8[:] {
    for i in 0..v.len {
        if v[i] == '"' || v[i] == '\'' {
            let close = find(v[i + 1..], v[i..i + 1]);
            return if close >= 0 { v[i + 1..i + 1 + close] } else { v[i + 1..] };
        }
    }
    var s = trim(v);
    let hash = find(s, "#");
    if hash >= 0 { s = trim(s[..hash]); }
    while s.len > 0 && (s[0] == '[' || s[0] == '{') { s = trim(s[1..]); }
    var n = 0;
    while n < s.len && s[n] != ' ' && s[n] != ',' && s[n] != ']' && s[n] != '}' { n++; }
    return s[..n];
}

// Every quoted string of a value, comma-separated: a TOML list of globs.
fn all_strings(v: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var i = 0;
    while i < v.len {
        if v[i] == '"' || v[i] == '\'' {
            let close = find(v[i + 1..], v[i..i + 1]);
            guard close >= 0 else { break; }
            if out.len > 0 { out.push(','); }
            out.append(v[i + 1..i + 1 + close]);
            i = i + close + 2;
        } else { i++; }
    }
    return out;
}

// A key without the quotes TOML allows around it.
fn bare_key(k: const u8[:]) -> const u8[:] {
    var s = trim(k);
    if s.len >= 2 && (s[0] == '"' || s[0] == '\'') { s = s[1..s.len - 1]; }
    return s;
}

// The tool a version manager's name means here ("" for one not reported).
fn tool_of(name: const u8[:]) -> const u8[:] {
    if name == "node" || name == "nodejs" { return "node"; }
    if name == "python" { return "python"; }
    if name == "bun" { return "bun"; }
    if name == "deno" { return "deno"; }
    if name == "rust" { return "rust"; }
    if name == "go" || name == "golang" { return "go"; }
    if name == "java" { return "java"; }
    if name == "pnpm" { return "pnpm"; }
    if name == "yarn" { return "yarn"; }
    if name == "uv" { return "uv"; }
    return "";
}

// Whether a workspace pattern covers a folder: `*` within one folder name,
// `**` any number of them.
recursive fn glob_match(p: const u8[:], s: const u8[:]) -> bool {
    if p.len == 0 { return s.len == 0; }
    if starts_with(p, "**") {
        let rest = if p.len > 2 && p[2] == '/' { p[3..] } else { p[2..] };
        if glob_match(rest, s) { return true; }
        guard s.len > 0 else { return false; }
        let slash = find(s, "/");
        return glob_match(p, if slash >= 0 { s[slash + 1..] } else { s[s.len..] });
    }
    if p[0] == '*' {
        var k = 0;
        while k <= s.len {
            if glob_match(p[1..], s[k..]) { return true; }
            if k == s.len || s[k] == '/' { return false; }
            k++;
        }
        return false;
    }
    if s.len > 0 && p[0] == s[0] { return glob_match(p[1..], s[1..]); }
    return false;
}

// Whether folder `rel` is one a workspace at `root` lists (patterns
// comma-separated, relative to the root; `!x` takes x out).
fn workspace_member(root: const u8[:], patterns: const u8[:], rel: const u8[:]) -> bool {
    let below = rel.len > root.len + 1 && starts_with(rel, root) && rel[root.len] == '/';
    let sub = if root == "." { rel } else if below { rel[root.len + 1..] } else { rel[..0] };
    guard sub.len > 0 && sub != "." else { return false; }
    var yes = false;
    var no = false;
    each_split(patterns, ',') { raw =>
        var p = trim(raw);
        let negated = p.len > 0 && p[0] == '!';
        if negated { p = p[1..]; }
        if starts_with(p, "./") { p = p[2..]; }
        while p.len > 0 && p[p.len - 1] == '/' { p = p[..p.len - 1]; }
        if p.len > 0 && glob_match(p, sub) {
            if negated { no = true; } else { yes = true; }
        }
    };
    return yes && !no;
}

// ---- JSON, written by hand: a comma before every member but the first.

fn jsep(out: u8[>..]&) {
    guard out.len > 0 else { return; }
    let c = out[out.len - 1];
    if c != '{' && c != '[' && c != ',' && c != ':' { out.push(','); }
}

fn jkey(out: u8[>..]&, key: const u8[:]) {
    jsep(out);
    json::format_string(out, key);
    out.push(':');
}

fn jtext(out: u8[>..]&, key: const u8[:], v: const u8[:]) {
    jkey(out, key);
    json::format_string(out, v);
}

fn has_name(names: const u8[:], n: const u8[:]) -> bool {
    var found = false;
    each_split(names, '\n') { x => if x == n { found = true; } };
    return found;
}

// One folder: its own facts go to `own`, the projects it holds to
// `projects` (JSON objects) and to the counts.
fn survey_folder(dir: const u8[:], rel: const u8[:], names: const u8[:], inherited: const u8[:],
                 own: u8[>..]&, projects: u8[>..]&, counts: i64[>..]&) {
    fn has(n: const u8[:]) -> bool { return has_name(names, n); }
    fn from_of(n: const u8[:]) -> u8[>..] {
        var p: u8[>..] = [];
        if rel == "." { p.append(n); } else { format(p, rel, "/", n); }
        return p;
    }
    fn read(n: const u8[:], text: u8[>..]&) -> bool {
        text.clear();
        return read_file(str(dir, "/", n), text) && text.len < 4000000;
    }
    // The first line of a one-line version file, a leading `v` dropped.
    fn version_file(n: const u8[:], tool: const u8[:]) {
        var text: u8[>..] = [];
        guard has(n) && read(n, text) else { return; }
        var line: u8[>..] = [];
        each_split(text, '\n') { l => if line.len == 0 && trim(l).len > 0 && trim(l)[0] != '#' { line.append(trim(l)); } };
        let bare = line.len > 1 && line[0] == 'v' && line[1] >= '0' && line[1] <= '9';
        fact_add(own, tool, if bare { line[1..] } else { line[..] }, from_of(n));
    }

    var text: u8[>..] = [];

    // Package managers, by their lock files (a `packageManager` field, read
    // below, says it outright and comes after).
    if has("package-lock.json") { fact_add(own, "pm.node", "npm", from_of("package-lock.json")); }
    if has("npm-shrinkwrap.json") { fact_add(own, "pm.node", "npm", from_of("npm-shrinkwrap.json")); }
    if has("yarn.lock") { fact_add(own, "pm.node", "yarn", from_of("yarn.lock")); }
    if has("pnpm-lock.yaml") { fact_add(own, "pm.node", "pnpm", from_of("pnpm-lock.yaml")); }
    if has("bun.lockb") { fact_add(own, "pm.node", "bun", from_of("bun.lockb")); }
    if has("bun.lock") { fact_add(own, "pm.node", "bun", from_of("bun.lock")); }
    if has("requirements.txt") { fact_add(own, "pm.python", "pip", from_of("requirements.txt")); }
    if has("Pipfile") { fact_add(own, "pm.python", "pipenv", from_of("Pipfile")); }
    if has("pdm.lock") { fact_add(own, "pm.python", "pdm", from_of("pdm.lock")); }
    if has("poetry.lock") { fact_add(own, "pm.python", "poetry", from_of("poetry.lock")); }
    if has("uv.lock") { fact_add(own, "pm.python", "uv", from_of("uv.lock")); }

    // Wanted versions: version managers first, the one-line files after
    // (nearer to the tool, so they win in the same folder).
    if has(".tool-versions") && read(".tool-versions", text) {
        each_split(text, '\n') { l =>
            let t = trim(l);
            let sp = find(t, " ");
            if sp > 0 && t[0] != '#' {
                let tool = tool_of(t[..sp]);
                if tool.len > 0 { fact_add(own, tool, first_string(t[sp + 1..]), from_of(".tool-versions")); }
            }
        };
    }
    fn mise_file(m: const u8[:]) {
        var mt: u8[>..] = [];
        guard has(m) && read(m, mt) else { return; }
        toml_each(mt) { section, key, value =>
            if section == "tools" {
                let tool = tool_of(bare_key(key));
                if tool.len > 0 { fact_add(own, tool, first_string(value), from_of(m)); }
            }
        };
    }
    mise_file("mise.toml");
    mise_file(".mise.toml");
    version_file(".nvmrc", "node");
    version_file(".node-version", "node");
    version_file(".python-version", "python");
    version_file(".bun-version", "bun");
    version_file(".java-version", "java");
    version_file(".go-version", "go");
    if has("rust-toolchain.toml") && read("rust-toolchain.toml", text) {
        toml_each(text) { section, key, value =>
            if section == "toolchain" && key == "channel" { fact_add(own, "rust", first_string(value), from_of("rust-toolchain.toml")); }
        };
    }
    if has("rust-toolchain") && read("rust-toolchain", text) {
        if find(text, "[toolchain]") >= 0 {
            toml_each(text) { section, key, value =>
                if section == "toolchain" && key == "channel" { fact_add(own, "rust", first_string(value), from_of("rust-toolchain")); }
            };
        } else { version_file("rust-toolchain", "rust"); }
    }

    // What is installed here.
    if has("node_modules") && is_dir(str(dir, "/node_modules")) { fact_add(own, "nm", rel, from_of("node_modules")); }
    for v in [".venv", "venv"] {
        var cfg: u8[>..] = [];
        if read_file(str(dir, "/", v, "/pyvenv.cfg"), cfg) {
            fact_add(own, "venv", from_of(v), from_of(v));
            each_split(cfg, '\n') { l =>
                let eq = find(l, "=");
                if eq > 0 && (trim(l[..eq]) == "version" || trim(l[..eq]) == "version_info") { fact_add(own, "venv.python", l[eq + 1..], str(from_of(v), "/pyvenv.cfg")); }
            };
        }
    }

    // ---- node
    var n_has = false;
    var n_name: u8[>..] = [];
    var n_test: u8[>..] = [];
    var n_ts: u8[>..] = [];
    var n_private = false;
    if has("package.json") && read("package.json", text) {
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let root, err = json::parse(text, doc, dec);
        if root {
            n_has = true;
            let nm, nm_ok = json::as_string(json::member(root, "name"));
            if nm_ok { n_name.append(nm); }
            let pv, pv_ok = json::as_bool(json::member(root, "private"));
            n_private = pv_ok && pv;
            let pm, pm_ok = json::as_string(json::member(root, "packageManager"));
            if pm_ok && pm.len > 0 {
                let at = find(pm, "@");
                let who = if at > 0 { pm[..at] } else { pm };
                fact_add(own, "pm.node", who, from_of("package.json packageManager"));
                if at > 0 {
                    var ver = pm[at + 1..];
                    let plus = find(ver, "+");
                    if plus > 0 { ver = ver[..plus]; }
                    fact_add(own, who, ver, from_of("package.json packageManager"));
                }
            }
            let eng = json::member(root, "engines");
            if eng {
                // A range ("node >=22"), kept beside a pinned version, not in its place.
                for t in ["node", "bun", "pnpm", "yarn"] {
                    let v, v_ok = json::as_string(json::member(eng, t));
                    if v_ok { fact_add(own, str(t, ".requires"), v, from_of("package.json engines")); }
                }
            }
            let volta = json::member(root, "volta");
            if volta {
                let v, v_ok = json::as_string(json::member(volta, "node"));
                if v_ok { fact_add(own, "node", v, from_of("package.json volta")); }
            }
            let scripts = json::member(root, "scripts");
            if scripts {
                let t, t_ok = json::as_string(json::member(scripts, "test"));
                if t_ok { n_test.append(field(t)); }
            }
            for part in ["devDependencies", "dependencies", "peerDependencies"] {
                let deps = json::member(root, part);
                if deps && n_ts.len == 0 {
                    let v, v_ok = json::as_string(json::member(deps, "typescript"));
                    if v_ok { n_ts.append(field(v)); }
                }
            }
            // A workspace: `"workspaces": ["packages/*"]` or `{"packages": [...]}`.
            var globs: u8[>..] = [];
            fn glob_list(list: json::Node?) {
                guard list else { return; }
                json::each(list) { g =>
                    let s, s_ok = json::as_string(g);
                    if s_ok && s.len > 0 { if globs.len > 0 { globs.push(','); } globs.append(s); }
                };
            }
            let ws = json::member(root, "workspaces");
            if ws {
                let inner = json::member(ws, "packages");
                if inner { glob_list(inner); } else { glob_list(ws); }
            }
            if globs.len > 0 {
                fact_add(own, "ws.node", rel, from_of("package.json workspaces"));
                fact_add(own, "wsglobs.node", globs, from_of("package.json workspaces"));
            }
        }
    }
    if has("pnpm-workspace.yaml") && read("pnpm-workspace.yaml", text) {
        // packages:\n  - 'packages/*'
        var globs: u8[>..] = [];
        var inside = false;
        each_split(text, '\n') { l =>
            let t = trim(l);
            if starts_with(l, "packages:") { inside = true; }
            else if inside && starts_with(t, "- ") {
                if globs.len > 0 { globs.push(','); }
                globs.append(first_string(t[2..]));
            }
            else if inside && t.len > 0 && t[0] != '#' && l[0] != ' ' && l[0] != '\t' { inside = false; }
        };
        fact_add(own, "ws.node", rel, from_of("pnpm-workspace.yaml"));
        fact_add(own, "wsglobs.node", if globs.len > 0 { globs[..] } else { "-" }, from_of("pnpm-workspace.yaml"));
        fact_add(own, "pm.node", "pnpm", from_of("pnpm-workspace.yaml"));
    }

    // ---- python
    var p_manifest: const u8[:] = "";
    var p_name: u8[>..] = [];
    var p_pytest = false;
    if has("pyproject.toml") && read("pyproject.toml", text) {
        p_manifest = "pyproject.toml";
        toml_each(text) { section, key, value =>
            if (section == "project" || section == "tool.poetry") && key == "name" && p_name.len == 0 { p_name.append(first_string(value)); }
            if section == "project" && key == "requires-python" { fact_add(own, "python.requires", first_string(value), from_of("pyproject.toml requires-python")); }
            if section == "tool.poetry.dependencies" && key == "python" { fact_add(own, "python.requires", first_string(value), from_of("pyproject.toml tool.poetry")); }
            if starts_with(section, "tool.pytest") { p_pytest = true; }
            if section == "tool.uv.workspace" && key == "members" {
                fact_add(own, "ws.python", rel, from_of("pyproject.toml tool.uv.workspace"));
                fact_add(own, "wsglobs.python", all_strings(value), from_of("pyproject.toml tool.uv.workspace"));
            }
            if section == "tool.poetry" && key == "name" { fact_add(own, "pm.python", "poetry", from_of("pyproject.toml tool.poetry")); }
            if starts_with(section, "tool.pdm") { fact_add(own, "pm.python", "pdm", from_of("pyproject.toml tool.pdm")); }
        };
        // A lock file says more than a table in pyproject: it is what was used.
        if has("poetry.lock") { fact_add(own, "pm.python", "poetry", from_of("poetry.lock")); }
        if has("pdm.lock") { fact_add(own, "pm.python", "pdm", from_of("pdm.lock")); }
        if has("uv.lock") { fact_add(own, "pm.python", "uv", from_of("uv.lock")); }
    }
    else if has("setup.py") { p_manifest = "setup.py"; }
    else if has("setup.cfg") { p_manifest = "setup.cfg"; }
    else if has("requirements.txt") { p_manifest = "requirements.txt"; }
    if has("pytest.ini") || has("conftest.py") { p_pytest = true; }

    // ---- rust
    var r_has = false;
    var r_name: u8[>..] = [];
    var r_ws = false;
    if has("Cargo.toml") && read("Cargo.toml", text) {
        r_has = true;
        var members: u8[>..] = [];
        var excluded: u8[>..] = [];
        toml_each(text) { section, key, value =>
            if section == "package" && key == "name" { r_name.append(first_string(value)); }
            if section == "package" && key == "rust-version" { fact_add(own, "rust.requires", str(">=", first_string(value)), from_of("Cargo.toml rust-version")); }
            if section == "workspace" { r_ws = true; }
            if section == "workspace" && key == "members" { members.append(all_strings(value)); }
            if section == "workspace" && key == "exclude" { excluded.append(all_strings(value)); }
        };
        if !r_ws && find(text, "[workspace]") >= 0 { r_ws = true; }
        if r_ws {
            each_split(excluded, ',') { x => if x.len > 0 { if members.len > 0 { members.push(','); } format(members, "!", x); } };
            fact_add(own, "ws.rust", rel, from_of("Cargo.toml workspace"));
            fact_add(own, "wsglobs.rust", if members.len > 0 { members[..] } else { "-" }, from_of("Cargo.toml workspace"));
        }
    }

    // ---- go
    var g_has = false;
    var g_module: u8[>..] = [];
    if has("go.work") && read("go.work", text) {
        // `use ./a` or `use (` ... `)`.
        var dirs: u8[>..] = [];
        var in_use = false;
        each_split(text, '\n') { l =>
            let t = trim(l);
            if t == "use (" { in_use = true; }
            else if in_use && t == ")" { in_use = false; }
            else if in_use && t.len > 0 && !starts_with(t, "//") { if dirs.len > 0 { dirs.push(','); } dirs.append(first_string(t)); }
            else if starts_with(t, "use ") { if dirs.len > 0 { dirs.push(','); } dirs.append(first_string(t[4..])); }
            else if starts_with(t, "go ") { fact_add(own, "go", t[3..], from_of("go.work")); }
        };
        fact_add(own, "ws.go", rel, from_of("go.work"));
        fact_add(own, "wsglobs.go", if dirs.len > 0 { dirs[..] } else { "-" }, from_of("go.work"));
    }
    if has("go.mod") && read("go.mod", text) {
        g_has = true;
        each_split(text, '\n') { l =>
            let t = trim(l);
            if starts_with(t, "module ") && g_module.len == 0 { g_module.append(first_string(t[7..])); }
            else if starts_with(t, "go ") { fact_add(own, "go", t[3..], from_of("go.mod")); }
            else if starts_with(t, "toolchain ") {
                let v = trim(t[10..]);
                fact_add(own, "go.toolchain", if starts_with(v, "go") { v[2..] } else { v }, from_of("go.mod toolchain"));
            }
        };
    }

    // ---- java, deno
    var j_tool: const u8[:] = "";
    var j_manifest: const u8[:] = "";
    if has("pom.xml") { j_tool = "maven"; j_manifest = "pom.xml"; }
    else if has("build.gradle.kts") { j_tool = "gradle"; j_manifest = "build.gradle.kts"; }
    else if has("build.gradle") { j_tool = "gradle"; j_manifest = "build.gradle"; }
    else if has("settings.gradle.kts") { j_tool = "gradle"; j_manifest = "settings.gradle.kts"; }
    else if has("settings.gradle") { j_tool = "gradle"; j_manifest = "settings.gradle"; }
    var d_manifest: const u8[:] = "";
    if has("deno.json") { d_manifest = "deno.json"; }
    else if has("deno.jsonc") { d_manifest = "deno.jsonc"; }

    guard n_has || p_manifest.len > 0 || r_has || g_has || j_tool.len > 0 || d_manifest.len > 0 else { return; }

    // What holds here: the folders above, then this one.
    var all: u8[>..] = [];
    all.append(inherited);
    all.append(own);
    var val: u8[>..] = [];
    var src: u8[>..] = [];

    fn begin(kind: const u8[:], name: const u8[:], manifest: const u8[:]) {
        if projects.len > 0 { projects.push(','); }
        projects.append("\n    {");
        jtext(projects, "path", rel);
        jtext(projects, "kind", kind);
        if name.len > 0 { jtext(projects, "name", name); }
        jtext(projects, "manifest", manifest);
    }
    fn manager(key: const u8[:]) {
        if fact_get(all, key, val, src) {
            jkey(projects, "package_manager");
            projects.push('{');
            jtext(projects, "name", val);
            jtext(projects, "from", src);
            projects.push('}');
        }
    }
    fn wants(tools: const u8[:][:]) {
        jkey(projects, "wants");
        projects.push('{');
        for t in tools {
            if fact_get(all, t, val, src) {
                // "x.requires" is a range the manifest states (engines,
                // requires-python, rust-version), beside a pinned version of x.
                jkey(projects, t);
                projects.push('{');
                jtext(projects, "version", val);
                jtext(projects, "from", src);
                projects.push('}');
            }
        }
        projects.push('}');
    }
    // The nearest workspace of this kind: this folder, or one above that
    // may or may not list it.
    fn workspace(kind: const u8[:]) {
        guard fact_get(all, str("ws.", kind), val, src) else { return; }
        var root: u8[>..] = [];
        root.append(val);
        var file: u8[>..] = [];
        file.append(src);
        var globs: u8[>..] = [];
        var gsrc: u8[>..] = [];
        fact_get(all, str("wsglobs.", kind), globs, gsrc);
        jkey(projects, "workspace");
        projects.push('{');
        jtext(projects, "root", root);
        jtext(projects, "from", file);
        jkey(projects, "is_root");
        json::format_bool(projects, root == rel);
        if root != rel {
            jkey(projects, "member");
            json::format_bool(projects, workspace_member(root, globs, rel));
        }
        projects.push('}');
    }

    if n_has {
        begin("node", n_name, "package.json");
        manager("pm.node");
        wants(["node", "node.requires", "bun", "bun.requires", "pnpm", "yarn"]);
        workspace("node");
        jkey(projects, "dependencies_installed");
        if fact_get(all, "nm", val, src) {
            projects.push('{');
            jkey(projects, "installed");
            projects.append("true");
            jtext(projects, "at", src);
            projects.push('}');
        } else { projects.append("{\"installed\":false}"); }
        if n_test.len > 0 { jtext(projects, "test_script", n_test); }
        if n_ts.len > 0 { jtext(projects, "typescript", n_ts); }
        var configs: u8[>..] = [];
        each_split(names, '\n') { x =>
            if starts_with(x, "tsconfig") && ends_with(x, ".json") { if configs.len > 0 { configs.push(','); } json::format_string(configs, x); }
        };
        if configs.len > 0 { jkey(projects, "tsconfigs"); format(projects, "[", configs, "]"); }
        projects.push('}');
        counts[0] = counts[0] + 1;
    }
    if p_manifest.len > 0 {
        begin("python", p_name, p_manifest);
        manager("pm.python");
        wants(["python", "python.requires", "uv"]);
        workspace("python");
        jkey(projects, "environment");
        if fact_get(all, "venv", val, src) {
            projects.push('{');
            jtext(projects, "venv", val);
            var pv: u8[>..] = [];
            var ps: u8[>..] = [];
            if fact_get(all, "venv.python", pv, ps) { jtext(projects, "python", pv); }
            projects.push('}');
        } else { projects.append("null"); }
        if p_pytest { jtext(projects, "tests", "pytest"); }
        projects.push('}');
        counts[1] = counts[1] + 1;
    }
    if r_has {
        begin("rust", r_name, "Cargo.toml");
        wants(["rust", "rust.requires"]);
        workspace("rust");
        jkey(projects, "lock_file");
        json::format_bool(projects, has("Cargo.lock"));
        projects.push('}');
        counts[2] = counts[2] + 1;
    }
    if g_has {
        begin("go", g_module, "go.mod");
        wants(["go", "go.toolchain"]);
        workspace("go");
        projects.push('}');
        counts[3] = counts[3] + 1;
    }
    if j_tool.len > 0 {
        begin("java", "", j_manifest);
        jtext(projects, "build_tool", j_tool);
        wants(["java"]);
        projects.push('}');
        counts[4] = counts[4] + 1;
    }
    if d_manifest.len > 0 {
        begin("deno", "", d_manifest);
        wants(["deno"]);
        projects.push('}');
        counts[5] = counts[5] + 1;
    }
}

// The files that make a folder worth reading. Anything else: its facts are
// its parent's.
let SURVEY_FILES = ["package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
                    "pnpm-workspace.yaml", "bun.lock", "bun.lockb", "node_modules", ".nvmrc", ".node-version",
                    ".bun-version", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile",
                    "pdm.lock", "poetry.lock", "uv.lock", ".python-version", ".venv", "venv", "pytest.ini",
                    "conftest.py", "Cargo.toml", "rust-toolchain", "rust-toolchain.toml", "go.mod", "go.work",
                    ".go-version", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
                    "settings.gradle.kts", ".java-version", "deno.json", "deno.jsonc", "mise.toml", ".mise.toml",
                    ".tool-versions"];

fn survey_main(repo_arg: const u8[:]) {
    let repo = abs_dir(repo_arg);
    guard is_dir(repo) else { abort(str("spread-wings: not a directory: ", repo)); }
    // Folders in the order met, a parent before its children.
    var dirs: u8[>..] = [];
    var d_at: i64[>..] = [];
    var d_len: i64[>..] = [];
    var f_at: i64[>..] = [];         // each folder's facts: a span of `facts`
    var f_len: i64[>..] = [];
    var facts: u8[>..] = [];
    var projects: u8[>..] = [];
    var counts: i64[>..] = [];
    counts.resize(6, 0);
    d_at.push(0);
    d_len.push(repo.len);
    dirs.append(repo);
    f_at.push(0);
    f_len.push(0);
    // Depth first, a folder's children in name order, so the projects come
    // out in path order; a parent is always read before its children.
    var todo: i64[>..] = [];
    todo.push(0);
    var read_count = 0;
    while todo.len > 0 && read_count < 200000 {
        let at = todo[todo.len - 1];
        todo.pop();
        read_count++;
        var dir: u8[>..] = [];
        dir.append(dirs[d_at[at]..d_at[at] + d_len[at]]);
        var names: u8[>..] = [];
        guard list_dir(dir, names) else { continue; }
        var worth = false;
        each_split(names, '\n') { x => if !worth && contains(SURVEY_FILES, x) { worth = true; } };
        if worth {
            var inherited: u8[>..] = [];
            inherited.append(facts[f_at[at]..f_at[at] + f_len[at]]);
            var own: u8[>..] = [];
            let rel = if dir.len > repo.len { dir[repo.len + 1..] } else { "." };
            survey_folder(dir, rel, names, inherited, own, projects, counts);
            if own.len > 0 {
                f_at[at] = facts.len;
                facts.append(inherited);
                facts.append(own);
                f_len[at] = facts.len - f_at[at];
            }
        }
        let first_child = d_at.len;
        each_split(names, '\n') { name =>
            if name.len > 0 && name[0] != '.' && !contains(SKIP_DIRS, name) {
                var full: u8[>..] = [];
                format(full, dir, "/", name);
                if is_dir(full) && !sw_is_symlink(full) {
                    d_at.push(dirs.len);
                    d_len.push(full.len);
                    f_at.push(f_at[at]);
                    f_len.push(f_len[at]);
                    dirs.append(full);
                }
            }
        };
        var k = d_at.len;
        while k > first_child { k--; todo.push(k); }
    }
    let next = read_count;
    var out: u8[>..] = [];
    out.append("{\n  \"root\": ");
    json::format_string(out, repo);
    format(out, ",\n  \"folders_read\": ", next, ",\n  \"projects\": [", projects, if projects.len > 0 { "\n  ]" } else { "]" });
    format(out, ",\n  \"count\": {\"node\": ", counts[0], ", \"python\": ", counts[1], ", \"rust\": ", counts[2],
           ", \"go\": ", counts[3], ", \"java\": ", counts[4], ", \"deno\": ", counts[5], "}");
    out.append(",\n  \"evidence\": \"read from manifest, lock and version files; nothing of the repo was run, and whether a wanted version is installed on this machine was not checked\"\n}");
    print(out);
}
