---
description: When and how to use lldb to debug macOS app deaths that leave no crash report — silent exits, uncatchable C++/abort paths, LaunchServices-only failures. Use before log-grepping yourself into a hole.
---

# Debugging silent app deaths with lldb

A playbook for the class of failure that `os_log` and crash reports are
**structurally blind to**: the app quits and you can't see why. The 2026-06-30
launch crash (MLX couldn't load its metallib and the C++ default error handler
called `exit()`) cost hours of log-grepping and rebuild-and-guess cycles before
`lldb` produced the answer in one attached stack. This skill exists so that
doesn't happen again.

> **If the process exits "cleanly" (no `.ips`, no signal), reach for `lldb`
> before you reach for another rebuild.** The debugger is the only tool that
> sees a deliberate `exit()` / `abort()` / return-from-main.

## The decision: os_log vs crash report vs lldb

| Signal you have | Right tool |
| --- | --- |
| A `.ips` in `~/Library/Logs/DiagnosticReports/` | Read it — it has the crashing thread's stack. |
| A signal death (SIGSEGV/SIGABRT) but no `.ips` yet | `log show` + re-run; a `.ips` usually lands seconds later. |
| App "just closes", exit code (e.g. `255`), **no `.ips`** | **`lldb`.** This is a deliberate `exit()`/`abort()`/return-from-main — logs will never tell you where. |
| A crash deep in a C/C++ third-party lib | **`lldb`** + read upward through the frames. |

The trap: when you have *no crash report*, you start reasoning from log
timestamps and process liveness polls. That is inference, not observation. A
debugger gives you the **stack at the moment of death** — a fact, not a guess.

## When to suspect a "silent exit" (reach for lldb immediately)

- The app quits with a numeric exit code and **no new `.ips`** appears in
  DiagnosticReports.
- A failure reproduces only when launched via LaunchServices (`open …`) or only
  from `/Applications`, but not when you run the binary directly.
- You use a C/C++ dependency (MLX, onnxruntime, a static lib, a C error handler)
  that may install its own fatal handler.
- `log show` shows the process alive and doing normal work, then simply
  vanishes mid-operation with no error line.
- An exception is logged but the stack is missing / redacted / "outside of its CU".

```sh
# Confirm there is no crash report for this run — if empty, it's a clean exit.
ls -lt ~/Library/Logs/DiagnosticReports/ | grep -i "<App Name>" | head
```

## Procedure

### 1. Attach to the LaunchServices-launched process (don't run the binary under lldb)

Binary-direct often **does not reproduce** the bug. LaunchServices launches add
state restoration, the real bundle/sandbox context, and (as in the MLX case) a
different resource-resolution path. So you must debug the `open`-launched
process, not the binary.

Use **wait-for attach** so lldb grabs the process the instant it appears, before
it runs:

```sh
# Background: lldb waits for a process named "Self Driving Wiki" to spawn, then
# attaches (suspended). Output to a file so you can read it non-interactively.
nohup lldb \
  -o "process attach -n 'Self Driving Wiki' -w" \
  -o "<breakpoints…>" \
  -o "continue" \
  -o "process status" \
  -o "bt" \
  -o "thread backtrace all" \
  -o "quit" \
  > tmp/lldb_out.txt 2>&1 &

sleep 2                         # let lldb arm the wait-for attach
open "/Applications/Self Driving Wiki.app"   # now launch the way the bug reproduces
```

`-w` / `--waitfor` is the key flag: it blocks until the named process appears,
then attaches suspended. You set breakpoints next, then `continue`.

### 2. Set PRECISE termination breakpoints (the substring trap)

The instinct is `breakpoint set -n exit`. **That matches any symbol whose
basename is `exit`**, including C++ methods like `Security::CountingMutex::exit()`
inside the Keychain — a false positive that stops you in unrelated code and
wastes a run. Scope the breakpoint to the C library:

```sh
# GOOD — scoped to libsystem_c so "exit" can't match CountingMutex::exit etc.
breakpoint set -n exit -n _exit -n abort -n __assert_rtn --shlib libsystem_c.dylib
```

Or use an anchored regex: `breakpoint set -r '^exit$|^_exit$|^abort$'`.

Add the ones relevant to the failure class:
- Swift fatal path: `-n swift_runtime_on_report`
- Obj-C exceptions: `-n objc_exception_throw`
- NSApplication termination: `-n '-[NSApplication terminate:]'`
- C++ throws: `-n __cxa_throw` (note: MLX/Boost-style libs throw a *lot*; noisy)
- TLS/cleanup: `__cxa_throw` if you suspect a C++ exception unwinding to `abort`

### 3. Capture the stop, then read the stack

After `continue`, when a breakpoint hits, dump the stop reason + the stack:

```
process status      # stop reason = breakpoint N.M (which symbol) — THIS is the answer
bt                  # current thread
thread backtrace all# every thread — the death is often on a worker, not main
```

Read **upward** from `exit`/`abort`. In the MLX case the frames were the whole
answer:

```
frame #0  libsystem_c.dylib`exit
frame #1  mlx_error_handler_default_(msg="Failed to load the default metallib. …")
frame #2  _mlx_error("Failed to load the default metallib …")
frame #3  mlx_default_gpu_stream_new()        ← MLX one-time GPU init
frame #4  one-time initialization function for gpu()  ← dispatch_once
frame #5  libdispatch _dispatch_client_callout
frame #6  libdispatch _dispatch_once_callout
```

That single stack ended the investigation: it was MLX's metallib lookup failing
inside a `dispatch_once`, calling the C++ default error handler, which `exit()`s.

### 4. If nothing hits, the process may exit via an unbroken path

After `continue`, if lldb returns because the process exited on its own (no
breakpoint), `process status` reports the exit reason/status. Re-arm with a
broader net: add `_Exit`, `__stack_chk_fail`, `os_crash`, `-[NSApplication
_terminate:]`, or break on the specific suspected frame (e.g. the lib's
error-handler symbol you saw in docs).

## Gotchas & less-obvious points

- **`lldb quit` kills the attached process.** When you `quit`, lldb detaches
  and terminates the debuggee by default. So a breakpoint stop is your
  evidence-capture moment — run `bt`/`thread backtrace all` (and `frame
  variable` / `po` anything you need) *before* quitting. Don't quit hoping to
  re-continue into a later state without capturing first.
- **Breakpoint `-n` matches by basename, including C++ methods.** Always scope
  with `--shlib` or use `-r '^name$'`. The `CountingMutex::exit()` false
  positive stopped us inside `SecItemCopyMatching` (Keychain) — looked like a
  real lead but was noise.
- **The death is frequently on a worker thread, not main.** A detached
  `Task`/queue that calls `exit()` won't show in `bt` (main thread only). Use
  `thread backtrace all`. In the MLX case the exit was on thread "Task 7",
  `com.apple.root.utility-qos.cooperative`.
- **Stripped/release builds emit `GetDIE … outside of its CU` warnings and skip
  some symbols.** The raw addresses + shlib names are still enough to identify
  the call site (e.g. `mlx_default_gpu_stream_new() at stream.cpp:115`). For
  full symbols, build a debug configuration.
- **Attaching changes timing (Heisenberg).** A race may fail to reproduce under
  the debugger, or reproduce differently. If attach-on-launch masks the bug,
  try `attach -p <pid>` *after* launch (you'll race the ~few-second window
  before death), or move the triggering action to after attach.
- **`DYLD_*` env vars and some injections are stripped under Hardened Runtime.**
  If you need to set env for the debuggee, the app must not have Hardened
  Runtime with the relevant restrictions, or you set it before `open` in the
  shell. (Self Driving Wiki's app entitlements do not enable the sandbox, so
  this is rarely a blocker here.)
- **Debugging apps in `/Applications`:** a self-built, developer-signed app is
  debuggable as-is. Apple-shipped/protected binaries may need SIP adjustments;
  not our case.
- **The `open -W` liveness poll lies.** `open -W` returns the app's exit status
  but a clean `exit(0)`-style termination looks like success. Poll
  `pgrep -f "<app>/Contents/MacOS/<binary>"` instead to see if the process is
  actually alive, and remember a windowless app can be **auto-terminated** by
  macOS (`AutomaticTermination … No windows open yet` in the log) — that's a
  *symptom* of "window never opened", not the root cause. lldb tells you why
  the window never opened.
- **"Restoring windows" ≠ crash.** LaunchServices does state restoration; logs
  showing `Restoring windows` are normal launch activity, not the fault. Don't
  chase them.
- **`os_log` shows what your code logs; it does not see C/C++ library internals
  or the act of exiting.** A third-party lib's `exit()` is silent in Console.
  That's the whole reason this skill exists.

## The uncatchable-exit class of bug (C/C++ default error handlers)

Some dependencies install a **default** error handler that calls `exit()` /
`abort()` *before* any Swift `do/catch` can intervene. mlx-swift is the
canonical example: its catchable handler is installed **lazily** — only on the
first `withError` / `setErrorHandler` call — so if a failure happens during a
`dispatch_once` one-time init before that, the C++ default handler runs and the
process dies with no report.

Pattern to recognize and fix:
1. **Recognize:** stack shows `exit`/`abort` directly under a `<lib>_error` /
   `<lib>_default_handler` symbol, with no Swift frame between you and the exit.
2. **Find the lib's "install handler" API** (docs or headers): e.g. mlx-swift's
   `withError { … }` / `setErrorHandler`, or a C `set_error_handler(fn)`.
3. **Route the dangerous call through it** so the failure becomes a Swift
   `throw` you can catch and degrade from, instead of `exit()`. For MLX, wrap
   model construction in `try await withError { try await build() }`.

This turns an invisible, uncatchable process death into a handled, logged
fallback. Whenever you adopt a C/C++ dependency that does GPU/native work,
check whether it has a default fatal handler and install the catchable one at
launch.

## Anti-patterns to avoid

- Log-grepping and rebuilding in circles when there is **no crash report**. A
  clean `exit()` is invisible to logs by definition — attach a debugger.
- Running the binary under `lldb` when the bug reproduces only via `open` /
  `/Applications`. You'll debug a different code path and "fix" nothing.
- `breakpoint set -n exit` unscoped — it stops on `CountingMutex::exit()` and
  other noise; always `--shlib libsystem_c.dylib` or anchor with `-r`.
- Quitting lldb before dumping the stack. The attached process dies on `quit`.
- Trusting `open -W`'s exit code or a single liveness poll as the verdict; the
  failure is often intermittent (race/auto-termination). Confirm with the
  debugger's stop reason.
- Treating macOS auto-termination ("No windows open yet") as the root cause —
  it's a *consequence* of the window never appearing; keep digging for why.
