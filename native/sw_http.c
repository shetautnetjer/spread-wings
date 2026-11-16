/* HTTPS POST for the decision step, through libcurl. The API key is read
   from the environment here, by name, so it never passes through Goose
   strings, logs or the graph. Thread-safe: each call uses its own handle. */
#include "goose.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *data; int64_t len; } sw_slice;

static pthread_once_t once = PTHREAD_ONCE_INIT;
static void init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

static size_t on_body(char *p, size_t size, size_t n, void *ud) {
    gs_bld_append(*(gs_rref *)ud, p, size * n);
    return size * n;
}

static char *cstr(sw_slice s) {
    char *b = malloc((size_t)s.len + 1);
    if (!b) return NULL;
    memcpy(b, s.data, (size_t)s.len);
    b[s.len] = 0;
    return b;
}

/* POSTs body (JSON) to url with "Authorization: Bearer $<key_env>" and
   appends the response body to out. Returns the HTTP status, or -1 when the
   key is missing or the request could not be made. */
int64_t sw_http_post(sw_slice url, sw_slice key_env, sw_slice body, int64_t timeout_s, gs_rref out) {
    pthread_once(&once, init);
    char *u = cstr(url), *k = cstr(key_env), *b = cstr(body);
    int64_t status = -1;
    const char *key = k ? getenv(k) : NULL;
    if (u && b && key && *key) {
        CURL *c = curl_easy_init();
        if (c) {
            size_t hl = strlen(key) + 32;
            char *auth = malloc(hl);
            if (auth) {
                snprintf(auth, hl, "Authorization: Bearer %s", key);
                struct curl_slist *h = curl_slist_append(NULL, auth);
                h = curl_slist_append(h, "Content-Type: application/json");
                curl_easy_setopt(c, CURLOPT_URL, u);
                curl_easy_setopt(c, CURLOPT_HTTPHEADER, h);
                curl_easy_setopt(c, CURLOPT_POSTFIELDS, b);
                curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)body.len);
                curl_easy_setopt(c, CURLOPT_TIMEOUT, (long)timeout_s);
                curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
                curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
                curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
                if (curl_easy_perform(c) == CURLE_OK) {
                    long code = 0;
                    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
                    status = code;
                }
                curl_slist_free_all(h);
                memset(auth, 0, hl);
                free(auth);
            }
            curl_easy_cleanup(c);
        }
    }
    free(u); free(k); free(b);
    return status;
}
