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

void host_free(char *ptr) { free(ptr); }
