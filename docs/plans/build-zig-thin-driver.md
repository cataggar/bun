# Plan: Replace `build.ts` with `build.zig` (thin driver)

## Goal & scope
Replace Bun's WebKit dev-facing build driver `build.ts` with a `build.zig` that
**orchestrates the existing CMake/Ninja build** — same flags, same two-phase
`cmake configure` → `cmake --build --target jsc`. No change to the WebKit CMake
graph, code generation, or derived sources. Net behavior parity, invoked as
`zig build` instead of `bun build.ts`.

## What `build.ts` does today (parity checklist)
Source: `oven-sh/WebKit:build.ts` (303 lines). The replacement must reproduce:

1. **Config arg**: `debug` | `release` | `lto` (default `debug`); validate & error.
2. **Platform/arch detection**: mac / linux / windows; arm64 vs x64 (Windows uses
   `PROCESSOR_ARCHITECTURE`).
3. **Tool detection**:
   - C/C++ compiler: `clang-21`/`clang`, `clang++-21`/`clang++`; `clang-cl` on Windows.
   - `ccache` → set `CMAKE_C/CXX_COMPILER_LAUNCHER`, keep base compiler in `CMAKE_C/CXX_COMPILER`.
   - `lld-link` on Windows.
4. **Common CMake flags**: `-DPORT=JSCOnly -DENABLE_STATIC_JSC=ON
   -DALLOW_LINE_AND_COLUMN_NUMBER_IN_BUILTINS=ON -DUSE_THIN_ARCHIVES=OFF
   -DUSE_BUN_JSC_ADDITIONS=ON -DUSE_BUN_EVENT_LOOP=ON -DENABLE_FTL_JIT=ON
   -DENABLE_MEDIA_SOURCE=OFF -DENABLE_MEDIA_STREAM=OFF -DENABLE_WEB_RTC=OFF -G Ninja`.
5. **Per-config flags**:
   - `debug`: `CMAKE_BUILD_TYPE=Debug`, `ENABLE_BUN_SKIP_FAILING_ASSERTIONS=ON`,
     `CMAKE_EXPORT_COMPILE_COMMANDS=ON`, `ENABLE_REMOTE_INSPECTOR=ON`,
     `USE_VISIBILITY_ATTRIBUTE=1`, asan (`ENABLE_SANITIZERS=address`) on mac/linux,
     `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebug` on Windows.
   - `release`: `CMAKE_BUILD_TYPE=RelWithDebInfo` (+ MSVC `MultiThreaded`).
   - `lto`: `CMAKE_BUILD_TYPE=Release` + `-flto=full` in C/CXX flags (+ MSVC `MultiThreaded`).
6. **Windows ICU (vcpkg static)**: auto-pick `arm64-windows-static` else
   `x64-windows-static`; debug uses `d`-suffixed libs (`sicudtd/sicuind/sicuucd`);
   set `ICU_ROOT/ICU_LIBRARY/ICU_INCLUDE_DIR/ICU_*_LIBRARY_RELEASE`,
   `/DU_STATIC_IMPLEMENTATION`, `/clang:-fno-c++-static-destructors`, `CMAKE_LINKER=lld-link`.
7. **Env**: mac sets `ICU_INCLUDE_DIRS=$HOMEBREW_PREFIX/opt/icu4c/include`.
8. **Build dirs**: `WebKitBuild/{Debug,Release,ReleaseLTO}`; create if missing.
9. **Run**: `cmake [flags] <srcDir> <buildDir>` then
   `cmake --build <buildDir> --config <Debug|Release|RelWithDebInfo> --target jsc`,
   streaming stdio, propagate non-zero exit codes.

## Design of `build.zig`
- Target Zig: pin a known-good version (e.g. 0.14.x); document in `.zig-version` / CLAUDE.md.
- `build(b: *std.Build)`:
  - Option: `const config = b.option(Config, "config", "debug|release|lto") orelse .debug;`
    (enum). Keep `-Dconfig=` to mirror `build.ts <arg>`.
  - Host detect: `const host = b.graph.host.result;` → `host.os.tag`, `host.cpu.arch`.
  - Tool discovery via `b.findProgram(&.{...}, &.{})` for clang/clang++/clang-cl,
    ccache, lld-link. Fall back to defaults exactly as `build.ts`.
  - Build the flag list (`std.ArrayList([]const u8)`) replicating sections 4–6.
  - ICU path strings via `b.pathJoin(...)` and `std.fs` existence checks for the
    vcpkg triplet selection.
  - **Two Run steps**:
    - `configure = b.addSystemCommand(&.{ "cmake", ...flags, srcDir, buildDir });`
    - `build_step = b.addSystemCommand(&.{ "cmake", "--build", buildDir,
      "--config", buildType, "--target", "jsc" });`
    - `build_step.step.dependOn(&configure.step);`
  - **Critical gotchas**:
    - Set `has_side_effects = true` on both Run steps so Zig's build cache never
      skips them (CMake/Ninja state lives in `buildDir`, not Zig's hash).
    - `setCwd(b.path(buildDirRel))`; create dir first (a small mkdir step or
      `std.fs.cwd().makePath` in `build()` before adding run steps).
    - `setEnvironmentVariable("ICU_INCLUDE_DIRS", ...)` on mac.
    - Pass space-containing Windows `-DCMAKE_CXX_FLAGS=...` as a single argv item.
    - stdio inherits by default for system commands; ensure errors propagate.
  - Wire to the default step: `b.getInstallStep().dependOn(&build_step.step);` or
    make `build_step` the top-level so `zig build` builds jsc.
  - Optional named steps: `zig build configure`, `zig build jsc` for convenience.

## Call sites & docs to update
- `CLAUDE.md` "Quick Build (TypeScript)" section → `zig build -Dconfig=debug|release|lto`.
- `ReadMe.md` / any onboarding docs that mention `bun build.ts`.
- `.github/` CI workflows that invoke `bun build.ts` (grep before editing).
- Leave the **release scripts** (`mac-release.bash`, `release.sh`, `musl-release.sh`,
  `android-release.sh`, `freebsd-release.sh`) alone initially — they call `cmake`
  directly and do **not** use `build.ts`. (Optional later: route them through
  `build.zig` for single-source-of-truth flags.)

## Validation (parity gate)
1. Add an instrumentation/dry-run mode to both old & new (`--print` of the exact
   `cmake` argv + env + cwd) and **diff them** for the 3 configs × {mac,linux,win}.
   This is the cheapest high-confidence parity check.
2. Real builds: `zig build -Dconfig=debug` and `release` on linux + mac; confirm
   `libJavaScriptCore.a` / `jsc` lands in the same `WebKitBuild/<dir>` as before.
3. Windows build with vcpkg static ICU (CI runner) — verify ICU lib selection &
   `d`-suffix logic.
4. Confirm `compile_commands.json` is emitted in debug (editor tooling depends on it).
5. ccache path: build twice, confirm cache hits and that launcher flags are set.

## Rollout
1. Land `build.zig` alongside `build.ts` (no removal yet).
2. Update docs/CI to call `zig build`; keep `build.ts` one release as fallback.
3. After parity confirmed in CI for all platforms, delete `build.ts`.

## Open questions / decisions
- Pin which Zig version, and whether to vendor it (Bun already ships a Zig
  toolchain — reuse that version for consistency).
- Whether to also unify the release shell scripts through `build.zig` (out of
  scope for "replace build.ts only", but high-value follow-up).
- Behavior when `cmake`/`ninja` absent: emit a clear error (parity with current
  implicit failure).
