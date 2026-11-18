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
