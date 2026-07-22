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

// NFKC normalization (Android): the host normalizes text with its own
// java.text.Normalizer (present since API 1), so the pure-Swift core links no
// ICU (linking the platform libicu would force API 31+, and bundling
// Foundation's ICU would add tens of megabytes). Returns a malloc'd,
// NUL-terminated UTF-8 string the caller frees with host_free; NULL means "not
// installed / failed", which the caller treats as "leave the text unchanged".
typedef char *(*HostNormalizeFn)(const char *text);
void host_set_normalize(HostNormalizeFn fn);
char *host_normalize(const char *text);

// HTTP (Android): the host performs the request off the pure-Swift library.
// tree GETs the Hub tree API and returns a malloc'd listing, one file per line
// as "path\tsize\tsha256" (empty sha256 for non-LFS files), NULL on failure.
// download writes the response body to dest_path and returns 0 / -1.
typedef char *(*HostHttpTreeFn)(const char *url);
void host_set_http_tree(HostHttpTreeFn fn);
char *host_http_tree(const char *url);

// download writes the body to dest_path and returns 0 / -1. For streaming
// progress the host calls `progress(ctx, bytes_written)` with the cumulative
// byte count as it goes (pass a NULL-tolerant progress; ctx is opaque).
typedef void (*HostProgressFn)(void *ctx, int64_t bytes_written);
typedef int32_t (*HostHttpDownloadFn)(const char *url, const char *dest_path,
                                      void *ctx, HostProgressFn progress);
void host_set_http_download(HostHttpDownloadFn fn);
int32_t host_http_download(const char *url, const char *dest_path,
                           void *ctx, HostProgressFn progress);

void host_free(char *ptr);

#ifdef __cplusplus
}
#endif
