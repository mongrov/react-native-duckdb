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

## Reconciled build scripts (Option B — this commit)

The prior WIP scripts were internally inconsistent:

- `scripts/download-duckdb.sh` fetched the DuckDB **amalgamation**
  (single-file source: `duckdb.cpp/hpp/h`) into `vendor/duckdb/`.
- `scripts/build-duckdb-ios.sh` ran `cmake -S ${REPO_DIR}/duckdb`,
  which requires a **full source tree** (submodule/tarball layout,
  not amalgamation) with `src/include/`, `extension/`,
  `CMakeLists.txt`, etc.

This session picks **Option B (source tarball at pod-install)**,
recommended in the prior version of this file:

- `scripts/download-duckdb.sh` — rewritten to fetch
  `github.com/duckdb/duckdb/archive/refs/tags/v1.4.4.tar.gz` (~50MB),
  extract into `${REPO_DIR}/duckdb/` so the tree matches what CMake
  expects. Idempotent (skips if `duckdb/CMakeLists.txt` already
  exists).
- `scripts/build-duckdb-ios.sh` — adds a Step 0 guard that invokes
  `download-duckdb.sh` when `${DUCKDB_DIR}/CMakeLists.txt` is
  missing. No other build-script changes.
- `.gitignore` — `duckdb/` now ignored wholesale (source tree is
  fetched at pod-install time, not committed). Stale
  `package/DuckDB.xcframework/` entry replaced with root-level
  `DuckDB.xcframework/` + `.duckdb-extensions.json` (post-restructure
  locations).

Options A (submodule) and C (amalgamation-only rewrite of CMake)
were both rejected — see prior version of this file for rationale.
The extension build path (iceberg, parquet, httpfs) that the ZivaOne
analytics stack depends on is preserved.

### package.json — Lane A workaround for missing `lib/`

The fork does not commit `react-native-builder-bob` build output
(`lib/`), so consumers installing from git cannot resolve
`./lib/module/index` or `./lib/typescript/module/index.d.ts`. This
commit switches to **Lane A**: drop `main`/`module`/`types` and
rewrite `exports` main entry to point at `./src/index.ts` directly.

- Metro resolves via the `react-native` field (`./src/index`) —
  unchanged.
- TypeScript consumers with `moduleResolution: "bundler"` (or
  `"nodenext"` with `allowImportingTsExtensions`) resolve the
  `types` condition to `./src/index.ts`.

Lane B (commit `lib/` output to `wip/mongrov-restructure`) remains
available if a downstream consumer breaks on `.ts` extension in
exports. Not the default.

## What is NOT yet done

- **iOS pod-install verification** — 20-40 min per iteration; needs
  Xcode + iOS simulator. Verify DuckDB.xcframework builds and links.
- **Android build verification** — CMakeLists + JNI adapter. Confirm
  extensions link correctly.
- **Merge to `mongrov-releases`** — once both platforms verify, cut
  a release branch and pin consumers to a SHA there (not the WIP
  branch head).

## Merging back upstream

If upstream refactors to fix the packaging bug (either by moving
the module out of `/package/` on main, or by shipping a proper
tarball with `/scripts/` intact), this fork can be retired and
the consumer app can pin the upstream tag directly.
