#!/usr/bin/env bash
# Renders the chart for every mode x protocol combination and every example file.
# With a cluster available (kubectl context set), also validates the manifests server-side.
set -euo pipefail
cd "$(dirname "$0")/.."
CHART=charts/elbencho
SERVER=0; kubectl version >/dev/null 2>&1 && SERVER=1
check() { # name, helm args...
  local name=$1; shift
  local out; out=$(helm template t "$CHART" "$@")
  if [ $SERVER = 1 ]; then echo "$out" | kubectl apply --dry-run=server -f - >/dev/null; fi
  echo "ok  $name"
}
helm lint "$CHART"
COMMON=(--set nfs.server=10.0.0.5 --set s3.endpoints=http://s3:9000 --set s3.accessKey=a --set s3.secretKey=b --set serviceMode.benchmark.enabled=true)
for p in file nfs block s3; do for m in standalone service job; do
  check "$m/$p" --set mode=$m --set protocol=$p "${COMMON[@]}"
done; done
for f in examples/*.yaml; do check "$f" -f "$f"; done
# negative tests
for bad in "--set mode=foo" "--set protocol=foo" "--set protocol=nfs"; do
  if helm template t "$CHART" $bad >/dev/null 2>&1; then echo "FAIL: '$bad' should be rejected"; exit 1; fi
  echo "ok  rejects: $bad"
done
