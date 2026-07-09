#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Generic host-callback bridge. On platforms with no in-process regex/JSON
// available to a pure-Swift library (e.g. Android, where linking Foundation is
// too heavy), the runtime installs callbacks that delegate to the host's own
// facilities (java.util.regex, the platform JSON parser). Regex and
// JSON call these; a runtime shim (e.g. a JNI layer) sets them. Each
// returns a malloc'd buffer the caller frees with host_free (NULL on failure).
//
// This target is model-agnostic and reusable across projects.

// Regex: newline-separated matches, each "g0s,g0e;g1s,g1e;..." of UTF-16 group
// offsets ("-1,-1" for an unmatched group). NUL-terminated text.
typedef char *(*HostRegexMatchesFn)(const char *pattern, int32_t case_insensitive,
                                    const char *text, int32_t first_only);
void host_set_regex_matches(HostRegexMatchesFn fn);
char *host_regex_matches(const char *pattern, int32_t case_insensitive,
                         const char *text, int32_t first_only);

// JSON: parse a JSON document into the length-prefixed binary value tree that
// JSON decodes (big-endian uint32 payload length, then the tree).
typedef char *(*HostJSONParseFn)(const char *json);
void host_set_json_parse(HostJSONParseFn fn);
char *host_json_parse(const char *json);

void host_free(char *ptr);

#ifdef __cplusplus
}
#endif
