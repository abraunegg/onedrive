/* TC0090: fail lstat/lstat64 for exactly one test-owned path with EACCES or EBADMSG.
 * No filesystem is modified; this library is loaded only by the subject client.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int injected(const char *path) {
    const char *suffix = getenv("E2E_TC0090_LSTAT_PATH");
    if (!path || !suffix || !*suffix)
        return 0;
    while (path[0] == '.' && path[1] == '/')
        path += 2;
    size_t plen = strlen(path), slen = strlen(suffix);
    return (plen == slen && strcmp(path, suffix) == 0) ||
           (plen > slen && path[plen - slen - 1] == '/' &&
            strcmp(path + plen - slen, suffix) == 0);
}

/* D's glibc runtime may resolve std.file.getLinkAttributes() to lstat64,
 * not lstat. Keep both symbols consistent with the injected error.
 */
static int injected_errno(const char *path) {
    if (!injected(path))
        return 0;
    const char *requested = getenv("E2E_TC0090_LSTAT_ERRNO");
    if (requested && strcmp(requested, "EACCES") == 0)
        return EACCES;
    if (requested && strcmp(requested, "EBADMSG") == 0)
        return EBADMSG;
    return 0;
}

int lstat(const char *path, struct stat *info) {
    int error = injected_errno(path);
    if (error) {
        errno = error;
        return -1;
    }
    static int (*original)(const char *, struct stat *) = NULL;
    if (!original)
        original = dlsym(RTLD_NEXT, "lstat");
    if (!original) {
        errno = ENOSYS;
        return -1;
    }
    return original(path, info);
}

/* glibc large-file ABI used by D Phobos when __USE_LARGEFILE64 is enabled. */
#if defined(__GLIBC__)
int lstat64(const char *path, struct stat64 *info) {
    int error = injected_errno(path);
    if (error) {
        errno = error;
        return -1;
    }
    static int (*original)(const char *, struct stat64 *) = NULL;
    if (!original)
        original = dlsym(RTLD_NEXT, "lstat64");
    if (!original) {
        errno = ENOSYS;
        return -1;
    }
    return original(path, info);
}
#endif
