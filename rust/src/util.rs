// Byte-string helpers with the meanings the Goose program's builtins have, so
// its code carries over line for line: text is bytes (a source file need not
// be UTF-8), `find` gives -1 for "not there", `split` keeps empty parts.

pub fn find(hay: &[u8], needle: &[u8]) -> i64 {
    if needle.is_empty() { return 0; }
    if needle.len() > hay.len() { return -1; }
    if needle.len() == 1 {
        return match hay.iter().position(|&c| c == needle[0]) { Some(i) => i as i64, None => -1 };
    }
    let first = needle[0];
    let last = hay.len() - needle.len();
    let mut i = 0;
    while i <= last {
        match hay[i..=last].iter().position(|&c| c == first) {
            None => return -1,
            Some(k) => {
                i += k;
                if &hay[i..i + needle.len()] == needle { return i as i64; }
                i += 1;
            }
        }
    }
    -1
}

pub fn rfind(hay: &[u8], needle: &[u8]) -> i64 {
    if needle.is_empty() { return hay.len() as i64; }
    if needle.len() > hay.len() { return -1; }
    let mut i = hay.len() - needle.len();
    loop {
        if &hay[i..i + needle.len()] == needle { return i as i64; }
        if i == 0 { return -1; }
        i -= 1;
    }
}

fn is_space(c: u8) -> bool { c == b' ' || (9..=13).contains(&c) }

pub fn trim(s: &[u8]) -> &[u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && is_space(s[a]) { a += 1; }
    while b > a && is_space(s[b - 1]) { b -= 1; }
    &s[a..b]
}

pub fn starts_with(s: &[u8], p: &[u8]) -> bool { s.len() >= p.len() && &s[..p.len()] == p }
pub fn ends_with(s: &[u8], p: &[u8]) -> bool { s.len() >= p.len() && &s[s.len() - p.len()..] == p }

/// The parts of s between each sep; empty parts kept ("a\n" gives "a" and "").
pub fn split(s: &[u8], sep: u8) -> Vec<&[u8]> {
    s.split(|&c| c == sep).collect()
}

/// An optional sign and digits, the whole of s; None otherwise.
pub fn parse_int(s: &[u8]) -> Option<i64> {
    if s.is_empty() { return None; }
    std::str::from_utf8(s).ok()?.parse::<i64>().ok().filter(|_| {
        let d = if s[0] == b'-' || s[0] == b'+' { &s[1..] } else { s };
        !d.is_empty() && d.iter().all(|c| c.is_ascii_digit())
    })
}

pub fn push_int(out: &mut Vec<u8>, v: i64) { out.extend_from_slice(v.to_string().as_bytes()); }

pub fn s(b: &[u8]) -> String { String::from_utf8_lossy(b).into_owned() }

/// Says what is wrong and ends the run, as the Goose program's abort does.
pub fn die(msg: &str) -> ! {
    eprintln!("{}", msg);
    std::process::exit(1);
}

/// A hash of some bytes (FNV-1a, 64 bits). Only ever compared with itself:
/// a file's content now against the same file's content last time.
pub fn hash(s: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &c in s { h = (h ^ c as u64).wrapping_mul(0x100000001b3); }
    h
}
