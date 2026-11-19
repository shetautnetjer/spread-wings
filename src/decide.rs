// Decisions with Span-02 (respan/span-02, through OpenRouter's System One
// endpoint): for each call the code alone couldn't tie to one definition
// (resolution by_name), a typed choice among the candidate definitions plus
// "outside this repo", answered with probabilities. Never free text, so it
// can't invent a definition.
//
// Cost is the state's tokens times the number of questions (measured: a
// state is billed once per question), while a request with 50 questions
// takes about as long as one with 1. So the state is kept small (the
// caller's own function), the questions that share it go in one request,
// and requests run in parallel on worker threads. Answers are cached by
// content in ~/.cache/spread-wings/decisions.db: unchanged code is never
// asked twice.
//
// The cache's keys are util::hash of the model, the state and the question:
// the hash the program has always used, so answers cached before the move
// to Rust are still found.

use crate::db::Db;
use crate::graph::{call_file_edges, communities};
use crate::query::jtext;
use crate::sql;
use crate::store::*;
use crate::sys;
use crate::util::*;
use serde_json::Value;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MODEL: &str = "respan/span-02";
const URL: &str = "https://openrouter.ai/api/v1/systemone";
const KEY_ENV: &str = "OPENROUTER_API_KEY";
const MAX_PER_REQUEST: i64 = 8; // questions per cluster of nearby calls (one small state each)
const MIN_P: i64 = 600; // thousandths: a choice below 0.6 changes nothing
const WINDOW: i64 = 4;

fn add(out: &mut Vec<u8>, t: &str) { out.extend_from_slice(t.as_bytes()); }

/// POSTs body (JSON) to url with "Authorization: Bearer $<key_env>" and
/// appends the response body to out. Returns the HTTP status, or -1 when the
/// key is missing or the request could not be made. The key is read from
/// the environment here, by name, and goes nowhere but the header.
///
/// Through libcurl itself (curl-sys), set up on the first request: the `curl` crate sets libcurl and OpenSSL up
/// when the program starts, which cost every command, `find` included,
/// half a millisecond and 3.7 MB (measured 2026-11-18).
fn http_post(url: &str, key_env: &str, body: &[u8], timeout_s: i64, out: &mut Vec<u8>) -> i64 {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_long, c_void};
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe { curl_sys::curl_global_init(curl_sys::CURL_GLOBAL_DEFAULT); });
    extern "C" fn on_body(p: *mut c_char, size: usize, n: usize, ud: *mut c_void) -> usize {
        let out = unsafe { &mut *(ud as *mut Vec<u8>) };
        out.extend_from_slice(unsafe { std::slice::from_raw_parts(p as *const u8, size * n) });
        size * n
    }
    let key = match std::env::var(key_env) { Ok(k) if !k.is_empty() => k, _ => return -1 };
    let (u, auth) = match (CString::new(url), CString::new(format!("Authorization: Bearer {}", key))) {
        (Ok(u), Ok(a)) => (u, a),
        _ => return -1,
    };
    let mut status: i64 = -1;
    unsafe {
        let c = curl_sys::curl_easy_init();
        if !c.is_null() {
            let mut h = curl_sys::curl_slist_append(std::ptr::null_mut(), auth.as_ptr());
            h = curl_sys::curl_slist_append(h, b"Content-Type: application/json\0".as_ptr() as *const c_char);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_URL, u.as_ptr());
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_HTTPHEADER, h);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_POSTFIELDS, body.as_ptr() as *const c_char);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_POSTFIELDSIZE, body.len() as c_long);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_TIMEOUT, timeout_s as c_long);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_WRITEFUNCTION, on_body as extern "C" fn(*mut c_char, usize, usize, *mut c_void) -> usize);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_WRITEDATA, out as *mut Vec<u8> as *mut c_void);
            curl_sys::curl_easy_setopt(c, curl_sys::CURLOPT_NOSIGNAL, 1 as c_long);
            if curl_sys::curl_easy_perform(c) == curl_sys::CURLE_OK {
                let mut code: c_long = 0;
                curl_sys::curl_easy_getinfo(c, curl_sys::CURLINFO_RESPONSE_CODE, &mut code as *mut c_long);
                status = code as i64;
            }
            curl_sys::curl_slist_free_all(h);
            curl_sys::curl_easy_cleanup(c);
        }
    }
    // The header held the key: wiped before its memory goes back.
    let mut held = auth.into_bytes();
    for b in held.iter_mut() { *b = 0; }
    status
}

/// One request, with its retries: rate limits and busy servers back off and
/// are tried again, 4 times at most.
fn ask(body: &[u8]) -> (i64, Vec<u8>) {
    let mut data: Vec<u8> = Vec::new();
    let mut attempt = 0;
    loop {
        data.clear();
        let status = http_post(URL, KEY_ENV, body, 120, &mut data);
        if !((status == 429 || status >= 500 || status < 0) && attempt < 4) { return (status, data); }
        std::thread::sleep(Duration::from_millis((1u64 << attempt) * 1000));
        attempt += 1;
    }
}

/// The function's first line, then the lines within WINDOW of any of
/// `rows` (file line numbers), numbered from 1 at `from`, with "..." where
/// lines are left out. Smaller than the whole function, and billed per
/// question.
fn window_lines(text: &[u8], from: i64, to: i64, rows: &[i64], out: &mut Vec<u8>) {
    let mut row: i64 = 0;
    let mut gap = false;
    for l in text.split(|&c| c == b'\n') {
        row += 1;
        if row >= from && row <= to {
            // The first line, and any import inside the function: the clue
            // the model needs most, at a few tokens.
            let tl = trim(l);
            let mut keep = row == from || starts_with(tl, b"import ") || (starts_with(tl, b"from ") && find(tl, b" import ") > 0) || starts_with(tl, b"use ");
            for &r in rows { if row >= r - WINDOW && row <= r + WINDOW { keep = true; } }
            if keep {
                push_int(out, row - from + 1);
                add(out, ": ");
                out.extend_from_slice(l);
                out.push(b'\n');
                gap = false;
            } else if !gap { add(out, "...\n"); gap = true; }
        }
    }
}

struct Site { file: i64, row: i64, callee: Vec<u8> }

/// "d123" -> 123, "outside" -> 0, anything else -> -1.
fn choice_target(ch: &[u8]) -> i64 {
    if ch == b"outside" { return 0; }
    if !(ch.len() > 1 && ch[0] == b'd') { return -1; }
    match parse_int(&ch[1..]) { Some(t) if t > 0 => t, _ => -1 }
}

fn mkdirs(p: &[u8]) -> bool {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(sys::path(p)).is_ok()
}

pub fn decide_main(db_path: &[u8], max_questions: i64, max_workers: i64) {
    let db = open_map(db_path);
    let mut err = String::new();
    let root = get_meta(&db, b"root").unwrap_or_default();
    // SPREAD_WINGS_CACHE picks another cache folder (a fresh one measures a
    // first run without touching the real cache).
    use std::os::unix::ffi::OsStringExt;
    let mut cache_dir: Vec<u8> = std::env::var_os("SPREAD_WINGS_CACHE").map(|v| v.into_vec()).unwrap_or_default();
    if cache_dir.is_empty() {
        let home = match std::env::var_os("HOME") { Some(h) => h.into_vec(), None => die("spread-wings: HOME is not set") };
        cache_dir = home;
        cache_dir.extend_from_slice(b"/.cache/spread-wings");
    }
    mkdirs(&cache_dir);
    let mut cache_path = cache_dir.clone();
    cache_path.extend_from_slice(b"/decisions.db");
    let cache = match Db::open(&cache_path) {
        Ok(c) => c,
        Err(e) => die(&format!("spread-wings: cannot open the decision cache: {}", e)),
    };
    cache.exec_or_die(b"CREATE TABLE IF NOT EXISTS answers (key TEXT PRIMARY KEY, choice TEXT, p INTEGER)");
    let cache_get = cache.prepare_or_die(b"SELECT choice, p FROM answers WHERE key = ?1");
    let cache_put = cache.prepare_or_die(b"INSERT OR REPLACE INTO answers (key, choice, p) VALUES (?1, ?2, ?3)");

    let mut bodies: Vec<Vec<u8>> = Vec::new(); // request bodies
    let mut qsite: Vec<Site> = Vec::new(); // question index -> site
    let mut qreq: Vec<i64> = Vec::new(); // question index -> request (-1: from the cache)
    let mut qkey: Vec<Vec<u8>> = Vec::new(); // question index -> cache key
    let mut cached_choice: Vec<Vec<u8>> = Vec::new(); // question index -> cached "choice p" or ""
    let mut asked: i64 = 0;
    let mut from_cache: i64 = 0;
    {
        // Each still-ambiguous call site, grouped by the function it sits in.
        let sites_st = db.prepare_or_die(sql::DECIDE_SITES_SQL.as_bytes());
        let cand_st = db.prepare_or_die(sql::DECIDE_CANDIDATES_SQL.as_bytes());
        let imp_st = db.prepare_or_die(b"SELECT DISTINCT module FROM imports WHERE file_id = ?1 ORDER BY row");
        let rows_st = db.prepare_or_die(sql::DECIDE_ROWS_SQL.as_bytes());

        let mut cur_group: i64 = -1;
        let mut cur_file: i64 = -1;
        let mut state: Vec<u8> = Vec::new();
        let mut questions: Vec<u8> = Vec::new();
        let mut in_req: i64 = 0;
        let mut text: Vec<u8> = Vec::new();
        let mut state_from: i64 = 1; // the file line that is line 1 of the state
        let mut cluster_end: i64 = -1; // the last call line the current state covers
        let mut state_imports: Vec<u8> = Vec::new();
        let mut state_imports_file: i64 = -1;

        fn flush_request(bodies: &mut Vec<Vec<u8>>, state: &[u8], questions: &mut Vec<u8>, in_req: &mut i64) {
            if !(*in_req > 0) { return; }
            let mut body: Vec<u8> = Vec::new();
            add(&mut body, "{\"model\":");
            jtext(&mut body, MODEL.as_bytes());
            add(&mut body, ",\"state\":");
            jtext(&mut body, state);
            add(&mut body, ",\"questions\":{");
            body.extend_from_slice(questions);
            add(&mut body, "}}");
            bodies.push(body);
            questions.clear();
            *in_req = 0;
        }

        while sites_st.step(&mut err) == 1 && asked + from_cache < max_questions {
            let fid = sites_st.col_int(0);
            let row = sites_st.col_int(1);
            let callee = sites_st.col_text(2);
            let ctext = sites_st.col_text(3);
            let in_sym = sites_st.col_int(4);
            let path = sites_st.col_text(5);
            let s_row = sites_st.col_int(6);
            let s_end = sites_st.col_int(7);
            // A new state for another function or file, a call too far from the
            // cluster's last one, or a full cluster: each question pays for its
            // state, so a state covers only a few nearby calls.
            let group = fid * 1000000 + in_sym;
            if group != cur_group || in_req >= MAX_PER_REQUEST || row > cluster_end {
                flush_request(&mut bodies, &state, &mut questions, &mut in_req);
                if fid != cur_file {
                    let mut p = root.clone();
                    p.push(b'/');
                    p.extend_from_slice(&path);
                    text = sys::read_file(&p).unwrap_or_default();
                    cur_file = fid;
                }
                state.clear();
                // The file's path and its imports help tell a repo call from a
                // library one; the code is the caller's own function.
                add(&mut state, "File: ");
                state.extend_from_slice(&path);
                state.push(b'\n');
                if fid != state_imports_file {
                    state_imports.clear();
                    imp_st.reset();
                    imp_st.bind_int(1, fid);
                    let mut nimp = 0;
                    while imp_st.step(&mut err) == 1 && nimp < 15 {
                        if nimp > 0 { add(&mut state_imports, ", "); }
                        state_imports.extend_from_slice(&imp_st.col_text(0));
                        nimp += 1;
                    }
                    state_imports_file = fid;
                }
                if !state_imports.is_empty() {
                    add(&mut state, "Imports: ");
                    state.extend_from_slice(&state_imports);
                    state.push(b'\n');
                }
                // This cluster: the ambiguous calls from this one on, while each is
                // within two windows of the previous and there are at most 8.
                let mut rows: Vec<i64> = Vec::new();
                rows_st.reset();
                rows_st.bind_int(1, fid);
                rows_st.bind_int(2, in_sym);
                rows_st.bind_int(3, row);
                while rows_st.step(&mut err) == 1 {
                    let r = rows_st.col_int(0);
                    if !rows.is_empty() && (r - rows[rows.len() - 1] > 2 * WINDOW + 1 || rows.len() as i64 >= MAX_PER_REQUEST) { break; }
                    rows.push(r);
                }
                cluster_end = if !rows.is_empty() { rows[rows.len() - 1] } else { row };
                if in_sym != 0 && s_row > 0 { state_from = s_row; window_lines(&text, s_row, s_end.max(s_row), &rows, &mut state); }
                else { state_from = 1; window_lines(&text, 1, 1000000000, &rows, &mut state); }
                cur_group = group;
            }
            // The question: which definition does this call reach?
            let mut crit: Vec<u8> = Vec::new();
            let mut nc = 0;
            cand_st.reset();
            cand_st.bind_int(1, fid);
            cand_st.bind_int(2, row);
            cand_st.bind_text(3, &callee);
            while cand_st.step(&mut err) == 1 {
                let tid = cand_st.col_int(0);
                let name = cand_st.col_text(1);
                let cont = cand_st.col_text(2);
                let tpath = cand_st.col_text(3);
                let sig = cand_st.col_text(4);
                if !crit.is_empty() { crit.push(b','); }
                jtext(&mut crit, format!("d{}", tid).as_bytes());
                crit.push(b':');
                let mut d: Vec<u8> = Vec::new();
                if !cont.is_empty() { d.extend_from_slice(&cont); d.push(b'.'); }
                d.extend_from_slice(&name);
                add(&mut d, " defined in ");
                d.extend_from_slice(&tpath);
                add(&mut d, ": ");
                d.extend_from_slice(&sig);
                jtext(&mut crit, &d);
                nc += 1;
            }
            if !(nc > 0) { continue; }
            add(&mut crit, ",\"outside\":");
            jtext(&mut crit, b"none of these: a function or method from a library, the language's builtins (for example dict.get, list.append, str.join) or another type not listed");
            let mut q: Vec<u8> = Vec::new();
            add(&mut q, "{\"type\":\"choice\",\"instructions\":");
            let mut ins: Vec<u8> = Vec::new();
            add(&mut ins, &format!("On line {}, the call `", row - state_from + 1));
            ins.extend_from_slice(&ctext);
            add(&mut ins, "(...)` uses the name ");
            ins.extend_from_slice(&callee);
            add(&mut ins, ". Which definition does it call?");
            jtext(&mut q, &ins);
            add(&mut q, ",\"criteria\":{");
            q.extend_from_slice(&crit);
            add(&mut q, "}}");
            // Cached by content: the model, the state and the question.
            let mut keyed: Vec<u8> = MODEL.as_bytes().to_vec();
            keyed.push(0x1f);
            keyed.extend_from_slice(&state);
            keyed.push(0x1f);
            keyed.extend_from_slice(&q);
            let key = hash(&keyed).to_string().into_bytes();
            qsite.push(Site { file: fid, row, callee: callee[..callee.len().min(95)].to_vec() });
            cache_get.reset();
            cache_get.bind_text(1, &key);
            qkey.push(key);
            if cache_get.step(&mut err) == 1 {
                let mut c = cache_get.col_text(0);
                c.push(b' ');
                push_int(&mut c, cache_get.col_int(1));
                cached_choice.push(c);
                qreq.push(-1);
                from_cache += 1;
            } else {
                cached_choice.push(Vec::new());
                if !questions.is_empty() { questions.push(b','); }
                jtext(&mut questions, format!("q{}", qsite.len() - 1).as_bytes());
                questions.push(b':');
                questions.extend_from_slice(&q);
                qreq.push(bodies.len() as i64);
                in_req += 1;
                asked += 1;
            }
        }
        flush_request(&mut bodies, &state, &mut questions, &mut in_req);
    }
    let nreq = bodies.len();

    // Ask, on worker threads.
    let t0 = Instant::now();
    // Nothing to ask needs no key (everything came from the cache). With
    // questions and no key, stop now: each request would otherwise fail and
    // be retried for 15 seconds.
    if !(nreq == 0 || std::env::var_os(KEY_ENV).map(|v| !v.is_empty()).unwrap_or(false)) {
        die(&format!("spread-wings decide: {} requests to send and {} is not set", nreq, KEY_ENV));
    }
    let mut results: Vec<(i64, Vec<u8>)> = (0..nreq).map(|_| (0, Vec::new())).collect();
    if nreq > 0 {
        let workers = (max_workers.max(1) as usize).min(nreq).max(1);
        let next = AtomicUsize::new(0);
        let done: Mutex<Vec<(usize, (i64, Vec<u8>))>> = Mutex::new(Vec::new());
        std::thread::scope(|sc| {
            for _ in 0..workers {
                sc.spawn(|| loop {
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    if k >= nreq { break; }
                    let r = ask(&bodies[k]);
                    done.lock().unwrap().push((k, r));
                });
            }
        });
        for (k, r) in done.into_inner().unwrap() { results[k] = r; }
    }

    // Read the answers. Per question: the chosen definition (0 for
    // "outside", -1 unanswered) and p in thousandths.
    let mut ans_target: Vec<i64> = vec![-1; qsite.len()];
    let mut ans_p: Vec<i64> = vec![0; qsite.len()];
    let mut failed_requests: i64 = 0;
    let mut input_tokens: i64 = 0;
    let mut cost_micro: i64 = 0;
    for (status, data) in &results {
        if *status != 200 { failed_requests += 1; continue; }
        let rootn: Value = match serde_json::from_slice(data) { Ok(v) => v, Err(_) => { failed_requests += 1; continue; } };
        let usage = rootn.as_object().and_then(|o| o.get("usage")).and_then(|u| u.as_object());
        if let Some(it) = usage.and_then(|u| u.get("input_tokens")).and_then(|v| v.as_i64()) { input_tokens += it; }
        if let Some(cst) = usage.and_then(|u| u.get("cost")).and_then(|v| v.as_f64()) { cost_micro += (cst * 1000000.0) as i64; }
        let answers = match rootn.as_object().and_then(|o| o.get("answers")) { Some(a) => a, None => { failed_requests += 1; continue; } };
        if let Some(members) = answers.as_object() {
            for (k, a) in members {
                let k = k.as_bytes();
                if k.is_empty() { continue; }
                if let Some(qi) = parse_int(&k[1..]) {
                    if qi >= 0 && (qi as usize) < qsite.len() {
                        if let Some(ch) = a.as_object().and_then(|o| o.get("choice")).and_then(|v| v.as_str()) {
                            let p = a.as_object().and_then(|o| o.get("probabilities")).and_then(|v| v.as_object()).and_then(|o| o.get(ch)).and_then(|v| v.as_f64());
                            ans_p[qi as usize] = match p { Some(p) => (p * 1000.0) as i64, None => 0 };
                            ans_target[qi as usize] = choice_target(ch.as_bytes());
                        }
                    }
                }
            }
        }
    }
    let t1 = Instant::now();

    // Apply: a definition chosen with p >= 0.6 becomes the call's only link
    // (resolution "decided", weight p); "outside" with p >= 0.6 removes the
    // guessed links; anything less certain leaves by_name as it was.
    db.exec_or_die(b"BEGIN; DELETE FROM decisions;");
    let mut decided: i64 = 0;
    let mut outside: i64 = 0;
    let mut unsure: i64 = 0;
    {
        let ins_dec = db.prepare_or_die(b"INSERT INTO decisions (file_id, row, callee, choice, target, p) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
        for i in 0..qsite.len() {
            let target: i64;
            let p: i64;
            if qreq[i] < 0 {
                let c = &cached_choice[i];
                let sp = rfind(c, b" ");
                if !(sp > 0) { continue; }
                let pp = match parse_int(&c[sp as usize + 1..]) { Some(v) => v, None => continue };
                target = choice_target(&c[..sp as usize]);
                p = pp;
            } else {
                target = ans_target[i];
                p = ans_p[i];
            }
            if !(target >= 0) { continue; }
            let choice = if target == 0 { "outside".to_string() } else { format!("d{}", target) };
            if qreq[i] >= 0 {
                cache_put.reset();
                cache_put.bind_text(1, &qkey[i]);
                cache_put.bind_text(2, choice.as_bytes());
                cache_put.bind_int(3, p);
                cache_put.step_done();
            }
            let site = &qsite[i];
            ins_dec.reset();
            ins_dec.bind_int(1, site.file);
            ins_dec.bind_int(2, site.row);
            ins_dec.bind_text(3, &site.callee);
            ins_dec.bind_text(4, choice.as_bytes());
            ins_dec.bind_int(5, target);
            ins_dec.bind_int(6, p);
            ins_dec.step_done();
            if p < MIN_P { unsure += 1; } else if target != 0 { decided += 1; } else { outside += 1; }
        }
    }
    let dropped = apply_decisions(&db);
    call_file_edges(&db, false);
    let g100 = parse_int(&get_meta(&db, b"resolution").unwrap_or_default());
    let rounds = communities(&db, match g100 { Some(g) if g > 0 => g as f64 / 100.0, _ => 1.5 });
    set_meta(&db, b"decided_with", MODEL.as_bytes());
    db.exec_or_die(b"COMMIT");
    drop(cache_get);
    drop(cache_put);
    drop(cache);
    println!(
        "spread-wings decide: {} questions asked in {} requests ({} failed), {} from cache; {} calls tied to one definition, {} found to be outside the repo, {} left as by_name (p < 0.6); {} answers not used (see apply_decisions); {} input tokens, ${}.{:06}; {} ms asking; {} communities ({} rounds)",
        asked, nreq, failed_requests, from_cache, decided, outside, unsure, dropped, input_tokens,
        cost_micro / 1000000, cost_micro % 1000000, (t1 - t0).as_millis(),
        db.scalar(b"SELECT COUNT(*) FROM communities"), rounds
    );
}

/// Writes the rows of `decisions` into the links. Returns how many answers
/// were not used, for one of two reasons:
///   - the answer names a definition that was not one of that call's
///     by_name candidates. Nothing offered it, so it is not an answer;
///     taking it would delete every real candidate and link nothing.
///   - links are kept per line and name, and two calls of one name on a line
///     (`a.render(), b.render()`) got answers that differ, or only one of
///     them a sure one. Writing either would overwrite the other call's
///     links, so both stay by_name.
fn apply_decisions(db: &Db) -> i64 {
    let before = db.scalar(b"SELECT COUNT(*) FROM decisions");
    db.exec_or_die(sql::DECIDE_DROP_SQL.as_bytes());
    let dropped = before - db.scalar(b"SELECT COUNT(*) FROM decisions");
    db.exec_or_die(sql::DECIDE_APPLY_SQL.as_bytes());
    dropped
}

/// For the tests: applies whatever rows the decisions table holds, asking
/// nothing (`spread-wings decide-apply <graph.db>`).
pub fn decide_apply_main(db_path: &[u8]) {
    let db = open_map(db_path);
    db.exec_or_die(b"BEGIN");
    let dropped = apply_decisions(&db);
    call_file_edges(&db, false);
    db.exec_or_die(b"COMMIT");
    println!("spread-wings decide-apply: {} answers applied, {} not used", db.scalar(b"SELECT COUNT(*) FROM decisions"), dropped);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    // The request as a server on this machine gets it, and its answer as
    // http_post gives it back. (The real address is never asked here.)
    #[test]
    fn post_carries_the_key_and_the_body_and_returns_the_answer() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut sock, _) = listener.accept().unwrap();
            let mut got: Vec<u8> = Vec::new();
            let mut buf = [0u8; 4096];
            loop {
                let n = sock.read(&mut buf).unwrap();
                if n == 0 { break; }
                got.extend_from_slice(&buf[..n]);
                let head_end = find(&got, b"\r\n\r\n");
                if head_end >= 0 && got.len() >= head_end as usize + 4 + 7 { break; }
            }
            let answer = b"{\"answers\":{}}";
            sock.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", answer.len()).as_bytes()).unwrap();
            sock.write_all(answer).unwrap();
            got
        });
        std::env::set_var("SW_TEST_KEY", "k123");
        let mut out: Vec<u8> = Vec::new();
        let status = http_post(&format!("http://127.0.0.1:{}/x", port), "SW_TEST_KEY", b"{\"a\":1}", 10, &mut out);
        let got = server.join().unwrap();
        assert_eq!(status, 200);
        assert_eq!(out, b"{\"answers\":{}}");
        assert!(find(&got, b"POST /x ") == 0, "{}", s(&got));
        assert!(find(&got, b"Authorization: Bearer k123\r\n") > 0, "{}", s(&got));
        assert!(find(&got, b"Content-Type: application/json\r\n") > 0, "{}", s(&got));
        assert!(ends_with(&got, b"{\"a\":1}"), "{}", s(&got));
    }

    #[test]
    fn post_without_a_key_asks_nobody() {
        let mut out: Vec<u8> = Vec::new();
        assert_eq!(http_post("http://127.0.0.1:9/x", "SW_TEST_NO_SUCH_KEY", b"{}", 10, &mut out), -1);
        assert!(out.is_empty());
    }

    #[test]
    fn a_choice_names_a_definition_or_outside() {
        assert_eq!(choice_target(b"d123"), 123);
        assert_eq!(choice_target(b"outside"), 0);
        assert_eq!(choice_target(b"d0"), -1);
        assert_eq!(choice_target(b"x"), -1);
    }
}
