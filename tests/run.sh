#!/usr/bin/env bash
# run.sh — run every tests/test_*.sh; one line per assertion; non-zero exit on any failure.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAILS=0
assert_eq() { # expected actual name
  if [ "$1" == "$2" ]; then echo "ok   $3"; else echo "FAIL $3: expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi
}
assert_fails() { # name cmd...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL $name: expected non-zero exit"; FAILS=$((FAILS+1)); else echo "ok   $name"; fi
}
export -f assert_eq assert_fails
for t in tests/test_*.sh; do
  echo "== $t"
  # shellcheck disable=SC1090
  source "$t"
done
echo "failures: $FAILS"
[ "$FAILS" -eq 0 ]
