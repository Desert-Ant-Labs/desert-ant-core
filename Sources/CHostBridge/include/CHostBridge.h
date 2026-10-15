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
// java.text.Normalizer, so the Swift core links no ICU (see TextNormalization's
// AndroidNormalization.swift for why). Returns a malloc'd,
// NUL-terminated UTF-8 string the caller frees with host_free; NULL means "not
// installed / failed", which the caller treats as "leave the text unchanged".
typedef char *(*HostNormalizeFn)(const char *text);
void host_set_normalize(HostNormalizeFn fn);
char *host_normalize(const char *text);

// HTTP (Android): the host performs the request off the pure-Swift library.
// tree GETs the Hub tree API and returns a malloc'd listing, one file per line
// as "path\tsize\tsha256" (empty sha256 for non-LFS files), NULL on failure.
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

// Generic HTTP request (Android): the host performs `method url` with an optional
// body, content type and headers, returning a malloc'd buffer laid out as:
//   4-byte big-endian status, 4-byte big-endian body length, body bytes, then
//   the Retry-After value (empty when absent), NUL-terminated.
// Returns NULL on transport failure. `body`/`content_type`/`headers` may be
// NULL; `headers` is "Name: value" lines separated by '\n'.
typedef char *(*HostHttpRequestFn)(const char *method, const char *url,
                                   const uint8_t *body, int32_t body_len,
                                   const char *content_type, const char *headers);
void host_set_http_request(HostHttpRequestFn fn);
char *host_http_request(const char *method, const char *url,
                        const uint8_t *body, int32_t body_len,
                        const char *content_type, const char *headers);

// Preferences (Android): the host persists small string values keyed by name,
// backed by SharedPreferences. get returns a malloc'd value string (NULL if
// absent or no host); set stores value under key. Used for the install id and stored licenses.
typedef char *(*HostPrefsGetFn)(const char *key);
void host_set_prefs_get(HostPrefsGetFn fn);
char *host_prefs_get(const char *key);

typedef void (*HostPrefsSetFn)(const char *key, const char *value);
void host_set_prefs_set(HostPrefsSetFn fn);
void host_prefs_set(const char *key, const char *value);

// App identity (Android): the host returns its package name (context.packageName)
// as a malloc'd string (NULL if unset). Sent as the license grant's app id.
typedef char *(*HostAppIdFn)(void);
void host_set_app_id(HostAppIdFn fn);
char *host_app_id(void);

// API key (Android): the key the host app set in code (Kotlin's
// DesertAnt.apiKey), as a malloc'd string, empty when unset (NULL if not
// installed). Read on each license request.
typedef char *(*HostApiKeyFn)(void);
void host_set_api_key(HostApiKeyFn fn);
char *host_api_key(void);

// Audio decode (Android / hosts with no in-process audio decoder): the host
// decodes the file at `path` (or, when `path` is NULL, the `byte_count` bytes at
// `bytes`) to mono PCM at `target_sample_rate`, mixing channels down and
// resampling as needed. It returns a malloc'd, length-prefixed FFI buffer the
// caller frees with host_free: a big-endian uint32 body length, then a uint32
// sample rate, then a float32 array (uint32 count, then that many big-endian
// floats). NULL means "not installed / decode failed".
typedef char *(*HostAudioDecodeFn)(const char *path, const unsigned char *bytes,
                                   int64_t byte_count, double target_sample_rate);
void host_set_audio_decode(HostAudioDecodeFn fn);
char *host_audio_decode(const char *path, const unsigned char *bytes,
                        int64_t byte_count, double target_sample_rate);

// License signature (Android): 1 when an ES256 R||S signature verifies against an X9.63 P-256 key, 0 when not, -1 with no host.
typedef int32_t (*HostLicenseVerifyFn)(const uint8_t *signature, int32_t signature_len,
                                       const uint8_t *message, int32_t message_len,
                                       const uint8_t *public_key, int32_t public_key_len);
void host_set_license_verify(HostLicenseVerifyFn fn);
int32_t host_license_verify(const uint8_t *signature, int32_t signature_len,
                            const uint8_t *message, int32_t message_len,
                            const uint8_t *public_key, int32_t public_key_len);

void host_free(char *ptr);

#ifdef __cplusplus
}
#endif
