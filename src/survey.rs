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

use crate::extract::SKIP_DIRS;
use crate::query::jtext as jstring;
use crate::run::abs_dir;
use crate::sys;
use crate::util::*;
use serde_json::Value;

// ---- facts: "key \t value \t from \n"; a later line overrides an earlier.

fn field(v: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    for &c in trim(v) {
        if out.len() >= 200 { break; }
        out.push(if c == b'\t' || c == b'\n' || c == b'\r' { b' ' } else { c });
    }
    out
}

fn fact_add(facts: &mut Vec<u8>, key: &[u8], value: &[u8], from: &[u8]) {
    let v = field(value);
    if v.is_empty() { return; }
    for p in [key, b"\t", &v, b"\t", from, b"\n"] { facts.extend_from_slice(p); }
}

fn fact_get(facts: &[u8], key: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let mut found = None;
    for line in facts.split(|&c| c == b'\n') {
        let t1 = find(line, b"\t");
        if t1 > 0 && &line[..t1 as usize] == key {
            let rest = &line[t1 as usize + 1..];
            let t2 = find(rest, b"\t");
            if t2 >= 0 { found = Some((rest[..t2 as usize].to_vec(), rest[t2 as usize + 1..].to_vec())); }
        }
    }
    found
}

// ---- reading TOML and friends, as far as these files need.

fn bracket_delta(v: &[u8]) -> i64 {
    let mut d = 0;
    for &c in v {
        if c == b'[' || c == b'{' { d += 1; }
        else if c == b']' || c == b'}' { d -= 1; }
    }
    d
}

/// Each `key = value` of a TOML text with the section it is in. A value that
/// opens a list or table and closes it on a later line is given whole.
fn toml_each(text: &[u8], mut f: impl FnMut(&[u8], &[u8], &[u8])) {
    let mut section: Vec<u8> = Vec::new();
    let mut pend_key: Vec<u8> = Vec::new();
    let mut pend_val: Vec<u8> = Vec::new();
    let mut depth = 0;
    for raw in text.split(|&c| c == b'\n') {
        let line = trim(raw);
        if depth > 0 {
            pend_val.push(b' ');
            pend_val.extend_from_slice(line);
            depth += bracket_delta(line);
            if depth <= 0 {
                f(&section, &pend_key, &pend_val);
                pend_key.clear();
                pend_val.clear();
                depth = 0;
            }
        } else if line.is_empty() || line[0] == b'#' {
        } else if line[0] == b'[' {
            let mut sc = line;
            let hash = find(sc, b"#");
            if hash > 0 { sc = trim(&sc[..hash as usize]); }
            while !sc.is_empty() && sc[0] == b'[' { sc = &sc[1..]; }
            while !sc.is_empty() && sc[sc.len() - 1] == b']' { sc = &sc[..sc.len() - 1]; }
            section.clear();
            section.extend_from_slice(trim(sc));
        } else {
            let eq = find(line, b"=");
            if eq > 0 {
                let eq = eq as usize;
                let d = bracket_delta(&line[eq + 1..]);
                if d > 0 {
                    pend_key.extend_from_slice(trim(&line[..eq]));
                    pend_val.extend_from_slice(trim(&line[eq + 1..]));
                    depth = d;
                } else {
                    f(&section, trim(&line[..eq]), trim(&line[eq + 1..]));
                }
            }
        }
    }
}

/// The first string of a value: `"22"`, `["3.12", "3.11"]`, `{ version =
/// "22" }`, or a bare `22`.
fn first_string(v: &[u8]) -> &[u8] {
    for i in 0..v.len() {
        if v[i] == b'"' || v[i] == b'\'' {
            let close = find(&v[i + 1..], &v[i..i + 1]);
            return if close >= 0 { &v[i + 1..i + 1 + close as usize] } else { &v[i + 1..] };
        }
    }
    let mut t = trim(v);
    let hash = find(t, b"#");
    if hash >= 0 { t = trim(&t[..hash as usize]); }
    while !t.is_empty() && (t[0] == b'[' || t[0] == b'{') { t = trim(&t[1..]); }
    let mut n = 0;
    while n < t.len() && t[n] != b' ' && t[n] != b',' && t[n] != b']' && t[n] != b'}' { n += 1; }
    &t[..n]
}

/// Every quoted string of a value, comma-separated: a TOML list of globs.
fn all_strings(v: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut i = 0;
    while i < v.len() {
        if v[i] == b'"' || v[i] == b'\'' {
            let close = find(&v[i + 1..], &v[i..i + 1]);
            if close < 0 { break; }
            if !out.is_empty() { out.push(b','); }
            out.extend_from_slice(&v[i + 1..i + 1 + close as usize]);
            i = i + close as usize + 2;
        } else { i += 1; }
    }
    out
}

/// A key without the quotes TOML allows around it.
fn bare_key(k: &[u8]) -> &[u8] {
    let mut t = trim(k);
    if t.len() >= 2 && (t[0] == b'"' || t[0] == b'\'') { t = &t[1..t.len() - 1]; }
    t
}

/// The tool a version manager's name means here ("" for one not reported).
fn tool_of(name: &[u8]) -> &'static [u8] {
    match name {
        b"node" | b"nodejs" => b"node",
        b"python" => b"python",
        b"bun" => b"bun",
        b"deno" => b"deno",
        b"rust" => b"rust",
        b"go" | b"golang" => b"go",
        b"java" => b"java",
        b"pnpm" => b"pnpm",
        b"yarn" => b"yarn",
        b"uv" => b"uv",
        _ => b"",
    }
}

/// Whether a workspace pattern covers a folder: `*` within one folder name,
/// `**` any number of them.
fn glob_match(p: &[u8], t: &[u8]) -> bool {
    if p.is_empty() { return t.is_empty(); }
    if starts_with(p, b"**") {
        let rest = if p.len() > 2 && p[2] == b'/' { &p[3..] } else { &p[2..] };
        if glob_match(rest, t) { return true; }
        if t.is_empty() { return false; }
        let slash = find(t, b"/");
        return glob_match(p, if slash >= 0 { &t[slash as usize + 1..] } else { &t[t.len()..] });
    }
    if p[0] == b'*' {
        let mut k = 0;
        while k <= t.len() {
            if glob_match(&p[1..], &t[k..]) { return true; }
            if k == t.len() || t[k] == b'/' { return false; }
            k += 1;
        }
        return false;
    }
    if !t.is_empty() && p[0] == t[0] { return glob_match(&p[1..], &t[1..]); }
    false
}

/// Whether folder `rel` is one a workspace at `root` lists (patterns
/// comma-separated, relative to the root; `!x` takes x out).
fn workspace_member(root: &[u8], patterns: &[u8], rel: &[u8]) -> bool {
    let below = rel.len() > root.len() + 1 && starts_with(rel, root) && rel[root.len()] == b'/';
    let sub = if root == b"." { rel } else if below { &rel[root.len() + 1..] } else { &rel[..0] };
    if !(!sub.is_empty() && sub != b".") { return false; }
    let mut yes = false;
    let mut no = false;
    for raw in patterns.split(|&c| c == b',') {
        let mut p = trim(raw);
        let negated = !p.is_empty() && p[0] == b'!';
        if negated { p = &p[1..]; }
        if starts_with(p, b"./") { p = &p[2..]; }
        while !p.is_empty() && p[p.len() - 1] == b'/' { p = &p[..p.len() - 1]; }
        if !p.is_empty() && glob_match(p, sub) {
            if negated { no = true; } else { yes = true; }
        }
    }
    yes && !no
}

// ---- JSON, written by hand: a comma before every member but the first.

fn jsep(out: &mut Vec<u8>) {
    if out.is_empty() { return; }
    let c = out[out.len() - 1];
    if c != b'{' && c != b'[' && c != b',' && c != b':' { out.push(b','); }
}

fn jkey(out: &mut Vec<u8>, key: &[u8]) {
    jsep(out);
    jstring(out, key);
    out.push(b':');
}

fn jtext(out: &mut Vec<u8>, key: &[u8], v: &[u8]) {
    jkey(out, key);
    jstring(out, v);
}

fn jbool(out: &mut Vec<u8>, b: bool) { out.extend_from_slice(if b { b"true" } else { b"false" }); }

fn jget<'a>(v: Option<&'a Value>, key: &str) -> Option<&'a Value> { v.and_then(|x| x.as_object()).and_then(|o| o.get(key)) }
fn jstr_of<'a>(v: Option<&'a Value>) -> Option<&'a str> { v.and_then(|x| x.as_str()) }

/// What one folder says, and the pieces of it the answer is written from.
struct Folder<'a> {
    dir: &'a [u8],
    rel: &'a [u8],
    names: &'a [Vec<u8>],
    own: &'a mut Vec<u8>,
}

impl<'a> Folder<'a> {
    fn has(&self, n: &str) -> bool { self.names.iter().any(|x| x == n.as_bytes()) }
    fn from_of(&self, n: &[u8]) -> Vec<u8> {
        let mut p: Vec<u8> = Vec::new();
        if self.rel != b"." { p.extend_from_slice(self.rel); p.push(b'/'); }
        p.extend_from_slice(n);
        p
    }
    fn full(&self, n: &[u8]) -> Vec<u8> {
        let mut p = self.dir.to_vec();
        p.push(b'/');
        p.extend_from_slice(n);
        p
    }
    fn read(&self, n: &str) -> Option<Vec<u8>> {
        sys::read_file(&self.full(n.as_bytes())).filter(|t| t.len() < 4000000)
    }
    fn fact(&mut self, key: &[u8], value: &[u8], from: &str) {
        let f = self.from_of(from.as_bytes());
        fact_add(self.own, key, value, &f);
    }
    /// The first line of a one-line version file, a leading `v` dropped.
    fn version_file(&mut self, n: &str, tool: &[u8]) {
        if !self.has(n) { return; }
        let text = match self.read(n) { Some(t) => t, None => return };
        let mut line: &[u8] = b"";
        for l in text.split(|&c| c == b'\n') {
            let t = trim(l);
            if line.is_empty() && !t.is_empty() && t[0] != b'#' { line = t; }
        }
        let bare = line.len() > 1 && line[0] == b'v' && line[1].is_ascii_digit();
        self.fact(tool, if bare { &line[1..] } else { line }, n);
    }
    fn mise_file(&mut self, m: &str) {
        if !self.has(m) { return; }
        let mt = match self.read(m) { Some(t) => t, None => return };
        let mut got: Vec<(&'static [u8], Vec<u8>)> = Vec::new();
        toml_each(&mt, |section, key, value| {
            if section == b"tools" {
                let tool = tool_of(bare_key(key));
                if !tool.is_empty() { got.push((tool, first_string(value).to_vec())); }
            }
        });
        for (tool, v) in got { self.fact(tool, &v, m); }
    }
    fn toolchain_toml(&mut self, n: &str, text: &[u8]) {
        let mut got: Vec<Vec<u8>> = Vec::new();
        toml_each(text, |section, key, value| {
            if section == b"toolchain" && key == b"channel" { got.push(first_string(value).to_vec()); }
        });
        for v in got { self.fact(b"rust", &v, n); }
    }
}

/// One folder: its own facts go to `own`, the projects it holds to
/// `projects` (JSON objects) and to the counts.
fn survey_folder(dir: &[u8], rel: &[u8], names: &[Vec<u8>], inherited: &[u8], own: &mut Vec<u8>, projects: &mut Vec<u8>, counts: &mut [i64; 6]) {
    let mut f = Folder { dir, rel, names, own };

    // Package managers, by their lock files (a `packageManager` field, read
    // below, says it outright and comes after).
    for (file, key, pm) in [
        ("package-lock.json", "pm.node", "npm"), ("npm-shrinkwrap.json", "pm.node", "npm"), ("yarn.lock", "pm.node", "yarn"),
        ("pnpm-lock.yaml", "pm.node", "pnpm"), ("bun.lockb", "pm.node", "bun"), ("bun.lock", "pm.node", "bun"),
        ("requirements.txt", "pm.python", "pip"), ("Pipfile", "pm.python", "pipenv"), ("pdm.lock", "pm.python", "pdm"),
        ("poetry.lock", "pm.python", "poetry"), ("uv.lock", "pm.python", "uv"),
    ] {
        if f.has(file) { f.fact(key.as_bytes(), pm.as_bytes(), file); }
    }

    // Wanted versions: version managers first, the one-line files after
    // (nearer to the tool, so they win in the same folder).
    if f.has(".tool-versions") {
        if let Some(text) = f.read(".tool-versions") {
            for l in text.split(|&c| c == b'\n') {
                let t = trim(l);
                let sp = find(t, b" ");
                if sp > 0 && t[0] != b'#' {
                    let tool = tool_of(&t[..sp as usize]);
                    if !tool.is_empty() { f.fact(tool, first_string(&t[sp as usize + 1..]), ".tool-versions"); }
                }
            }
        }
    }
    f.mise_file("mise.toml");
    f.mise_file(".mise.toml");
    f.version_file(".nvmrc", b"node");
    f.version_file(".node-version", b"node");
    f.version_file(".python-version", b"python");
    f.version_file(".bun-version", b"bun");
    f.version_file(".java-version", b"java");
    f.version_file(".go-version", b"go");
    if f.has("rust-toolchain.toml") {
        if let Some(text) = f.read("rust-toolchain.toml") { f.toolchain_toml("rust-toolchain.toml", &text); }
    }
    if f.has("rust-toolchain") {
        if let Some(text) = f.read("rust-toolchain") {
            if find(&text, b"[toolchain]") >= 0 { f.toolchain_toml("rust-toolchain", &text); }
            else { f.version_file("rust-toolchain", b"rust"); }
        }
    }

    // What is installed here.
    if f.has("node_modules") && sys::is_dir(&f.full(b"node_modules")) { f.fact(b"nm", rel, "node_modules"); }
    for v in [".venv", "venv"] {
        if let Some(cfg) = sys::read_file(&f.full(format!("{}/pyvenv.cfg", v).as_bytes())) {
            let fv = f.from_of(v.as_bytes());
            f.fact(b"venv", &fv, v);
            for l in cfg.split(|&c| c == b'\n') {
                let eq = find(l, b"=");
                if eq > 0 && (trim(&l[..eq as usize]) == b"version" || trim(&l[..eq as usize]) == b"version_info") {
                    f.fact(b"venv.python", &l[eq as usize + 1..], &format!("{}/pyvenv.cfg", v));
                }
            }
        }
    }

    // ---- node
    let mut n_has = false;
    let mut n_name: Vec<u8> = Vec::new();
    let mut n_test: Vec<u8> = Vec::new();
    let mut n_ts: Vec<u8> = Vec::new();
    if f.has("package.json") {
        if let Some(text) = f.read("package.json") {
            if let Ok(root) = serde_json::from_slice::<Value>(&text) {
                let root = Some(&root);
                n_has = true;
                if let Some(nm) = jstr_of(jget(root, "name")) { n_name.extend_from_slice(nm.as_bytes()); }
                if let Some(pm) = jstr_of(jget(root, "packageManager")) {
                    let pm = pm.as_bytes();
                    if !pm.is_empty() {
                        let at = find(pm, b"@");
                        let who = if at > 0 { &pm[..at as usize] } else { pm };
                        f.fact(b"pm.node", who, "package.json packageManager");
                        if at > 0 {
                            let mut ver = &pm[at as usize + 1..];
                            let plus = find(ver, b"+");
                            if plus > 0 { ver = &ver[..plus as usize]; }
                            f.fact(who, ver, "package.json packageManager");
                        }
                    }
                }
                let eng = jget(root, "engines");
                if eng.is_some() {
                    // A range ("node >=22"), kept beside a pinned version, not in its place.
                    for t in ["node", "bun", "pnpm", "yarn"] {
                        if let Some(v) = jstr_of(jget(eng, t)) { f.fact(format!("{}.requires", t).as_bytes(), v.as_bytes(), "package.json engines"); }
                    }
                }
                if let Some(v) = jstr_of(jget(jget(root, "volta"), "node")) { f.fact(b"node", v.as_bytes(), "package.json volta"); }
                if let Some(t) = jstr_of(jget(jget(root, "scripts"), "test")) { n_test.extend_from_slice(&field(t.as_bytes())); }
                for part in ["devDependencies", "dependencies", "peerDependencies"] {
                    let deps = jget(root, part);
                    if deps.is_some() && n_ts.is_empty() {
                        if let Some(v) = jstr_of(jget(deps, "typescript")) { n_ts.extend_from_slice(&field(v.as_bytes())); }
                    }
                }
                // A workspace: `"workspaces": ["packages/*"]` or `{"packages": [...]}`.
                let mut globs: Vec<u8> = Vec::new();
                let ws = jget(root, "workspaces");
                if let Some(w) = ws {
                    let list = jget(ws, "packages").unwrap_or(w);
                    let each: Vec<&Value> = match list {
                        Value::Array(a) => a.iter().collect(),
                        Value::Object(o) => o.values().collect(),
                        _ => Vec::new(),
                    };
                    for g in each {
                        if let Some(t) = g.as_str() {
                            if !t.is_empty() { if !globs.is_empty() { globs.push(b','); } globs.extend_from_slice(t.as_bytes()); }
                        }
                    }
                }
                if !globs.is_empty() {
                    f.fact(b"ws.node", rel, "package.json workspaces");
                    f.fact(b"wsglobs.node", &globs, "package.json workspaces");
                }
            }
        }
    }
    if f.has("pnpm-workspace.yaml") {
        if let Some(text) = f.read("pnpm-workspace.yaml") {
            // packages:\n  - 'packages/*'
            let mut globs: Vec<u8> = Vec::new();
            let mut inside = false;
            for l in text.split(|&c| c == b'\n') {
                let t = trim(l);
                if starts_with(l, b"packages:") { inside = true; }
                else if inside && starts_with(t, b"- ") {
                    if !globs.is_empty() { globs.push(b','); }
                    globs.extend_from_slice(first_string(&t[2..]));
                }
                else if inside && !t.is_empty() && t[0] != b'#' && l[0] != b' ' && l[0] != b'\t' { inside = false; }
            }
            f.fact(b"ws.node", rel, "pnpm-workspace.yaml");
            f.fact(b"wsglobs.node", if !globs.is_empty() { &globs } else { b"-" }, "pnpm-workspace.yaml");
            f.fact(b"pm.node", b"pnpm", "pnpm-workspace.yaml");
        }
    }

    // ---- python
    let mut p_manifest: &str = "";
    let mut p_name: Vec<u8> = Vec::new();
    let mut p_pytest = false;
    let pyproject = if f.has("pyproject.toml") { f.read("pyproject.toml") } else { None };
    if let Some(text) = pyproject {
        p_manifest = "pyproject.toml";
        let mut facts: Vec<(&'static str, Vec<u8>, &'static str)> = Vec::new();
        toml_each(&text, |section, key, value| {
            if (section == b"project" || section == b"tool.poetry") && key == b"name" && p_name.is_empty() { p_name.extend_from_slice(first_string(value)); }
            if section == b"project" && key == b"requires-python" { facts.push(("python.requires", first_string(value).to_vec(), "pyproject.toml requires-python")); }
            if section == b"tool.poetry.dependencies" && key == b"python" { facts.push(("python.requires", first_string(value).to_vec(), "pyproject.toml tool.poetry")); }
            if starts_with(section, b"tool.pytest") { p_pytest = true; }
            if section == b"tool.uv.workspace" && key == b"members" {
                facts.push(("ws.python", rel.to_vec(), "pyproject.toml tool.uv.workspace"));
                facts.push(("wsglobs.python", all_strings(value), "pyproject.toml tool.uv.workspace"));
            }
            if section == b"tool.poetry" && key == b"name" { facts.push(("pm.python", b"poetry".to_vec(), "pyproject.toml tool.poetry")); }
            if starts_with(section, b"tool.pdm") { facts.push(("pm.python", b"pdm".to_vec(), "pyproject.toml tool.pdm")); }
        });
        for (k, v, from) in facts { f.fact(k.as_bytes(), &v, from); }
        // A lock file says more than a table in pyproject: it is what was used.
        if f.has("poetry.lock") { f.fact(b"pm.python", b"poetry", "poetry.lock"); }
        if f.has("pdm.lock") { f.fact(b"pm.python", b"pdm", "pdm.lock"); }
        if f.has("uv.lock") { f.fact(b"pm.python", b"uv", "uv.lock"); }
    }
    else if f.has("setup.py") { p_manifest = "setup.py"; }
    else if f.has("setup.cfg") { p_manifest = "setup.cfg"; }
    else if f.has("requirements.txt") { p_manifest = "requirements.txt"; }
    if f.has("pytest.ini") || f.has("conftest.py") { p_pytest = true; }

    // ---- rust
    let mut r_has = false;
    let mut r_name: Vec<u8> = Vec::new();
    let mut r_ws = false;
    let cargo = if f.has("Cargo.toml") { f.read("Cargo.toml") } else { None };
    if let Some(text) = cargo {
        r_has = true;
        let mut members: Vec<u8> = Vec::new();
        let mut excluded: Vec<u8> = Vec::new();
        let mut wants: Vec<Vec<u8>> = Vec::new();
        toml_each(&text, |section, key, value| {
            if section == b"package" && key == b"name" { r_name.extend_from_slice(first_string(value)); }
            if section == b"package" && key == b"rust-version" {
                let mut v = b">=".to_vec();
                v.extend_from_slice(first_string(value));
                wants.push(v);
            }
            if section == b"workspace" { r_ws = true; }
            if section == b"workspace" && key == b"members" { members.extend_from_slice(&all_strings(value)); }
            if section == b"workspace" && key == b"exclude" { excluded.extend_from_slice(&all_strings(value)); }
        });
        for v in wants { f.fact(b"rust.requires", &v, "Cargo.toml rust-version"); }
        if !r_ws && find(&text, b"[workspace]") >= 0 { r_ws = true; }
        if r_ws {
            for x in excluded.split(|&c| c == b',') {
                if !x.is_empty() {
                    if !members.is_empty() { members.push(b','); }
                    members.push(b'!');
                    members.extend_from_slice(x);
                }
            }
            f.fact(b"ws.rust", rel, "Cargo.toml workspace");
            f.fact(b"wsglobs.rust", if !members.is_empty() { &members } else { b"-" }, "Cargo.toml workspace");
        }
    }

    // ---- go
    let mut g_has = false;
    let mut g_module: Vec<u8> = Vec::new();
    if f.has("go.work") {
        if let Some(text) = f.read("go.work") {
            // `use ./a` or `use (` ... `)`.
            let mut dirs: Vec<u8> = Vec::new();
            let mut in_use = false;
            for l in text.split(|&c| c == b'\n') {
                let t = trim(l);
                if t == b"use (" { in_use = true; }
                else if in_use && t == b")" { in_use = false; }
                else if in_use && !t.is_empty() && !starts_with(t, b"//") { if !dirs.is_empty() { dirs.push(b','); } dirs.extend_from_slice(first_string(t)); }
                else if starts_with(t, b"use ") { if !dirs.is_empty() { dirs.push(b','); } dirs.extend_from_slice(first_string(&t[4..])); }
                else if starts_with(t, b"go ") { f.fact(b"go", &t[3..], "go.work"); }
            }
            f.fact(b"ws.go", rel, "go.work");
            f.fact(b"wsglobs.go", if !dirs.is_empty() { &dirs } else { b"-" }, "go.work");
        }
    }
    if f.has("go.mod") {
        if let Some(text) = f.read("go.mod") {
            g_has = true;
            for l in text.split(|&c| c == b'\n') {
                let t = trim(l);
                if starts_with(t, b"module ") && g_module.is_empty() { g_module.extend_from_slice(first_string(&t[7..])); }
                else if starts_with(t, b"go ") { f.fact(b"go", &t[3..], "go.mod"); }
                else if starts_with(t, b"toolchain ") {
                    let v = trim(&t[10..]);
                    f.fact(b"go.toolchain", if starts_with(v, b"go") { &v[2..] } else { v }, "go.mod toolchain");
                }
            }
        }
    }

    // ---- java, deno
    let (mut j_tool, mut j_manifest) = ("", "");
    if f.has("pom.xml") { j_tool = "maven"; j_manifest = "pom.xml"; }
    else if f.has("build.gradle.kts") { j_tool = "gradle"; j_manifest = "build.gradle.kts"; }
    else if f.has("build.gradle") { j_tool = "gradle"; j_manifest = "build.gradle"; }
    else if f.has("settings.gradle.kts") { j_tool = "gradle"; j_manifest = "settings.gradle.kts"; }
    else if f.has("settings.gradle") { j_tool = "gradle"; j_manifest = "settings.gradle"; }
    let mut d_manifest = "";
    if f.has("deno.json") { d_manifest = "deno.json"; }
    else if f.has("deno.jsonc") { d_manifest = "deno.jsonc"; }

    if !(n_has || !p_manifest.is_empty() || r_has || g_has || !j_tool.is_empty() || !d_manifest.is_empty()) { return; }
    let has_cargo_lock = f.has("Cargo.lock");

    // What holds here: the folders above, then this one.
    let mut all: Vec<u8> = inherited.to_vec();
    all.extend_from_slice(f.own);
    let all = &all[..];

    let begin = |projects: &mut Vec<u8>, kind: &str, name: &[u8], manifest: &str| {
        if !projects.is_empty() { projects.push(b','); }
        projects.extend_from_slice(b"\n    {");
        jtext(projects, b"path", rel);
        jtext(projects, b"kind", kind.as_bytes());
        if !name.is_empty() { jtext(projects, b"name", name); }
        jtext(projects, b"manifest", manifest.as_bytes());
    };
    let manager = |projects: &mut Vec<u8>, key: &str| {
        if let Some((val, src)) = fact_get(all, key.as_bytes()) {
            jkey(projects, b"package_manager");
            projects.push(b'{');
            jtext(projects, b"name", &val);
            jtext(projects, b"from", &src);
            projects.push(b'}');
        }
    };
    let wants = |projects: &mut Vec<u8>, tools: &[&str]| {
        jkey(projects, b"wants");
        projects.push(b'{');
        for t in tools {
            if let Some((val, src)) = fact_get(all, t.as_bytes()) {
                // "x.requires" is a range the manifest states (engines,
                // requires-python, rust-version), beside a pinned version of x.
                jkey(projects, t.as_bytes());
                projects.push(b'{');
                jtext(projects, b"version", &val);
                jtext(projects, b"from", &src);
                projects.push(b'}');
            }
        }
        projects.push(b'}');
    };
    // The nearest workspace of this kind: this folder, or one above that
    // may or may not list it.
    let workspace = |projects: &mut Vec<u8>, kind: &str| {
        let (root, file) = match fact_get(all, format!("ws.{}", kind).as_bytes()) { Some(x) => x, None => return };
        let globs = fact_get(all, format!("wsglobs.{}", kind).as_bytes()).map(|x| x.0).unwrap_or_default();
        jkey(projects, b"workspace");
        projects.push(b'{');
        jtext(projects, b"root", &root);
        jtext(projects, b"from", &file);
        jkey(projects, b"is_root");
        jbool(projects, root == rel);
        if root != rel {
            jkey(projects, b"member");
            jbool(projects, workspace_member(&root, &globs, rel));
        }
        projects.push(b'}');
    };

    if n_has {
        begin(projects, "node", &n_name, "package.json");
        manager(projects, "pm.node");
        wants(projects, &["node", "node.requires", "bun", "bun.requires", "pnpm", "yarn"]);
        workspace(projects, "node");
        jkey(projects, b"dependencies_installed");
        if let Some((_, src)) = fact_get(all, b"nm") {
            projects.push(b'{');
            jkey(projects, b"installed");
            projects.extend_from_slice(b"true");
            jtext(projects, b"at", &src);
            projects.push(b'}');
        } else { projects.extend_from_slice(b"{\"installed\":false}"); }
        if !n_test.is_empty() { jtext(projects, b"test_script", &n_test); }
        if !n_ts.is_empty() { jtext(projects, b"typescript", &n_ts); }
        let mut configs: Vec<u8> = Vec::new();
        for x in names {
            if starts_with(x, b"tsconfig") && ends_with(x, b".json") { if !configs.is_empty() { configs.push(b','); } jstring(&mut configs, x); }
        }
        if !configs.is_empty() {
            jkey(projects, b"tsconfigs");
            projects.push(b'[');
            projects.extend_from_slice(&configs);
            projects.push(b']');
        }
        projects.push(b'}');
        counts[0] += 1;
    }
    if !p_manifest.is_empty() {
        begin(projects, "python", &p_name, p_manifest);
        manager(projects, "pm.python");
        wants(projects, &["python", "python.requires", "uv"]);
        workspace(projects, "python");
        jkey(projects, b"environment");
        if let Some((val, _)) = fact_get(all, b"venv") {
            projects.push(b'{');
            jtext(projects, b"venv", &val);
            if let Some((pv, _)) = fact_get(all, b"venv.python") { jtext(projects, b"python", &pv); }
            projects.push(b'}');
        } else { projects.extend_from_slice(b"null"); }
        if p_pytest { jtext(projects, b"tests", b"pytest"); }
        projects.push(b'}');
        counts[1] += 1;
    }
    if r_has {
        begin(projects, "rust", &r_name, "Cargo.toml");
        wants(projects, &["rust", "rust.requires"]);
        workspace(projects, "rust");
        jkey(projects, b"lock_file");
        jbool(projects, has_cargo_lock);
        projects.push(b'}');
        counts[2] += 1;
    }
    if g_has {
        begin(projects, "go", &g_module, "go.mod");
        wants(projects, &["go", "go.toolchain"]);
        workspace(projects, "go");
        projects.push(b'}');
        counts[3] += 1;
    }
    if !j_tool.is_empty() {
        begin(projects, "java", b"", j_manifest);
        jtext(projects, b"build_tool", j_tool.as_bytes());
        wants(projects, &["java"]);
        projects.push(b'}');
        counts[4] += 1;
    }
    if !d_manifest.is_empty() {
        begin(projects, "deno", b"", d_manifest);
        wants(projects, &["deno"]);
        projects.push(b'}');
        counts[5] += 1;
    }
}

/// The files that make a folder worth reading. Anything else: its facts are
/// its parent's.
const SURVEY_FILES: [&str; 42] = [
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
    "pnpm-workspace.yaml", "bun.lock", "bun.lockb", "node_modules", ".nvmrc", ".node-version",
    ".bun-version", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile",
    "pdm.lock", "poetry.lock", "uv.lock", ".python-version", ".venv", "venv", "pytest.ini",
    "conftest.py", "Cargo.toml", "rust-toolchain", "rust-toolchain.toml", "go.mod", "go.work",
    ".go-version", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
    "settings.gradle.kts", ".java-version", "deno.json", "deno.jsonc", "mise.toml", ".mise.toml",
    ".tool-versions",
];

pub fn survey_main(repo_arg: &[u8]) {
    use std::io::Write;
    let repo = abs_dir(repo_arg);
    if !sys::is_dir(&repo) { die(&format!("spread-wings: not a directory: {}", s(&repo))); }
    // Folders in the order met, a parent before its children; each with the
    // facts that hold in it (a number into `facts`; 0 is "none").
    let mut dirs: Vec<(Vec<u8>, usize)> = vec![(repo.clone(), 0)];
    let mut facts: Vec<Vec<u8>> = vec![Vec::new()];
    let mut projects: Vec<u8> = Vec::new();
    let mut counts = [0i64; 6];
    // Depth first, a folder's children in name order, so the projects come
    // out in path order; a parent is always read before its children.
    let mut todo: Vec<usize> = vec![0];
    let mut read_count = 0;
    while !todo.is_empty() && read_count < 200000 {
        let at = todo.pop().unwrap_or(0);
        read_count += 1;
        let dir = dirs[at].0.clone();
        let names = match sys::list_dir(&dir) { Some(n) => n, None => continue };
        let worth = names.iter().any(|x| SURVEY_FILES.iter().any(|f| f.as_bytes() == &x[..]));
        if worth {
            let inherited = facts[dirs[at].1].clone();
            let mut own: Vec<u8> = Vec::new();
            let rel: &[u8] = if dir.len() > repo.len() { &dir[repo.len() + 1..] } else { b"." };
            survey_folder(&dir, rel, &names, &inherited, &mut own, &mut projects, &mut counts);
            if !own.is_empty() {
                let mut both = inherited;
                both.extend_from_slice(&own);
                facts.push(both);
                dirs[at].1 = facts.len() - 1;
            }
        }
        let first_child = dirs.len();
        for name in &names {
            if !name.is_empty() && name[0] != b'.' && !SKIP_DIRS.iter().any(|d| d.as_bytes() == &name[..]) {
                let mut full = dir.clone();
                full.push(b'/');
                full.extend_from_slice(name);
                if sys::is_dir(&full) && !sys::is_symlink(&full) {
                    let fi = dirs[at].1;
                    dirs.push((full, fi));
                }
            }
        }
        let mut k = dirs.len();
        while k > first_child { k -= 1; todo.push(k); }
    }
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"{\n  \"root\": ");
    jstring(&mut out, &repo);
    out.extend_from_slice(format!(",\n  \"folders_read\": {},\n  \"projects\": [", read_count).as_bytes());
    out.extend_from_slice(&projects);
    out.extend_from_slice(if !projects.is_empty() { b"\n  ]" as &[u8] } else { b"]" });
    out.extend_from_slice(
        format!(
            ",\n  \"count\": {{\"node\": {}, \"python\": {}, \"rust\": {}, \"go\": {}, \"java\": {}, \"deno\": {}}}",
            counts[0], counts[1], counts[2], counts[3], counts[4], counts[5]
        )
        .as_bytes(),
    );
    out.extend_from_slice(b",\n  \"evidence\": \"read from manifest, lock and version files; nothing of the repo was run, and whether a wanted version is installed on this machine was not checked\"\n}\n");
    let _ = std::io::stdout().write_all(&out);
}
