/* Spread-Wings' native helpers: what Goose's os module leaves out. Goose
   passes a string as a slice and a growable buffer as a gs_rref. */
#include "goose.h"
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } sw_slice;

static bool to_cstr(sw_slice s, char *buf, size_t size) {
    if (s.len <= 0 || (size_t)s.len >= size) return false;
    memcpy(buf, s.data, (size_t)s.len);
    buf[s.len] = 0;
    return true;
}

/* True when the path itself is a symbolic link (lstat: not followed). Goose's
   is_dir follows links, so the walk needs this to stay inside the repo. */
bool sw_is_symlink(sw_slice path) {
    char buf[4096];
    struct stat st;
    return to_cstr(path, buf, sizeof buf) && lstat(buf, &st) == 0 && S_ISLNK(st.st_mode);
}

/* An absolute, symlink-free path, appended to out. */
bool sw_realpath(sw_slice path, gs_rref out) {
    char in[4096], res[PATH_MAX];
    if (!to_cstr(path, in, sizeof in) || !realpath(in, res)) return false;
    gs_bld_append(out, res, strlen(res));
    return true;
}

/* When the file was last modified, in ns since the epoch; -1 if it cannot be
   read. The compiler step compares it with the time a Swan map was built. */
int64_t sw_mtime_ns(sw_slice path) {
    char buf[4096];
    struct stat st;
    if (!to_cstr(path, buf, sizeof buf) || stat(buf, &st) != 0) return -1;
    return (int64_t)st.st_mtim.tv_sec * 1000000000LL + (int64_t)st.st_mtim.tv_nsec;
}

/* When the file's inode last changed (a write, a rename onto it, a restore
   that keeps the old mtime), in ns since the epoch, and its size in bytes;
   -1 if it cannot be read. With the mtime, what `update` compares before it
   reads a file again. */
int64_t sw_ctime_ns(sw_slice path) {
    char buf[4096];
    struct stat st;
    if (!to_cstr(path, buf, sizeof buf) || stat(buf, &st) != 0) return -1;
    return (int64_t)st.st_ctim.tv_sec * 1000000000LL + (int64_t)st.st_ctim.tv_nsec;
}

int64_t sw_file_size(sw_slice path) {
    char buf[4096];
    struct stat st;
    if (!to_cstr(path, buf, sizeof buf) || stat(buf, &st) != 0) return -1;
    return (int64_t)st.st_size;
}

/* Whether an environment variable is set and not empty. The decision step
   asks this about its API key: the key itself is only ever read by the HTTP
   helper, in C, so it never sits in a Goose buffer. */
bool sw_env_set(sw_slice name) {
    char buf[256];
    if (!to_cstr(name, buf, sizeof buf)) return false;
    const char *v = getenv(buf);
    return v && *v;
}

/* mkdir -p, for the decision cache. */
#include <errno.h>
#include <sys/types.h>
bool sw_mkdirs(sw_slice path) {
    char buf[4096];
    if (!to_cstr(path, buf, sizeof buf)) return false;
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') { *p = 0; if (mkdir(buf, 0700) != 0 && errno != EEXIST) return false; *p = '/'; }
    }
    return mkdir(buf, 0700) == 0 || errno == EEXIST;
}

/* The watcher's wake-up: file events on the folders it was given, so that
   it sleeps until something under one of them is written, made, moved or
   removed. Only a wake-up: what changed is found by `update`, which looks
   at every file, so an event lost or one too many costs nothing but a
   look. Linux (inotify); elsewhere sw_watch_open says -1 and the watcher
   looks on a timer. */
#ifdef __linux__
#include <poll.h>
#include <signal.h>
#include <sys/inotify.h>
#include <sys/prctl.h>
#include <unistd.h>

/* A handle for sw_watch_add and sw_watch_wait, or -1. From here on this
   process ends when the one that started it does: a watcher nobody reads
   is not left running. */
int64_t sw_watch_open(void) {
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    return fd < 0 ? -1 : fd;
}

/* Watches one folder (not the folders in it). 1: watched (a second time
   is the same watch); 0: the folder is gone; -1: it cannot be watched (the
   system's limit on watches is reached). */
int32_t sw_watch_add(int64_t fd, sw_slice dir) {
    char buf[4096];
    if (fd < 0 || !to_cstr(dir, buf, sizeof buf)) return -1;
    if (inotify_add_watch((int)fd, buf, IN_CLOSE_WRITE | IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM |
                          IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR) >= 0) return 1;
    return (errno == ENOENT || errno == ENOTDIR) ? 0 : -1;
}

/* Waits up to timeout_ms for an event and takes every event that is
   waiting. 1: there were events; 0: none came; -1: the handle is no good. */
int32_t sw_watch_wait(int64_t fd, int64_t timeout_ms) {
    if (fd < 0) return -1;
    struct pollfd p = { .fd = (int)fd, .events = POLLIN };
    int r;
    do { r = poll(&p, 1, (int)timeout_ms); } while (r < 0 && errno == EINTR);
    if (r == 0) return 0;
    if (r < 0 || (p.revents & (POLLERR | POLLNVAL))) return -1;
    union { char bytes[16384]; struct inotify_event align; } buf;
    while (read((int)fd, buf.bytes, sizeof buf.bytes) > 0) { }
    return 1;
}
#else
int64_t sw_watch_open(void) { return -1; }
int32_t sw_watch_add(int64_t fd, sw_slice dir) { (void)fd; (void)dir; return -1; }
int32_t sw_watch_wait(int64_t fd, int64_t timeout_ms) { (void)fd; (void)timeout_ms; return -1; }
#endif
