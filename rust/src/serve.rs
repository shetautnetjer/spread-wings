// The questions over MCP (stdio): one JSON-RPC message per line. From
// src/spread-wings.goose.

use crate::query::*;
use crate::sql;
use crate::store::open_map;
use crate::util::*;
use serde_json::Value;
use std::io::{BufRead, Write};

pub use crate::sql::VERSION;

fn add(out: &mut Vec<u8>, s: &str) { out.extend_from_slice(s.as_bytes()); }

fn format_id(out: &mut Vec<u8>, id: &Value) {
    match id {
        Value::Number(n) if n.is_i64() => push_int(out, n.as_i64().unwrap_or(0)),
        Value::String(s) => jtext(out, s.as_bytes()),
        _ => add(out, "null"),
    }
}

fn arg_text<'a>(args: Option<&'a Value>, key: &str) -> &'a str {
    args.and_then(|a| a.as_object()).and_then(|o| o.get(key)).and_then(|v| v.as_str()).unwrap_or("")
}

pub fn serve_main(db_path: &[u8]) {
    let db = open_map(db_path);
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let mut line: Vec<u8> = Vec::new();
    loop {
        line.clear();
        match stdin.lock().read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if trim(&line).is_empty() { continue; }
        let mut out: Vec<u8> = Vec::new();
        let root: Value = match serde_json::from_slice(&line) {
            Ok(v) => v,
            Err(e) => {
                add(&mut out, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":");
                jtext(&mut out, format!("json: {}", e).as_bytes());
                add(&mut out, "}}\n");
                let _ = stdout.write_all(&out);
                let _ = stdout.flush();
                continue;
            }
        };
        let method = arg_text(Some(&root), "method");
        let id = match root.as_object().and_then(|o| o.get("id")) {
            Some(v) => v,
            None => continue, // a notification
        };
        let params = root.as_object().and_then(|o| o.get("params"));
        add(&mut out, "{\"jsonrpc\":\"2.0\",\"id\":");
        format_id(&mut out, id);
        if method == "initialize" {
            add(&mut out, ",\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"spread-wings\",\"version\":\"");
            add(&mut out, VERSION);
            add(&mut out, "\"}}}");
        } else if method == "ping" {
            add(&mut out, ",\"result\":{}}");
        } else if method == "tools/list" {
            add(&mut out, ",\"result\":{\"tools\":");
            for &c in sql::TOOLS.as_bytes() { if c != b'\n' { out.push(c); } } // one JSON-RPC message per line
            add(&mut out, "}}");
        } else if method == "tools/call" {
            let name = arg_text(params, "name");
            let targs = params.and_then(|p| p.as_object()).and_then(|o| o.get("arguments"));
            let mut payload: Vec<u8> = Vec::new();
            let mut ok = true;
            if name == "overview" { overview(&db, &mut payload); }
            else if name == "find" {
                let n = arg_text(targs, "name");
                if n.is_empty() { add(&mut payload, "name is required"); ok = false; } else { find_defs(&db, n.as_bytes(), &mut payload); }
            } else if name == "neighbors" {
                let p = arg_text(targs, "path");
                if p.is_empty() { add(&mut payload, "path is required"); ok = false; } else { ok = neighbors(&db, p.as_bytes(), &mut payload); }
            } else if name == "callers" {
                let n = arg_text(targs, "name");
                if n.is_empty() { add(&mut payload, "name is required"); ok = false; } else { callers(&db, n.as_bytes(), &mut payload); }
            } else if name == "touches" {
                let n = arg_text(targs, "name");
                if n.is_empty() { add(&mut payload, "name is required"); ok = false; } else { ok = touches(&db, n.as_bytes(), arg_text(targs, "path").as_bytes(), &mut payload); }
            } else { add(&mut payload, "unknown tool: "); add(&mut payload, name); ok = false; }
            add(&mut out, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
            jtext(&mut out, &payload);
            add(&mut out, "}],\"isError\":");
            add(&mut out, if ok { "false" } else { "true" });
            add(&mut out, "}}");
        } else {
            add(&mut out, ",\"error\":{\"code\":-32601,\"message\":\"method not found\"}}");
        }
        out.push(b'\n');
        let _ = stdout.write_all(&out);
        let _ = stdout.flush();
    }
}
