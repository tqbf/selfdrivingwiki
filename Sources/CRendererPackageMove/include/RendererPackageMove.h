#ifndef RENDERER_PACKAGE_MOVE_H
#define RENDERER_PACKAGE_MOVE_H

/// Atomically moves `source` to an absent `destination`. This never falls back
/// to replacement semantics: unsupported platforms report `ENOTSUP`.
int renderer_package_move_no_replace(const char *source, const char *destination);

/// Atomically moves one child between two open directories when the destination
/// child is absent. This preserves the same no-replace contract as the path API.
int renderer_package_move_no_replace_at(
    int source_directory,
    const char *source_name,
    int destination_directory,
    const char *destination_name
);

#endif
