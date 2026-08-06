#include "RendererPackageMove.h"

#include <errno.h>

// pattern: Imperative Shell

#if defined(__APPLE__)
#include <stdio.h>

int renderer_package_move_no_replace(const char *source, const char *destination) {
    return renamex_np(source, destination, RENAME_EXCL);
}
#elif defined(__linux__)
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

int renderer_package_move_no_replace(const char *source, const char *destination) {
#ifdef SYS_renameat2
    return (int)syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE);
#else
    errno = ENOTSUP;
    return -1;
#endif
}
#else
int renderer_package_move_no_replace(const char *source, const char *destination) {
    (void)source;
    (void)destination;
    errno = ENOTSUP;
    return -1;
}
#endif
