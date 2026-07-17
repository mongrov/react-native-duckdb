#!/usr/bin/env bash
set -euo pipefail

# Fetch the DuckDB **full source tree** from the GitHub tag tarball,
# extract into ${REPO_DIR}/duckdb/, so that scripts/build-duckdb-ios.sh
# can `cmake -S ${REPO_DIR}/duckdb` against a proper source layout
# (CMakeLists.txt + src/include/ + extension/).
#
# Called automatically by scripts/build-duckdb-ios.sh when the source
# tree is missing (pod-install time). Idempotent: no-op if
# ${REPO_DIR}/duckdb/CMakeLists.txt already exists.
#
# Prior to the mongrov reconciliation, this script fetched the
# `libduckdb-src.zip` amalgamation (duckdb.cpp/hpp/h) into
# ${REPO_DIR}/vendor/duckdb/ — inconsistent with build-duckdb-ios.sh,
# which requires the extension build path. See FORK.md.

VERSION="${1:-v1.4.4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DUCKDB_DIR="$ROOT_DIR/duckdb"

if [ -f "$DUCKDB_DIR/CMakeLists.txt" ]; then
  echo "DuckDB source already present at $DUCKDB_DIR (skipping download)."
  exit 0
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Strip a leading "v" (e.g. v1.4.4 -> 1.4.4) for the extracted dir name.
UNPREFIXED="${VERSION#v}"
URL="https://github.com/duckdb/duckdb/archive/refs/tags/${VERSION}.tar.gz"

echo "Downloading DuckDB $VERSION source tarball..."
echo "  $URL"
curl -fsSL -o "$TMP_DIR/duckdb-src.tar.gz" "$URL"

echo "Extracting..."
tar -xzf "$TMP_DIR/duckdb-src.tar.gz" -C "$TMP_DIR"

# GitHub tarballs unpack into <repo>-<version-without-v>/…
EXTRACTED="$TMP_DIR/duckdb-${UNPREFIXED}"
if [ ! -d "$EXTRACTED" ]; then
  echo "ERROR: expected extracted dir $EXTRACTED not found"
  ls "$TMP_DIR"
  exit 1
fi

mkdir -p "$DUCKDB_DIR"
# Move contents up so $DUCKDB_DIR/CMakeLists.txt sits at the top level.
# Use tar-pipe to preserve dotfiles; simpler than shopt across shells.
( cd "$EXTRACTED" && tar cf - . ) | ( cd "$DUCKDB_DIR" && tar xf - )

echo "$VERSION" > "$DUCKDB_DIR/DUCKDB_VERSION"

echo ""
echo "DuckDB $VERSION source tree extracted to $DUCKDB_DIR"
if [ -f "$DUCKDB_DIR/CMakeLists.txt" ]; then
  echo "  ✓ CMakeLists.txt present"
fi
if [ -d "$DUCKDB_DIR/src/include" ]; then
  echo "  ✓ src/include/ present"
fi
if [ -d "$DUCKDB_DIR/extension" ]; then
  echo "  ✓ extension/ present"
fi
