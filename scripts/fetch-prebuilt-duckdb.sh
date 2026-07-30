#!/usr/bin/env bash
set -euo pipefail

# Try to satisfy the DuckDB.xcframework requirement from a prebuilt GitHub
# release asset instead of compiling DuckDB from source at pod-install time.
#
# Called by scripts/build-duckdb-ios.sh before its source-build path.
# Usage: fetch-prebuilt-duckdb.sh [<comma-separated extension list>]
#   (empty list = DuckDB defaults: core_functions,parquet)
#
# Exit codes:
#   0 — prebuilt DuckDB.xcframework is in place at the module root
#       (freshly downloaded + checksum-verified, or already cached)
#   2 — no prebuilt asset published for this extension set; caller
#       falls back to the source build
# Any other non-zero exit (download failure, checksum mismatch) also
# makes the caller fall back to the source build.
#
# Asset lookup is driven by scripts/prebuilt-ios.json, which pins the
# release tag + per-extension-set asset name + sha256. Publishing a new
# DuckDB version or extension set = cut a new release + update that
# manifest (see FORK.md §Prebuilt xcframework).
#
# The release tarball lays down, relative to the module root:
#   DuckDB.xcframework/          — vendored framework (device + fat sim)
#   duckdb/src/include/          — headers the podspec's
#                                  HEADER_SEARCH_PATHS points at
# so consumers never need the full DuckDB source tree, vcpkg, or the
# OpenSSL/curl vendor builds.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/prebuilt-ios.json"
MARKER="${REPO_DIR}/.duckdb-prebuilt"

EXT_LIST="${1:-}"

if [ ! -f "$MANIFEST" ]; then
  echo "prebuilt: no manifest at ${MANIFEST}"
  exit 2
fi

# Normalize the extension list into the manifest key: trim, drop empties,
# lowercase, sort, comma-join. Empty input maps to the DuckDB default set
# (mirrors configure-extensions.js DEFAULT_EXTENSIONS).
EXT_KEY=$(node -e "
  const raw = process.argv[1] || '';
  let exts = raw.split(',').map(e => e.trim().toLowerCase()).filter(Boolean);
  if (exts.length === 0) exts = ['core_functions', 'parquet'];
  process.stdout.write([...new Set(exts)].sort().join(','));
" "$EXT_LIST")

read -r REPO TAG ASSET SHA256 < <(node -e "
  const m = require('$MANIFEST');
  const a = (m.artifacts || {})['$EXT_KEY'];
  if (!a) process.exit(2);
  console.log([m.repo, m.tag, a.asset, a.sha256].join(' '));
") || { echo "prebuilt: no asset published for extension set [${EXT_KEY}]"; exit 2; }

# Cached? Marker records the sha256 of the tarball the current
# DuckDB.xcframework was extracted from.
if [ -d "${REPO_DIR}/DuckDB.xcframework" ] && [ -f "$MARKER" ] \
   && [ "$(cat "$MARKER")" = "$SHA256" ]; then
  echo "prebuilt: DuckDB.xcframework already in place (sha256 match) — skipping download"
  exit 0
fi

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "prebuilt: downloading ${ASSET} (${TAG}) for extension set [${EXT_KEY}]"
echo "          ${URL}"
curl -fL --retry 3 -o "${TMP_DIR}/${ASSET}" "$URL"

ACTUAL=$(shasum -a 256 "${TMP_DIR}/${ASSET}" | cut -d' ' -f1)
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "prebuilt: sha256 mismatch for ${ASSET}"
  echo "          expected ${SHA256}"
  echo "          actual   ${ACTUAL}"
  exit 1
fi

echo "prebuilt: extracting into ${REPO_DIR}"
rm -rf "${REPO_DIR}/DuckDB.xcframework"
tar -xzf "${TMP_DIR}/${ASSET}" -C "${REPO_DIR}"

if [ ! -d "${REPO_DIR}/DuckDB.xcframework" ]; then
  echo "prebuilt: tarball did not contain DuckDB.xcframework/ — aborting"
  exit 1
fi

# Extension metadata for the podspec (httpfs ⇒ Security/SystemConfiguration
# frameworks + libz on the consumer target) — same file the source build
# writes in build-duckdb-ios.sh step 5.
case ",${EXT_KEY}," in
  *,httpfs,*) echo '{"httpfs":true}' > "${REPO_DIR}/.duckdb-extensions.json" ;;
  *)          echo '{}'              > "${REPO_DIR}/.duckdb-extensions.json" ;;
esac

echo "$SHA256" > "$MARKER"
echo "prebuilt: DuckDB.xcframework ready (extensions: ${EXT_KEY})"
