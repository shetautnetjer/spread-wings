// What the Goose program asks the system through native/sw_sys.c and Goose's
// os module: files, times, folders.

use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

pub fn path(p: &[u8]) -> &Path { Path::new(std::ffi::OsStr::from_bytes(p)) }

pub fn is_symlink(p: &[u8]) -> bool {
    fs::symlink_metadata(path(p)).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}
pub fn is_dir(p: &[u8]) -> bool { fs::metadata(path(p)).map(|m| m.is_dir()).unwrap_or(false) }
pub fn file_exists(p: &[u8]) -> bool { fs::metadata(path(p)).map(|m| m.is_file()).unwrap_or(false) }

/// -1 when the file cannot be looked at.
pub fn file_size(p: &[u8]) -> i64 { fs::metadata(path(p)).map(|m| m.len() as i64).unwrap_or(-1) }
pub fn mtime_ns(p: &[u8]) -> i64 {
    fs::metadata(path(p)).map(|m| m.mtime() * 1_000_000_000 + m.mtime_nsec()).unwrap_or(-1)
}
pub fn ctime_ns(p: &[u8]) -> i64 {
    fs::metadata(path(p)).map(|m| m.ctime() * 1_000_000_000 + m.ctime_nsec()).unwrap_or(-1)
}

pub fn time_ns() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as i64).unwrap_or(0)
}

/// The names in a folder, without `.` and `..`, sorted bytewise. None when
/// it cannot be read.
pub fn list_dir(dir: &[u8]) -> Option<Vec<Vec<u8>>> {
    let rd = fs::read_dir(path(dir)).ok()?;
    let mut names: Vec<Vec<u8>> = Vec::new();
    for e in rd {
        match e {
            Ok(e) => names.push(e.file_name().as_bytes().to_vec()),
            Err(_) => return None,
        }
    }
    names.sort();
    Some(names)
}

pub fn read_file(p: &[u8]) -> Option<Vec<u8>> { fs::read(path(p)).ok() }

/// The path with links followed and made absolute; None when it is not there.
pub fn realpath(p: &[u8]) -> Option<Vec<u8>> {
    fs::canonicalize(path(p)).ok().map(|x| x.as_os_str().as_bytes().to_vec())
}

pub fn hardware_threads() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}
