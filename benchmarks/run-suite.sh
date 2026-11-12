#!/usr/bin/env bash
# Runs several tests of one protocol in a row (the deployment and datasets are reused between tests).
#   usage: ./run-suite.sh <nfs|xfs|raw-block|s3> [TESTS="01 02 03"] [KEY=VALUE ...]
# Default TESTS: 01..11 (all that apply). Stops at the first failing test unless CONTINUE=1.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
P=${1:?usage: run-suite.sh <protocol> [TESTS=\"01 02\"] [KEY=VALUE ...]}; shift
TESTS=${TESTS:-}
args=()
for kv in "$@"; do case $kv in TESTS=*) TESTS=${kv#TESTS=} ;; *) args+=("$kv") ;; esac; done
[ -n "$TESTS" ] || TESTS=$(cd "$D/$P" && ls [01][0-9]-*.sh | grep -v '^12-' | cut -c1-2 | tr '\n' ' ')
failed=()
for t in $TESTS; do
  echo; echo "================= $P test $t ================="
  if ! "$D/lib/run.sh" "$P" "$t" "${args[@]}"; then
    failed+=("$t"); [ "${CONTINUE:-0}" = 1 ] || break
  fi
done
echo; echo "summary of all runs: $D/results/summary.csv"
[ ${#failed[@]} -eq 0 ] || { echo "FAILED tests: ${failed[*]}"; exit 1; }
