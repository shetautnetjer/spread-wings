// The watcher's wake-up: file events on the folders it was given, so that
// it sleeps until something under one of them is written, made, moved or
// removed. Only a wake-up: what changed is found by `update`. Linux
// (inotify); elsewhere open says -1 and the watcher looks on a timer.
// From native/sw_sys.c.

#[cfg(target_os = "linux")]
mod imp {
    use std::ffi::CString;

    /// A handle for add and wait, or -1. From here on this process ends
    /// when the one that started it does: a watcher nobody reads is not
    /// left running.
    pub fn open() -> i64 {
        unsafe {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            let fd = libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC);
            if fd < 0 { -1 } else { fd as i64 }
        }
    }

    /// Watches one folder (not the folders in it). 1: watched (a second
    /// time is the same watch); 0: the folder is gone; -1: it cannot be
    /// watched (the system's limit on watches is reached).
    pub fn add(fd: i64, dir: &[u8]) -> i32 {
        if fd < 0 || dir.is_empty() || dir.len() >= 4096 { return -1; }
        let c = match CString::new(dir) { Ok(c) => c, Err(_) => return -1 };
        let mask = libc::IN_CLOSE_WRITE | libc::IN_MODIFY | libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_FROM
            | libc::IN_MOVED_TO | libc::IN_DELETE_SELF | libc::IN_MOVE_SELF | libc::IN_ONLYDIR;
        unsafe {
            if libc::inotify_add_watch(fd as i32, c.as_ptr(), mask) >= 0 { return 1; }
            let e = *libc::__errno_location();
            if e == libc::ENOENT || e == libc::ENOTDIR { 0 } else { -1 }
        }
    }

    /// Waits up to timeout_ms for an event and takes every event that is
    /// waiting. 1: there were events; 0: none came; -1: the handle is no good.
    pub fn wait(fd: i64, timeout_ms: i64) -> i32 {
        if fd < 0 { return -1; }
        let mut p = libc::pollfd { fd: fd as i32, events: libc::POLLIN, revents: 0 };
        let mut r;
        unsafe {
            loop {
                r = libc::poll(&mut p, 1, timeout_ms as i32);
                if !(r < 0 && *libc::__errno_location() == libc::EINTR) { break; }
            }
            if r == 0 { return 0; }
            if r < 0 || (p.revents & (libc::POLLERR | libc::POLLNVAL)) != 0 { return -1; }
            let mut buf = [0u64; 2048];
            while libc::read(fd as i32, buf.as_mut_ptr() as *mut libc::c_void, 16384) > 0 {}
        }
        1
    }
}

#[cfg(not(target_os = "linux"))]
mod imp {
    pub fn open() -> i64 { -1 }
    pub fn add(_fd: i64, _dir: &[u8]) -> i32 { -1 }
    pub fn wait(_fd: i64, _timeout_ms: i64) -> i32 { -1 }
}

pub use imp::*;
