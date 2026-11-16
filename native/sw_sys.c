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
