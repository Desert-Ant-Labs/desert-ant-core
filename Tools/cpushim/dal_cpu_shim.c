// Supplies the two sysfs files XNNPACK's cpuinfo needs when the kernel's CPU
// tree is not mounted. Preloaded with LD_PRELOAD; does nothing otherwise.
//
// Why this exists. LiteRT's CPU accelerator is XNNPACK, which asks cpuinfo to
// enumerate cores before it builds its thread pool. On ARM there is no
// instruction that answers that, so cpuinfo reads
// /sys/devices/system/cpu/{possible,present}. AWS Lambda's sandbox does not
// mount /sys/devices/system/cpu at all, cpuinfo fails, XNNPACK never
// initializes, and LiteRtCreateCompiledModel fails - inference is dead while
// the library itself loaded fine. x86_64 is unaffected: there cpuinfo uses the
// CPUID instruction and never touches sysfs, which is the whole asymmetry.
//
// Only those two exact paths are answered; every other call goes straight to
// libc. The reply is served from anonymous memory, so no writable filesystem is
// needed and there is nothing to clean up.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static const char kPossible[] = "/sys/devices/system/cpu/possible";
static const char kPresent[] = "/sys/devices/system/cpu/present";

static int wanted(const char *path) {
  return path && (strcmp(path, kPossible) == 0 || strcmp(path, kPresent) == 0);
}

// A read-only fd holding the cpu range sysfs would have reported, e.g. "0-1".
// -1 leaves the caller to the real file, so a host that does mount sysfs is
// never second-guessed on the strength of a failed memfd.
static int cpu_range_fd(void) {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1) n = 1;
  char buf[32];
  int len = (n == 1) ? snprintf(buf, sizeof buf, "0\n")
                     : snprintf(buf, sizeof buf, "0-%ld\n", n - 1);
  int fd = memfd_create("dal-cpu-range", MFD_CLOEXEC);
  if (fd < 0) return -1;
  if (write(fd, buf, len) != len || lseek(fd, 0, SEEK_SET) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

// O_CREAT's mode is variadic; read it only when the flag is set, as libc does.
static mode_t creat_mode(int flags, va_list ap) {
  return (flags & O_CREAT) ? (mode_t)va_arg(ap, int) : 0;
}

int open(const char *path, int flags, ...) {
  static int (*real)(const char *, int, ...);
  if (!real) real = dlsym(RTLD_NEXT, "open");
  if (wanted(path)) {
    int fd = cpu_range_fd();
    if (fd >= 0) return fd;
  }
  va_list ap;
  va_start(ap, flags);
  mode_t mode = creat_mode(flags, ap);
  va_end(ap);
  return real(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
  static int (*real)(const char *, int, ...);
  if (!real) real = dlsym(RTLD_NEXT, "open64");
  if (wanted(path)) {
    int fd = cpu_range_fd();
    if (fd >= 0) return fd;
  }
  va_list ap;
  va_start(ap, flags);
  mode_t mode = creat_mode(flags, ap);
  va_end(ap);
  return real(path, flags, mode);
}

FILE *fopen(const char *path, const char *mode) {
  static FILE *(*real)(const char *, const char *);
  if (!real) real = dlsym(RTLD_NEXT, "fopen");
  if (wanted(path)) {
    int fd = cpu_range_fd();
    if (fd >= 0) return fdopen(fd, "r");
  }
  return real(path, mode);
}

FILE *fopen64(const char *path, const char *mode) {
  static FILE *(*real)(const char *, const char *);
  if (!real) real = dlsym(RTLD_NEXT, "fopen64");
  if (wanted(path)) {
    int fd = cpu_range_fd();
    if (fd >= 0) return fdopen(fd, "r");
  }
  return real(path, mode);
}
