#if os(macOS)  // File Provider extension — macOS-only (FileProvider framework)
import Foundation

// The Mach-O entry point for this extension is overridden to `_NSExtensionMain`
// by a linker flag in Package.swift (`-e _NSExtensionMain`) — the same entry
// Xcode uses for app extensions.
//
// Why not just call NSExtensionMain() from here? Because ExtensionFoundation
// *re-invokes the binary's entry point* to run the extension's second phase
// (instantiating NSExtensionPrincipalClass). That entry point must BE
// NSExtensionMain, which is re-entrant and dispatches correctly on the second
// call. If the entry is a Swift main() that unconditionally calls
// NSExtensionMain(), every re-invocation starts phase one over again and the
// process recurses until the stack overflows (SIGSEGV — observed exactly that).
//
// This file exists only so SwiftPM treats the target as an executable; the
// linker flag makes its main() dead code. Keep a reference so _NSExtensionMain
// is guaranteed linked.
@_silgen_name("NSExtensionMain")
func _nsExtensionMain() -> Int32

_ = _nsExtensionMain
#endif  // os(macOS)

