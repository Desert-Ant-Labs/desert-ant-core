#include "include/CHostBridge.h"
#include <stdlib.h>

static HostRegexMatchesFn g_regex_matches = 0;
static HostJSONParseFn g_json_parse = 0;

void host_set_regex_matches(HostRegexMatchesFn fn) { g_regex_matches = fn; }

char *host_regex_matches(const char *pattern, int32_t case_insensitive,
                         const char *text, int32_t first_only) {
    return g_regex_matches ? g_regex_matches(pattern, case_insensitive, text, first_only) : 0;
}

void host_set_json_parse(HostJSONParseFn fn) { g_json_parse = fn; }

char *host_json_parse(const char *json) {
    return g_json_parse ? g_json_parse(json) : 0;
}

static HostNormalizeFn g_normalize = 0;

void host_set_normalize(HostNormalizeFn fn) { g_normalize = fn; }

char *host_normalize(const char *text) {
    return g_normalize ? g_normalize(text) : 0;
}

static HostHttpTreeFn g_http_tree = 0;
static HostHttpDownloadFn g_http_download = 0;

void host_set_http_tree(HostHttpTreeFn fn) { g_http_tree = fn; }
char *host_http_tree(const char *url) { return g_http_tree ? g_http_tree(url) : 0; }

void host_set_http_download(HostHttpDownloadFn fn) { g_http_download = fn; }
int32_t host_http_download(const char *url, const char *dest_path,
                           void *ctx, HostProgressFn progress) {
    return g_http_download ? g_http_download(url, dest_path, ctx, progress) : -1;
}

static HostHttpRequestFn g_http_request = 0;

void host_set_http_request(HostHttpRequestFn fn) { g_http_request = fn; }
char *host_http_request(const char *method, const char *url,
                        const uint8_t *body, int32_t body_len,
                        const char *content_type) {
    return g_http_request ? g_http_request(method, url, body, body_len, content_type) : 0;
}

static HostPrefsGetFn g_prefs_get = 0;
static HostPrefsSetFn g_prefs_set = 0;

void host_set_prefs_get(HostPrefsGetFn fn) { g_prefs_get = fn; }
char *host_prefs_get(const char *key) { return g_prefs_get ? g_prefs_get(key) : 0; }

void host_set_prefs_set(HostPrefsSetFn fn) { g_prefs_set = fn; }
void host_prefs_set(const char *key, const char *value) { if (g_prefs_set) g_prefs_set(key, value); }

static HostAppIdFn g_app_id = 0;

void host_set_app_id(HostAppIdFn fn) { g_app_id = fn; }
char *host_app_id(void) { return g_app_id ? g_app_id() : 0; }

void host_free(char *ptr) { free(ptr); }
