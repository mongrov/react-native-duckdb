# mongrov/react-native-duckdb — Fork lineage

Downstream fork of
[`pranshuchittora/react-native-duckdb`](https://github.com/pranshuchittora/react-native-duckdb).

License: **MIT**, as declared in `package.json:license` (inherited from
upstream). Original author: Pranshu Chittora.

## Why fork

Upstream `main` (SHA `45033afedb54fd353ad6e8796d4eb1aa0d11ca3c`, 2026-02-22)
is a **bun workspaces monorepo** where the actual npm module lives at
`/package/`. Two consequences make it unusable directly from a pnpm-based
consumer app:

1. The npm-published tarball (`react-native-duckdb@1.0.0`) ships without
   the `/scripts/` directory even though `files:` lists it, so the
   podspec's `bash ../scripts/build-duckdb-ios.sh prepare_command`
   fails on `pod install`. Reproduced downstream in
   `zivaone_app/src/lib/analytics/README-duckdb-blocker.md`.
2. pnpm does not support installing a subdirectory of a git repo
   (issue [pnpm#10396](https://github.com/pnpm/pnpm/issues/10396)), so
   `github:pranshuchittora/react-native-duckdb#SHA&path=/package` is
   rejected by the resolver.

## What this fork does

Restructures the `main` branch so the module is at the repo root, making
it installable via
`github:mongrov/react-native-duckdb#<sha>` from any pnpm consumer.

### File moves (this commit)

- `package/*` → repo root (podspec, sources, nitrogen output,
  package.json all now at root).
- `scripts/` — kept at repo root (now module-local); podspec references
  updated from `../scripts/` → `./scripts/`.
- `RNDuckDB.podspec` header search paths updated:
  `$(PODS_TARGET_SRCROOT)/../duckdb/src/include` →
  `$(PODS_TARGET_SRCROOT)/duckdb/src/include`.
- `scripts/build-duckdb-ios.sh` xcframework copy target updated:
  `${REPO_DIR}/package/DuckDB.xcframework` →
  `${REPO_DIR}/DuckDB.xcframework`.
- `scripts/download-duckdb.sh` vendor dir updated:
  `$ROOT_DIR/package/vendor/duckdb` → `$ROOT_DIR/vendor/duckdb`.

### Deleted (workspace-only files not needed downstream)

- `docs/`, `example/`, `RELEASE.md`, `bun.md`, `bun.lockb`
- Root `package.json` (bun workspaces meta) and `README.md`
- `.gitmodules` and empty `duckdb/` submodule directory — DuckDB
  source will be downloaded at pod-install time by
  `scripts/download-duckdb.sh` or (temporarily) manually initialized
  during the build-system verification session.

## What is NOT yet done (deferred to build-system verification session)

The upstream build scripts on `main` are **internally inconsistent**:

- `scripts/download-duckdb.sh` fetches the DuckDB **amalgamation**
  (single-file source: `duckdb.cpp/hpp/h`) into `vendor/duckdb/`.
- `scripts/build-duckdb-ios.sh` runs `cmake -S ${REPO_DIR}/duckdb`,
  which requires a **full source tree** (submodule/tarball layout,
  not amalgamation) with `src/include/`, `extension/`, `CMakeLists.txt`,
  etc.

These two paths are contradictory and cannot both succeed. The
verification session needs to pick one strategy and reconcile:

- **Option A: submodule at pod-install time.** Add a `preinstall` or
  `postinstall` step that runs
  `git clone --depth=1 --branch=v1.4.4 https://github.com/duckdb/duckdb.git ./duckdb`.
  Keeps CMake build unchanged. Adds ~200MB per install.
- **Option B: source tarball at pod-install time.** Fetch
  `duckdb/duckdb#v1.4.4` source tarball (`.tar.gz`, ~50MB), extract to
  `./duckdb/`. Keeps CMake build unchanged. Smaller.
- **Option C: amalgamation only, rewrite CMake build.** Replace
  `build-duckdb-ios.sh`'s CMake logic with a direct
  `clang++ -c duckdb.cpp` (amalgamation compile). **Loses DuckDB
  extensions** (iceberg, parquet, httpfs, etc.), which the ZivaOne
  analytics stack currently uses. Not viable without a substitute for
  the extension load path.

Recommendation: Option B (source tarball at pod-install), since it
keeps the extension build path intact and doesn't require submodule
lifecycle management from the consumer.

### Also outstanding

- **iOS pod-install verification** — 20-40 min per iteration; needs
  Xcode + iOS simulator. Verify DuckDB.xcframework builds and links.
- **Android build verification** — CMakeLists + JNI adapter. Confirm
  extensions link correctly.
- **`lib/` publish artifacts** — module uses
  `react-native-builder-bob`; `main`/`module`/`types` fields point at
  `./lib/module/index` and `./lib/typescript/module/index.d.ts` which
  don't exist in a fresh git checkout (only produced by publish-time
  build). Metro will still resolve via the `react-native` field
  (`./src/index`), but `tsc` type-check will fail. Options: run the
  builder-bob build in the fork and commit `lib/` under a
  `mongrov-releases/` branch; or drop `main`/`module`/`types` fields;
  or add a `postinstall` build step.

## Merging back upstream

If upstream refactors to fix the packaging bug (either by moving
the module out of `/package/` on main, or by shipping a proper
tarball with `/scripts/` intact), this fork can be retired and
the consumer app can pin the upstream tag directly.
