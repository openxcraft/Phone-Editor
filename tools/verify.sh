#!/bin/sh
# Full verification: every Dart package (analyze + test), the Rust core
# crate against the Dart golden vectors, the SQLite schema via CLI, and
# the security scan. Exits non-zero on the first failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DART=${DART:-dart}

for pkg in doc_engine presentation_engine sheets_engine sync_engine \
           api_mcp pdf_engine vault export_engine; do
  echo "== packages/$pkg =="
  cd "$ROOT/packages/$pkg"
  $DART pub get >/dev/null
  $DART analyze
  $DART test
done

echo "== db/schema_v1.sql via sqlite3 CLI =="
TMPDB=$(mktemp)
trap 'rm -f "$TMPDB"' EXIT
sqlite3 "$TMPDB" < "$ROOT/db/schema_v1.sql"
sqlite3 "$TMPDB" "SELECT value FROM schema_meta WHERE key = 'schema_version';"

if command -v cargo >/dev/null 2>&1; then
  echo "== rust/doc_core (golden vectors vs Dart) =="
  cd "$ROOT/rust/doc_core"
  cargo test
elif [ -x "$HOME/workspace/tools/cargo/bin/cargo" ]; then
  echo "== rust/doc_core (workspace toolchain) =="
  export RUSTUP_HOME=${RUSTUP_HOME:-$HOME/workspace/tools/rustup}
  export CARGO_HOME=${CARGO_HOME:-$HOME/workspace/tools/cargo}
  cd "$ROOT/rust/doc_core"
  "$CARGO_HOME/bin/cargo" test
else
  echo "== rust/doc_core SKIPPED (cargo not installed) =="
fi

echo "== security scan =="
sh "$ROOT/tools/security_scan.sh"

echo "All checks passed."
