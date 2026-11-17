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

import std;
import json;
import sqlite;
import .store;
import .graph;

extern fn sw_mkdirs(path: const u8[:]) -> bool;
extern fn sw_env_set(name: const u8[:]) -> bool;
extern fn sw_http_post(url: const u8[:], key_env: const u8[:], body: const u8[:], timeout_s: i64, out: u8[>..]&) -> i64;

let MODEL = "respan/span-02";
let URL = "https://openrouter.ai/api/v1/systemone";
let KEY_ENV = "OPENROUTER_API_KEY";
let MAX_PER_REQUEST = 8;    // questions per cluster of nearby calls (one small state each)
let MIN_P = 600;    // thousandths: a choice below 0.6 changes nothing

struct AskJob { idx: i64, body: u8[>..] }
struct AskDone { idx: i64, status: i64, data: u8[>..] }

thread_fn ask_worker() {
    loop {
        let job = qget<AskJob>();
        guard job.idx >= 0 else { break; }
        var done = AskDone { idx: job.idx, .. };
        var attempt = 0;
        loop {
            done.data.clear();
            done.status = sw_http_post(URL, KEY_ENV, job.body, 120, done.data);
            // Rate limits and busy servers: back off and retry, 4 times at most.
            guard (done.status == 429 || done.status >= 500 || done.status < 0) && attempt < 4 else { break; }
            sleep_ms((1 << attempt) * 1000);
            attempt++;
        }
        qput(done);
    }
}

// The function's first line, then the lines within WINDOW of any of
// `rows` (file line numbers), numbered from 1 at `from`, with "..." where
// lines are left out. Smaller than the whole function, and billed per
// question.
let WINDOW = 4;
fn window_lines(text: const u8[:], from: i64, to: i64, rows: const i64[:], out: u8[>..]&) {
    var row: i64 = 0;
    var gap = false;
    each_split(text, '\n') { l =>
        row++;
        if row >= from && row <= to {
            // The first line, and any import inside the function (tests often
            // import what they call on their first lines): the clue the model
            // needs most, at a few tokens.
            let tl = trim(l);
            var keep = row == from || starts_with(tl, "import ") || (starts_with(tl, "from ") && find(tl, " import ") > 0)
                       || starts_with(tl, "use ");
            for r in rows { if row >= r - WINDOW && row <= r + WINDOW { keep = true; } }
            if keep { format(out, row - from + 1, ": ", l, "\n"); gap = false; }
            else if !gap { out.append("...\n"); gap = true; }
        }
    };
}


struct Site { file: i64, row: i64, callee: u8[..96], text: u8[..128] }

fn decide_main(db_path: const u8[:], max_questions: i64, max_workers: i64) {
    let db = open_map(db_path);
    var err: u8[>..] = [];
    var root: u8[>..] = [];
    get_meta(db, "root", root);
    // SPREAD_WINGS_CACHE picks another cache folder (a fresh one measures a
    // first run without touching the real cache).
    var cache_dir: u8[>..] = [];
    if !env("SPREAD_WINGS_CACHE", cache_dir) || cache_dir.len == 0 {
        var home: u8[>..] = [];
        guard env("HOME", home) else { abort("spread-wings: HOME is not set"); }
        cache_dir.clear();
        format(cache_dir, home, "/.cache/spread-wings");
    }
    sw_mkdirs(cache_dir);
    let cache = sqlite::open(str(cache_dir, "/decisions.db"), err);
    guard cache != 0 else { abort(str("spread-wings: cannot open the decision cache: ", err)); }
    sqlite::exec_or_die(cache, "CREATE TABLE IF NOT EXISTS answers (key TEXT PRIMARY KEY, choice TEXT, p INTEGER)");
    let cache_get = sqlite::prepare_or_die(cache, "SELECT choice, p FROM answers WHERE key = ?1");
    let cache_put = sqlite::prepare_or_die(cache, "INSERT OR REPLACE INTO answers (key, choice, p) VALUES (?1, ?2, ?3)");

    // Each still-ambiguous call site, grouped by the function it sits in.
    let sites_st = sqlite::prepare_or_die(db, """
        SELECT DISTINCT c.file_id, c.row, c.callee, COALESCE(c.text, c.callee), c.in_symbol, f.path,
               COALESCE(s.row, 0), COALESCE(s.end_row, 0)
        FROM calls c JOIN files f ON f.id = c.file_id
        LEFT JOIN symbols s ON s.id = c.in_symbol
        WHERE EXISTS (SELECT 1 FROM call_edges e JOIN symbols t ON t.id = e.callee
                      WHERE e.file_id = c.file_id AND e.row = c.row AND t.name = c.callee AND e.resolution = 'by_name')
        ORDER BY c.file_id, c.in_symbol, c.row, c.callee
        """);
    let cand_st = sqlite::prepare_or_die(db, """
        SELECT DISTINCT t.id, t.name, COALESCE(t.container, ''), tf.path, COALESCE(t.sig, '')
        FROM call_edges e JOIN symbols t ON t.id = e.callee JOIN files tf ON tf.id = t.file_id
        WHERE e.file_id = ?1 AND e.row = ?2 AND t.name = ?3 AND e.resolution = 'by_name'
        ORDER BY t.id
        """);
    var bodies: u8[>..] = [];          // request bodies, 0x1e separated
    var nreq: i64 = 0;
    var qsite: Site[>..] = [];         // question index -> site
    var qreq: i64[>..] = [];           // question index -> request
    var qkey: u8[>..] = [];            // question index -> cache key, '\n' separated
    var cached_choice: u8[>..] = [];   // question index -> cached "choice p" or "", '\n' separated
    var asked: i64 = 0;
    var from_cache: i64 = 0;

    var cur_group: i64 = -1;
    var cur_file: i64 = -1;
    var state: u8[>..] = [];
    var questions: u8[>..] = [];
    var in_req: i64 = 0;
    var text: u8[>..] = [];
    var state_from: i64 = 1;    // the file line that is line 1 of the state
    var cluster_end: i64 = -1;  // the last call line the current state covers
    var state_imports: u8[>..] = [];
    var state_imports_file: i64 = -1;
    let imp_st = sqlite::prepare_or_die(db, "SELECT DISTINCT module FROM imports WHERE file_id = ?1 ORDER BY row");
    let rows_st = sqlite::prepare_or_die(db, """
        SELECT DISTINCT c.row FROM calls c
        WHERE c.file_id = ?1 AND c.in_symbol = ?2 AND c.row >= ?3
          AND EXISTS (SELECT 1 FROM call_edges e JOIN symbols t ON t.id = e.callee
                      WHERE e.file_id = c.file_id AND e.row = c.row AND t.name = c.callee AND e.resolution = 'by_name')
        ORDER BY c.row
        """);

    fn flush_request() {
        guard in_req > 0;
        var body: u8[>..] = [];
        body.append("{\"model\":");
        json::format_string(body, MODEL);
        body.append(",\"state\":");
        json::format_string(body, state);
        body.append(",\"questions\":{");
        body.append(questions);
        body.append("}}");
        bodies.append(body);
        bodies.push(0x1e);
        nreq++;
        questions.clear();
        in_req = 0;
    }

    while sqlite::step(sites_st, err) == 1 && asked + from_cache < max_questions {
        let fid = sqlite::col_int(sites_st, 0);
        let row = sqlite::col_int(sites_st, 1);
        var callee: u8[>..] = [];
        var ctext: u8[>..] = [];
        var path: u8[>..] = [];
        sqlite::col_text(sites_st, 2, callee);
        sqlite::col_text(sites_st, 3, ctext);
        let in_sym = sqlite::col_int(sites_st, 4);
        sqlite::col_text(sites_st, 5, path);
        let s_row = sqlite::col_int(sites_st, 6);
        let s_end = sqlite::col_int(sites_st, 7);
        // A new state for another function or file, a call too far from the
        // cluster's last one, or a full cluster: each question pays for its
        // state, so a state covers only a few nearby calls.
        let group = fid * 1000000 + in_sym;
        if group != cur_group || in_req >= MAX_PER_REQUEST || row > cluster_end {
            flush_request();
            if fid != cur_file {
                text.clear();
                read_file(str(root, "/", path), text);
                cur_file = fid;
            }
            state.clear();
            // The file's path and its imports help tell a repo call from a
            // library one; the code is the caller's own function.
            format(state, "File: ", path, "\n");
            if fid != state_imports_file {
                state_imports.clear();
                sqlite::reset(imp_st);
                sqlite::bind_int(imp_st, 1, fid);
                var nimp = 0;
                while sqlite::step(imp_st, err) == 1 && nimp < 15 {
                    var m: u8[>..] = [];
                    sqlite::col_text(imp_st, 0, m);
                    format(state_imports, if nimp > 0 { ", " } else { "" }, m);
                    nimp++;
                }
                state_imports_file = fid;
            }
            if state_imports.len > 0 { format(state, "Imports: ", state_imports, "\n"); }
            // The lines of this function's ambiguous calls, for the windows.
            // This cluster: the ambiguous calls from this one on, while each is
            // within two windows of the previous and there are at most 8.
            var rows: i64[>..] = [];
            sqlite::reset(rows_st);
            sqlite::bind_int(rows_st, 1, fid);
            sqlite::bind_int(rows_st, 2, in_sym);
            sqlite::bind_int(rows_st, 3, row);
            while sqlite::step(rows_st, err) == 1 {
                let r = sqlite::col_int(rows_st, 0);
                if rows.len > 0 && (r - rows[rows.len - 1] > 2 * WINDOW + 1 || rows.len >= MAX_PER_REQUEST) { break; }
                rows.push(r);
            }
            cluster_end = if rows.len > 0 { rows[rows.len - 1] } else { row };
            if in_sym != 0 && s_row > 0 { state_from = s_row; window_lines(text, s_row, max(s_end, s_row), rows, state); }
            else { state_from = 1; window_lines(text, 1, 1000000000, rows, state); }
            cur_group = group;
        }
        // The question: which definition does this call reach?
        var crit: u8[>..] = [];
        var nc = 0;
        sqlite::reset(cand_st);
        sqlite::bind_int(cand_st, 1, fid);
        sqlite::bind_int(cand_st, 2, row);
        sqlite::bind_text(cand_st, 3, callee);
        while sqlite::step(cand_st, err) == 1 {
            let tid = sqlite::col_int(cand_st, 0);
            var name: u8[>..] = [];
            var cont: u8[>..] = [];
            var tpath: u8[>..] = [];
            var sig: u8[>..] = [];
            sqlite::col_text(cand_st, 1, name);
            sqlite::col_text(cand_st, 2, cont);
            sqlite::col_text(cand_st, 3, tpath);
            sqlite::col_text(cand_st, 4, sig);
            if crit.len > 0 { crit.push(','); }
            json::format_string(crit, str("d", tid));
            crit.push(':');
            json::format_string(crit, str(if cont.len > 0 { str(cont, ".") } else { str("") }, name, " defined in ", tpath, ": ", sig));
            nc++;
        }
        guard nc > 0 else { continue; }
        crit.append(",\"outside\":");
        json::format_string(crit, "none of these: a function or method from a library, the language's builtins (for example dict.get, list.append, str.join) or another type not listed");
        var q: u8[>..] = [];
        q.append("{\"type\":\"choice\",\"instructions\":");
        json::format_string(q, str("On line ", row - state_from + 1, ", the call `", ctext, "(...)` uses the name ", callee, ". Which definition does it call?"));
        q.append(",\"criteria\":{");
        q.append(crit);
        q.append("}}");
        // Cached by content: the model, the state and the question.
        let key = str(hash(str(MODEL, "\x1f", state, "\x1f", q)));
        qkey.append(key);
        qkey.push('\n');
        var site = Site { file: fid, row: row, .. };
        site.callee.append(callee[..min(callee.len, 95)]);
        qsite.push(site);
        sqlite::reset(cache_get);
        sqlite::bind_text(cache_get, 1, key);
        if sqlite::step(cache_get, err) == 1 {
            var ch: u8[>..] = [];
            sqlite::col_text(cache_get, 0, ch);
            format(cached_choice, ch, " ", sqlite::col_int(cache_get, 1), "\n");
            qreq.push(-1);
            from_cache++;
        } else {
            cached_choice.push('\n');
            if questions.len > 0 { questions.push(','); }
            json::format_string(questions, str("q", qsite.len - 1));
            questions.push(':');
            questions.append(q);
            qreq.push(nreq);
            in_req++;
            asked++;
        }
    }
    flush_request();
    sqlite::finalize(sites_st);
    sqlite::finalize(cand_st);
    sqlite::finalize(imp_st);
    sqlite::finalize(rows_st);

    // Ask, on worker threads.
    var results: u8[>..] = [];
    var r_at: i64[>..] = [];
    var r_len: i64[>..] = [];
    var r_status: i64[>..] = [];
    r_at.resize(nreq, 0);
    r_len.resize(nreq, 0);
    r_status.resize(nreq, 0);
    let t0 = clock();
    // Nothing to ask needs no key (everything came from the cache). With
    // questions and no key, stop now: each request would otherwise fail and
    // be retried for 15 seconds.
    guard nreq == 0 || sw_env_set(KEY_ENV) else {
        abort(str("spread-wings decide: ", nreq, " requests to send and ", KEY_ENV, " is not set"));
    }
    if nreq > 0 {
        var k = 0;
        each_split(bodies, 0x1e) { b =>
            if b.len > 0 {
                var job = AskJob { idx: k, .. };
                job.body.append(b);
                qput(job);
                k++;
            }
        };
        let workers = max(1, min(max_workers, nreq));
        for w in 0..workers { qput(AskJob { idx: -1, .. }); }
        var tids: i64[>..] = [];
        for w in 0..workers { tids.push(thread_spawn(ask_worker)); }
        for i in 0..nreq {
            let d = qget<AskDone>();
            r_at[d.idx] = results.len;
            r_len[d.idx] = d.data.len;
            r_status[d.idx] = d.status;
            results.append(d.data);
        }
        for t in tids { thread_wait(t); }
    }

    // Read the answers: question index -> "choice p".
    // Per question: the chosen definition (0 for "outside", -1 unanswered) and p in thousandths.
    var ans_target: i64[>..] = [];
    var ans_p: i64[>..] = [];
    ans_target.resize(qsite.len, -1);
    ans_p.resize(qsite.len, 0);
    var failed_requests: i64 = 0;
    var input_tokens: i64 = 0;
    var cost_micro: i64 = 0;
    for r in 0..nreq {
        if r_status[r] != 200 { failed_requests++; continue; }
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let rootn, perr = json::parse(results[r_at[r]..r_at[r] + r_len[r]], doc, decoded);
        guard rootn else { failed_requests++; continue; }
        let usage = json::member(rootn, "usage");
        let it, it_ok = json::as_i64(json::member(usage, "input_tokens"));
        if it_ok { input_tokens = input_tokens + it; }
        let cst, c_ok = json::as_f64(json::member(usage, "cost"));
        if c_ok { cost_micro = cost_micro + (cst * 1000000.0) as i64; }
        let answers = json::member(rootn, "answers");
        guard answers else { failed_requests++; continue; }
        json::each(answers) { a =>
            let qi, ok = parse_int(a.key[1..]);
            if ok && qi >= 0 && qi < qsite.len {
                let ch, ch_ok = json::as_string(json::member(a, "choice"));
                if ch_ok {
                    let p, p_ok = json::as_f64(json::member(json::member(a, "probabilities"), ch));
                    ans_p[qi] = if p_ok { (p * 1000.0) as i64 } else { 0 };
                    ans_target[qi] = choice_target(ch);
                }
            }
        };
    }
    let t1 = clock();

    // Apply: a definition chosen with p >= 0.6 becomes the call's only link
    // (resolution "decided", weight p); "outside" with p >= 0.6 removes the
    // guessed links; anything less certain leaves by_name as it was.
    sqlite::exec_or_die(db, "BEGIN; DELETE FROM decisions;");
    let ins_dec = sqlite::prepare_or_die(db, "INSERT INTO decisions (file_id, row, callee, choice, target, p) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
    let keys = split(qkey, '\n');
    let cached = split(cached_choice, '\n');
    var decided: i64 = 0;
    var outside: i64 = 0;
    var unsure: i64 = 0;
    for i in 0..qsite.len {
        var target: i64 = -1;
        var p: i64 = 0;
        if qreq[i] < 0 {
            let c = cached[i];
            let sp = rfind(c, " ");
            guard sp > 0 else { continue; }
            let pp, ok = parse_int(c[sp + 1..]);
            guard ok else { continue; }
            target = choice_target(c[..sp]);
            p = pp;
        } else {
            target = ans_target[i];
            p = ans_p[i];
        }
        guard target >= 0 else { continue; }
        let choice = if target == 0 { str("outside") } else { str("d", target) };
        if qreq[i] >= 0 {
            sqlite::reset(cache_put);
            sqlite::bind_text(cache_put, 1, keys[i]);
            sqlite::bind_text(cache_put, 2, choice);
            sqlite::bind_int(cache_put, 3, p);
            sqlite::step_done(cache_put);
        }
        let site = qsite[i];
        sqlite::reset(ins_dec);
        sqlite::bind_int(ins_dec, 1, site.file);
        sqlite::bind_int(ins_dec, 2, site.row);
        sqlite::bind_text(ins_dec, 3, site.callee[..]);
        sqlite::bind_text(ins_dec, 4, choice);
        sqlite::bind_int(ins_dec, 5, target);
        sqlite::bind_int(ins_dec, 6, p);
        sqlite::step_done(ins_dec);
        if p < MIN_P { unsure++; } else if target != 0 { decided++; } else { outside++; }
    }
    sqlite::finalize(ins_dec);
    let dropped = apply_decisions(db);
    call_file_edges(db);
    var gs: u8[>..] = [];
    get_meta(db, "resolution", gs);
    let g100, g_ok = parse_int(gs);
    let rounds = communities(db, if g_ok && g100 > 0 { g100 as f64 / 100.0 } else { 1.5 });
    set_meta(db, "decided_with", MODEL);
    sqlite::exec_or_die(db, "COMMIT");
    sqlite::finalize(cache_get);
    sqlite::finalize(cache_put);
    sqlite::close(cache);
    print(str("spread-wings decide: ", asked, " questions asked in ", nreq, " requests (", failed_requests, " failed), ",
              from_cache, " from cache; ", decided, " calls tied to one definition, ", outside, " found to be outside the repo, ",
              unsure, " left as by_name (p < 0.6); ", dropped, " answers not used (see apply_decisions); ", input_tokens, " input tokens, $",
              cost_micro / 1000000, ".", pad6(cost_micro % 1000000), "; ", ((t1 - t0) * 1000.0) as i64, " ms asking; ",
              scalar(db, "SELECT COUNT(*) FROM communities"), " communities (", rounds, " rounds)"));
    sqlite::close(db);
}

// Writes the rows of `decisions` into the links. Returns how many answers
// were not used, for one of two reasons:
//   - the answer names a definition that was not one of that call's
//     by_name candidates. Nothing offered it, so it is not an answer;
//     taking it would delete every real candidate and link nothing.
//   - links are kept per line and name, and two calls of one name on a line
//     (`a.render(), b.render()`) got answers that differ, or only one of
//     them a sure one. Writing either would overwrite the other call's
//     links, so both stay by_name.
fn apply_decisions(db: i64) -> i64 {
    let before = scalar(db, "SELECT COUNT(*) FROM decisions");
    sqlite::exec_or_die(db, """
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
    """);
    let dropped = before - scalar(db, "SELECT COUNT(*) FROM decisions");
    sqlite::exec_or_die(db, """
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
    """);
    return dropped;
}

// For the tests: applies whatever rows the decisions table holds, asking
// nothing (`spread-wings decide-apply <graph.db>`).
fn decide_apply_main(db_path: const u8[:]) {
    let db = open_map(db_path);
    sqlite::exec_or_die(db, "BEGIN");
    let dropped = apply_decisions(db);
    call_file_edges(db);
    sqlite::exec_or_die(db, "COMMIT");
    print(str("spread-wings decide-apply: ", scalar(db, "SELECT COUNT(*) FROM decisions"), " answers applied, ", dropped, " not used"));
    sqlite::close(db);
}

// "d123" -> 123, "outside" -> 0, anything else -> -1.
fn choice_target(ch: const u8[:]) -> i64 {
    if ch == "outside" { return 0; }
    guard ch.len > 1 && ch[0] == 'd' else { return -1; }
    let t, ok = parse_int(ch[1..]);
    return if ok && t > 0 { t } else { -1 };
}

fn pad6(n: i64) -> u8[>..] {
    var s = str(n);
    var out: u8[>..] = [];
    for k in s.len..6 { out.push('0'); }
    out.append(s);
    return out;
}
