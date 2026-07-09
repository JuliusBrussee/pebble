# 12 — Dedicated Server Console, Signals, and Headless Runtime

## Scope

Files: `Sources/pebserver/main.swift`, `Sources/PebbleCore/Game/GameCore.swift`, `Sources/PebbleCore/Net/`, `Sources/PebbleCore/Game/Saves.swift`.

Goal: make `pebserver` an early Windows validation target: no renderer/window/audio, direct-IP networking, portable console/runtime, clean save-on-exit.

## Current blockers

- Package is macOS-only until module 01.
- Server target graph depends on Apple Network.framework, ambient SQLite3, platform paths, `simd`, and time APIs.
- `pebserver/main.swift` is a top-level script using POSIX signals, `DispatchSource.makeSignalSource`, `readLine`, `RunLoop.main`, and `CFAbsoluteTimeGetCurrent`.
- `GameCore` and transport callbacks assume main queue semantics.

## Target architecture

- Thin `main.swift`: parse CLI, resolve data root, construct services, start controller, return exit code.
- `DedicatedServerController`: owns world selection, lifecycle, listener startup, console commands, shutdown state, `GameCore.frame(dtMs:)` calls.
- One serialized game executor for ticks, commands, network callbacks, chunk adoption, save retry, shutdown.
- Portable adapters: monotonic clock, tick scheduler, console input, console output, shutdown events.
- Direct-IP TCP transport is required; Bonjour remains optional/macOS.

## Plan

1. Baseline current macOS server build/smoke behavior.
2. Add pure CLI parsing: `--help` must not construct `GameCore` or touch storage.
3. Add `--data-dir <path>` and `--port 0`; print `READY port=<actual> world=<id>` after listener ready.
4. Move command parsing to testable `ServerCommand`: list, say, save, stop/exit/quit, help, unknown, empty.
5. Consume persistence/data-root service from module 04.
6. Consume portable network transport from module 05.
7. Add `DedicatedServerController` and centralize shutdown.
8. Replace/inject main-queue assumptions for server-reachable callbacks.
9. Replace wall-clock/run-loop assumptions with monotonic scheduler feeding elapsed ms into `GameCore.frame(dtMs:)`.
10. Add safe shutdown handling: Darwin SIGINT/SIGTERM; Windows console Ctrl-C/Ctrl-Break; no save work inside low-level handlers.
11. Implement console EOF behavior: keep server running with console disabled unless explicit stop is sent.
12. Add process smoke that starts server, waits for READY, connects guest, runs commands, verifies persistence, stops cleanly.

## Verification gates

- `swift build -c release --target pebserver` on macOS and Windows.
- `pebserver --help` exits 0 and creates no files.
- Temp-root server creates/opens world and binds `--port 0`.
- Direct-IP guest joins, appears in `list`, receives `say`, edits block, state persists after `save`/`stop`.
- SIGINT/SIGTERM or Windows Ctrl-C/Ctrl-Break triggers one clean shutdown/save path.
- Fake clock verifies stable 20 TPS through `GameCore.frame`, no second fixed-step loop.
- Server target has no renderer/window/audio dependencies.

## Done criteria

`pebserver` is portable, headless, direct-IP capable, temp-root safe, and stable enough to be a Windows CI/runtime milestone before the graphical client.
