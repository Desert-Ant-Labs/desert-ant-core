// Linked into every Linux Node native in place of a link against libcurl. Each
// libcurl call the static FoundationNetworking makes lands here, and is
// forwarded to the host's libcurl.so.4, which this opens itself on first use.
// A definition in an object file wins over a shared library's, and the build
// hands the linker an empty script in place of libcurl, so the .so records no
// DT_NEEDED on it at all.
//
// It exists for two reasons.
//
// Symbol binding. Official Node builds link OpenSSL 3 statically and export
// its symbols. On a host whose libcurl uses OpenSSL 1.1 (Ubuntu 20.04), a
// libcurl loaded as a plain dependency binds libssl's libcrypto references to
// Node's OpenSSL 3, and the first HTTPS request segfaults. RTLD_DEEPBIND makes
// libcurl and the libraries it brings resolve against each other first.
//
// Version skew. The Amazon Linux 2 Swift image compiled FoundationNetworking
// against libcurl 8, and corelibs-foundation picks features by the headers it
// compiled against, not the libcurl it runs on:
//   * curl_ws_* (7.86), for WebSockets, which a direct import would make a
//     load-time requirement;
//   * CURLINFO_CAINFO (7.84), queried under `try!` before every request, so an
//     older libcurl's CURLE_UNKNOWN_OPTION crashes the first download.
// Ubuntu 20.04 and 22.04 and Debian 11 ship libcurl 7.68 to 7.81.
//
// The prototypes are restated rather than taken from curl/curl.h, so this
// builds against any libcurl headers or none. Every enum is passed as int.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define DAL_HIDDEN __attribute__((visibility("hidden")))

enum { CURLE_OK = 0, CURLE_NOT_BUILT_IN = 4 };
enum { CURLINFO_STRING = 0x100000, CURLINFO_CAINFO = CURLINFO_STRING + 61 };
typedef int64_t curl_off_t;

static void *libcurl;
// dlerror() is per thread and cleared by reading, so the reason is kept here
// for whichever thread reports it.
static char libcurl_error[256];
static pthread_once_t libcurl_once = PTHREAD_ONCE_INIT;

static void open_libcurl(void) {
  libcurl = dlopen("libcurl.so.4", RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
  if (!libcurl) {
    const char *why = dlerror();
    snprintf(libcurl_error, sizeof libcurl_error, "%s", why ? why : "unknown");
  }
}

// The Node loader calls this before binding anything else and throws a
// catchable error when it returns 0, so the abort in curl_sym is only a
// backstop for a caller that skipped the check.
__attribute__((visibility("default"))) int dal_curl_available(void) {
  pthread_once(&libcurl_once, open_libcurl);
  return libcurl != NULL;
}

static void *curl_sym(const char *name, int required) {
  if (!dal_curl_available()) {
    fprintf(stderr,
            "desert-ant: cannot load libcurl.so.4 (%s). libcurl is required "
            "(downloads and usage reporting); install libcurl4, or libcurl on "
            "Fedora and Amazon Linux.\n",
            libcurl_error);
    abort();
  }
  void *fn = dlsym(libcurl, name);
  if (!fn && required) {
    fprintf(stderr, "desert-ant: libcurl.so.4 has no %s\n", name);
    abort();
  }
  return fn;
}

// Resolves once per function; a racing second lookup stores the same pointer.
#define REAL(ret, name, params)                                      \
  static ret(*real) params;                                          \
  if (!__atomic_load_n(&real, __ATOMIC_ACQUIRE))                     \
    __atomic_store_n(&real, (ret(*) params)curl_sym(#name, 1),       \
                     __ATOMIC_RELEASE)

#define FORWARD(ret, name, params, args) \
  DAL_HIDDEN ret name params {           \
    REAL(ret, name, params);             \
    return real args;                    \
  }

FORWARD(int, curl_global_init, (long flags), (flags))
FORWARD(char *, curl_version, (void), ())
FORWARD(void *, curl_version_info, (int age), (age))
FORWARD(void, curl_free, (void *p), (p))
FORWARD(void *, curl_slist_append, (void *list, const char *s), (list, s))
FORWARD(void, curl_slist_free_all, (void *list), (list))
FORWARD(void *, curl_url, (void), ())
FORWARD(int, curl_url_get, (void *u, int part, char **out, unsigned flags),
        (u, part, out, flags))
FORWARD(int, curl_url_set, (void *u, int part, const char *s, unsigned flags),
        (u, part, s, flags))
FORWARD(void *, curl_easy_init, (void), ())
FORWARD(void, curl_easy_cleanup, (void *curl), (curl))
FORWARD(int, curl_easy_pause, (void *curl, int mask), (curl, mask))
FORWARD(const char *, curl_easy_strerror, (int code), (code))
FORWARD(void *, curl_multi_init, (void), ())
FORWARD(int, curl_multi_cleanup, (void *multi), (multi))
FORWARD(int, curl_multi_add_handle, (void *multi, void *curl), (multi, curl))
FORWARD(int, curl_multi_remove_handle, (void *multi, void *curl),
        (multi, curl))
FORWARD(int, curl_multi_assign, (void *multi, int fd, void *p),
        (multi, fd, p))
FORWARD(void *, curl_multi_info_read, (void *multi, int *left), (multi, left))
FORWARD(int, curl_multi_socket_action,
        (void *multi, int fd, int mask, int *running),
        (multi, fd, mask, running))

// The variadic three take exactly one argument after the option: a long, a
// pointer or a curl_off_t, all one 64-bit integer-class slot on x86_64 and
// arm64, so reading it as a pointer and passing it on is lossless.
#define FORWARD_VARIADIC(name)                     \
  DAL_HIDDEN int name(void *h, int opt, ...) {     \
    REAL(int, name, (void *, int, ...));           \
    va_list ap;                                    \
    va_start(ap, opt);                             \
    void *arg = va_arg(ap, void *);                \
    va_end(ap);                                    \
    return real(h, opt, arg);                      \
  }

FORWARD_VARIADIC(curl_easy_setopt)
FORWARD_VARIADIC(curl_multi_setopt)

// A libcurl older than 7.84 rejects CURLINFO_CAINFO. Answering "no default
// bundle" makes Foundation look in the usual paths, which is what it does when
// built against that libcurl.
DAL_HIDDEN int curl_easy_getinfo(void *curl, int info, ...) {
  REAL(int, curl_easy_getinfo, (void *, int, ...));
  va_list ap;
  va_start(ap, info);
  void *out = va_arg(ap, void *);
  va_end(ap);
  int rc = real(curl, info, out);
  if (rc != CURLE_OK && info == CURLINFO_CAINFO && out) {
    *(char **)out = NULL;
    return CURLE_OK;
  }
  return rc;
}

// Nothing in the SDK opens a WebSocket, so on a libcurl without these they
// answer CURLE_NOT_BUILT_IN and are never reached in practice.
struct curl_ws_frame;

DAL_HIDDEN int curl_ws_recv(void *curl, void *buf, size_t len, size_t *got,
                            const struct curl_ws_frame **meta) {
  int (*real)(void *, void *, size_t, size_t *, const struct curl_ws_frame **) =
      curl_sym("curl_ws_recv", 0);
  return real ? real(curl, buf, len, got, meta) : CURLE_NOT_BUILT_IN;
}

DAL_HIDDEN int curl_ws_send(void *curl, const void *buf, size_t len,
                            size_t *sent, curl_off_t fragsize, unsigned flags) {
  int (*real)(void *, const void *, size_t, size_t *, curl_off_t, unsigned) =
      curl_sym("curl_ws_send", 0);
  return real ? real(curl, buf, len, sent, fragsize, flags)
              : CURLE_NOT_BUILT_IN;
}

DAL_HIDDEN const struct curl_ws_frame *curl_ws_meta(void *curl) {
  const struct curl_ws_frame *(*real)(void *) = curl_sym("curl_ws_meta", 0);
  return real ? real(curl) : NULL;
}
