/* TC0090: fail lstat for exactly one test-owned path with EACCES or EBADMSG.
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

int lstat(const char *path, struct stat *info) {
    if (injected(path)) {
        const char *requested = getenv("E2E_TC0090_LSTAT_ERRNO");
        if (requested && strcmp(requested, "EACCES") == 0) {
            errno = EACCES;
            return -1;
        }
        if (requested && strcmp(requested, "EBADMSG") == 0) {
            errno = EBADMSG;
            return -1;
        }
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
