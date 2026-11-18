#!/usr/bin/env bash
# Runs several tests of one protocol in a row (the deployment and datasets are reused between tests).
#   usage: ./run-suite.sh <nfs|xfs|raw-block|s3> [TESTS="01 02 03"] [KEY=VALUE ...]
# Default TESTS: 01..11 (+16 on s3; sweeps 12/17 and AI tests 14/15 are run on their own).
# CONTINUE=1: go on with the next test after a failed one.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
P=${1:?usage: run-suite.sh <protocol> [TESTS=\"01 02\"] [KEY=VALUE ...]}; shift
TESTS=${TESTS:-}
args=()
for kv in "$@"; do case $kv in TESTS=*) TESTS=${kv#TESTS=} ;; CONTINUE=*) CONTINUE=${kv#CONTINUE=} ;; *) args+=("$kv") ;; esac; done
[ -n "$TESTS" ] || TESTS=$(cd "$D/$P" && ls [01][0-9]-*.sh | grep -vE "^1[2-57]-" | cut -c1-2 | tr "\n" " ")
failed=""
for t in $TESTS; do
  echo; echo "================= $P test $t ================="
  if ! "$D/lib/run.sh" "$P" "$t" ${args[@]+"${args[@]}"}; then
    failed="$failed $t"; [ "${CONTINUE:-0}" = 1 ] || break
  fi
done
echo; echo "summary of all runs: $D/results/summary.csv"
[ -z "$failed" ] || { echo "FAILED tests:$failed"; exit 1; }
