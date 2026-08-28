#include "RendererPackageMove.h"

#include <errno.h>

// pattern: Imperative Shell

#if defined(__APPLE__)
#include <stdio.h>

int renderer_package_move_no_replace(const char *source, const char *destination) {
    return renamex_np(source, destination, RENAME_EXCL);
}

int renderer_package_move_no_replace_at(
    int source_directory,
    const char *source_name,
    int destination_directory,
    const char *destination_name
) {
    return renameatx_np(
        source_directory,
        source_name,
        destination_directory,
        destination_name,
        RENAME_EXCL
    );
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

int renderer_package_move_no_replace_at(
    int source_directory,
    const char *source_name,
    int destination_directory,
    const char *destination_name
) {
#ifdef SYS_renameat2
    return (int)syscall(
        SYS_renameat2,
        source_directory,
        source_name,
        destination_directory,
        destination_name,
        RENAME_NOREPLACE
    );
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

int renderer_package_move_no_replace_at(
    int source_directory,
    const char *source_name,
    int destination_directory,
    const char *destination_name
) {
    (void)source_directory;
    (void)source_name;
    (void)destination_directory;
    (void)destination_name;
    errno = ENOTSUP;
    return -1;
}
#endif
