#ifndef RENDERER_PACKAGE_MOVE_H
#define RENDERER_PACKAGE_MOVE_H

/// Atomically moves `source` to an absent `destination`. This never falls back
/// to replacement semantics: unsupported platforms report `ENOTSUP`.
int renderer_package_move_no_replace(const char *source, const char *destination);

#endif
