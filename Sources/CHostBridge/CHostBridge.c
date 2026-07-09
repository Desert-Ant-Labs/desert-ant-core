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

static HostHttpTreeFn g_http_tree = 0;
static HostHttpDownloadFn g_http_download = 0;

void host_set_http_tree(HostHttpTreeFn fn) { g_http_tree = fn; }
char *host_http_tree(const char *url) { return g_http_tree ? g_http_tree(url) : 0; }

void host_set_http_download(HostHttpDownloadFn fn) { g_http_download = fn; }
int32_t host_http_download(const char *url, const char *dest_path) {
    return g_http_download ? g_http_download(url, dest_path) : -1;
}

void host_free(char *ptr) { free(ptr); }
