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

## Prebuilt xcframework (2026-07-30)

`pod install` no longer compiles DuckDB from source by default.
`scripts/build-duckdb-ios.sh` first calls
`scripts/fetch-prebuilt-duckdb.sh`, which downloads a prebuilt
`DuckDB.xcframework` from this repo's GitHub releases, verifies its
sha256, and lays down `DuckDB.xcframework/` + `duckdb/src/include/`
(the headers the podspec's `HEADER_SEARCH_PATHS` points at) — no
DuckDB source tree, vcpkg, AWSSDK, or OpenSSL/curl vendor builds
needed on consumer machines. A ~160MB download replaces a 15-30 min
cold compile.

- **Manifest:** `scripts/prebuilt-ios.json` pins the release tag and,
  per extension set (sorted, comma-joined key), the asset name +
  sha256. Extension sets without a published asset (and any fetch
  failure: offline, checksum mismatch) fall back to the source build
  automatically.
- **Opt out:** `DUCKDB_BUILD_FROM_SOURCE=1 pod install` forces the
  source-build path.
- **Cache:** `.duckdb-prebuilt` at the module root records the
  tarball sha256; matching marker + existing xcframework skips the
  download (re-run cost: <0.1s).
- **Publishing a new artifact** (DuckDB bump or new extension set):
  run the source build for the target extension set, then from the
  module root
  `tar -czf DuckDB-ios-<sorted-ext-dashes>.tar.gz DuckDB.xcframework duckdb/src/include`,
  `gh release create <tag> --repo mongrov/react-native-duckdb <tarball>`,
  and update `scripts/prebuilt-ios.json` with the tag + sha256.

Current release: `prebuilt-ios-duckdb-v1.4.4-r1` — DuckDB v1.4.4,
extensions `httpfs,iceberg,parquet` (the ZivaOne shape), built from
the toolchain at `784c135`; same binary verified end-to-end in the
ZivaOne iOS build on 2026-07-28.

## Known limitations

- **No `system` catalog on iOS.** SQL that resolves through DuckDB's `system`
  catalog fails with `Binder Error: Referenced table "system" not found!`.
  Seen on 2026-08-12 for `SELECT current_database()` and
  `information_schema.columns`. Use the PRAGMA forms instead:
  `PRAGMA database_list` for the current database, and
  `PRAGMA table_info('<table>')` for columns. `@mongrov/analytics` (0.8.3,
  0.8.5) already does this. Any other `information_schema.*` / `duckdb_*()`
  catalog surface should be assumed affected until checked on device. Root
  cause not yet found (mongrov/mongrov-packages#5).
- **`core_functions` is always linked.** `scripts/configure-extensions.js`
  adds it to any configured list and says so at build time. It used to be
  linked only when no list was given, so an explicit list without it silently
  dropped `sum()`, `avg()`, `date_trunc()` and `timezone()`.

## What is NOT yet done

- **iOS pod-install verification** — 20-40 min per iteration; needs
  Xcode + iOS simulator. Verify DuckDB.xcframework builds and links.
- ~~**Android build verification**~~ — **done 2026-07-31**: green
  `assembleDebug` for arm64-v8a + x86_64 with iceberg+httpfs+parquet,
  verified via ZivaOne (`libRNDuckDB.so` carries duckdb/Aws/iceberg/
  roaring symbols). 32-bit ABIs skip iceberg+httpfs by design. Needs
  vcpkg triplets `arm64-android-release` + `x64-android-release` with
  the AWSSDK dep set installed (same recipe as iOS, see
  §Prebuilt xcframework publishing / build scripts). Remaining
  Android follow-up: runtime smoke on an emulator/device (build +
  symbol level verified only), and a prebuilt-.so hosting path
  mirroring the iOS xcframework release if consumer build times hurt.
- **Merge to `mongrov-releases`** — once both platforms verify, cut
  a release branch and pin consumers to a SHA there (not the WIP
  branch head).

## Merging back upstream

If upstream refactors to fix the packaging bug (either by moving
the module out of `/package/` on main, or by shipping a proper
tarball with `/scripts/` intact), this fork can be retired and
the consumer app can pin the upstream tag directly.
