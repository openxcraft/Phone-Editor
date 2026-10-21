#!/bin/sh
# Security scan: vendor/provider brand names and obvious secret shapes.
#
# Scopes
#   Brand scan:  app/ and packages/ (code and bundled strings).
#                Root docs are excluded from the brand scan: CONTEXT.md
#                and UX.md name one prohibited visual motif only in
#                order to ban it, which must not fail the scan.
#   Secret scan: app/, packages/, and the root *.md docs.
#
# Excludes .dart_tool, .git, and pubspec.lock everywhere.
# Exits 0 when clean, 1 with findings printed otherwise.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 2

status=0

# Brand words are assembled from fragments so this script never contains
# a full brand name itself.
_b1='chat''gpt'
_b2='cla''ude'
_b3='open''ai'
_b4='anthro''pic'
_b5='gem''ini'
_b6='spark''les'
BRAND_RE="$_b1|$_b2|$_b3|$_b4|$_b5|$_b6"

echo "== brand scan (app/, packages/) =="
if grep -rInEi \
    --exclude-dir=.dart_tool --exclude-dir=.git \
    --exclude='pubspec.lock' \
    "$BRAND_RE" app packages; then
  echo "FAIL: brand names found (see above)"
  status=1
else
  rc=$?
  if [ "$rc" -gt 1 ]; then echo "ERROR: brand scan failed to run"; exit 2; fi
  echo "clean"
fi

# Obvious secret shapes:
#   api_key / api-key / apikey / secret_key assigned a long literal
#   a Bearer header carrying a long literal token
#   an AWS-style access key id (AKIA + 16 upper-case/digit characters)
SECRET_RE='(api[_-]?key|secret[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:],;]{20,}|Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}|AKIA[0-9A-Z]{16}'

echo "== secret scan (app/, packages/, root *.md) =="
if grep -InE \
    --exclude-dir=.dart_tool --exclude-dir=.git \
    --exclude='pubspec.lock' \
    "$SECRET_RE" -r app packages ./*.md; then
  echo "FAIL: possible secrets found (see above)"
  status=1
else
  rc=$?
  if [ "$rc" -gt 1 ]; then echo "ERROR: secret scan failed to run"; exit 2; fi
  echo "clean"
fi

if [ "$status" -eq 0 ]; then
  echo "security_scan: OK"
else
  echo "security_scan: FINDINGS"
fi
exit "$status"
