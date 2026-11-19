// Byte-string helpers. Text is bytes (a source file need not be UTF-8),
// `find` gives -1 for "not there", `split` keeps empty parts: the meanings
// the program was written with (it began in Goose, and these were its
// builtins'), which the code that came over from there leans on.

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

/// Says what is wrong and ends the run.
pub fn die(msg: &str) -> ! {
    eprintln!("{}", msg);
    std::process::exit(1);
}

// A hash of a byte string: Goose's `hash` (its stdlib/std.goose), step for
// step. A file's stamp and a decision's cache key are this number, so the
// graphs and the cache written while the program was in Goose still read
// the same. Not to be changed without rebuilding both.
const K1: u64 = 11400714819323198485;
const K2: u64 = 15485907386658061715;

fn le64(s: &[u8], i: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&s[i..i + 8]);
    u64::from_le_bytes(b)
}

fn le32(s: &[u8], i: usize) -> u64 {
    let mut b = [0u8; 4];
    b.copy_from_slice(&s[i..i + 4]);
    u32::from_le_bytes(b) as u64
}

pub fn hash(s: &[u8]) -> u64 {
    let n = s.len();
    if n > 24 { return hash_lanes(s); }
    let mut h = (n as u64).wrapping_mul(K1);
    let mut w: u64 = 0;
    if n > 8 {
        let mut i = 0;
        while i < n - 8 {
            h = (h ^ le64(s, i)).wrapping_mul(K1);
            h = (h << 29) | (h >> 35);
            i += 8;
        }
        w = le64(s, n - 8);
    } else if n >= 4 {
        w = le32(s, 0) | le32(s, n - 4) << 32;
    } else if n > 0 {
        w = s[0] as u64 | (s[n >> 1] as u64) << 8 | (s[n - 1] as u64) << 16;
    }
    h = (h ^ w).wrapping_mul(K1);
    h = (h ^ (h >> 32)).wrapping_mul(K2);
    h ^ (h >> 32)
}

fn hash_lanes(s: &[u8]) -> u64 {
    let n = s.len();
    let mut h = (n as u64).wrapping_mul(K1);
    let mut g = h ^ 0x9E3779B97F4A7C15;
    let mut i = 0;
    while i < n - 24 {
        h = (h ^ le64(s, i)).wrapping_mul(K1);
        h = (h << 29) | (h >> 35);
        g = (g ^ le64(s, i + 8)).wrapping_mul(K1);
        g = (g << 29) | (g >> 35);
        i += 16;
    }
    h = h ^ ((g << 31) | (g >> 33));
    while i < n - 8 {
        h = (h ^ le64(s, i)).wrapping_mul(K1);
        h = (h << 29) | (h >> 35);
        i += 8;
    }
    h = (h ^ le64(s, n - 8)).wrapping_mul(K1);
    h = (h ^ (h >> 32)).wrapping_mul(K2);
    h ^ (h >> 32)
}

#[cfg(test)]
mod tests {
    use super::*;

    // What Goose's own `hash` gives for these (printed by a Goose program,
    // goose v2026.3): every branch of it, by length. A stamp or a cache key
    // written by one build must read the same to the other.
    #[test]
    fn hash_is_gooses_hash() {
        let want: [(usize, u64); 15] = [
            (0, 0), (1, 874251148392455296), (2, 7959004758223221308), (3, 16215211943321213931),
            (4, 14487226252335792074), (7, 12907706472906408456), (8, 4445469909192656180),
            (9, 15692679031000609385), (16, 14321181025998159423), (17, 7037860686989985198),
            (24, 16107364775720477008), (25, 9723631951205810525), (40, 16184706048744675262),
            (41, 11678578902861428149), (100, 4921713829712216036),
        ];
        for (n, h) in want {
            let text: Vec<u8> = (0..n).map(|i| b'a' + ((i * 7) % 26) as u8).collect();
            assert_eq!(hash(&text), h, "length {}", n);
        }
    }

    #[test]
    fn find_and_split_have_the_goose_meanings() {
        assert_eq!(find(b"abc", b"c"), 2);
        assert_eq!(find(b"abc", b"x"), -1);
        assert_eq!(find(b"abc", b""), 0);
        assert_eq!(rfind(b"a/b/c", b"/"), 3);
        assert_eq!(split(b"a\n", b'\n'), vec![&b"a"[..], &b""[..]]);
        assert_eq!(parse_int(b"-12"), Some(-12));
        assert_eq!(parse_int(b"12a"), None);
        assert_eq!(parse_int(b""), None);
        assert_eq!(trim(b" \t a b\n"), b"a b");
    }
}
