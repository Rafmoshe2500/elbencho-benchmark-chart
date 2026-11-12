#!/usr/bin/env bash
# Removes the benchmark deployments of a protocol (both layouts), their PVCs and NFS PVs.
#   usage: ./cleanup.sh <nfs|xfs|raw-block|s3|all> [NAMESPACE=...] [DELETE_NAMESPACE=1]
# S3 buckets / objects are NOT deleted (they live outside the cluster).
set -euo pipefail
P=${1:?usage: cleanup.sh <nfs|xfs|raw-block|s3|all> [KEY=VALUE ...]}; shift
for kv in "$@"; do export "${kv?}"; done
: "${NAMESPACE:=elbencho-bench}"; : "${RELEASE_PREFIX:=eb}"
case $P in all) S="nfs xfs blk s3" ;; raw-block) S=blk ;; *) S=$P ;; esac
for p in $S; do
  for rel in ${RELEASES:-$RELEASE_PREFIX-$p $RELEASE_PREFIX-$p-single}; do
    helm status "$rel" -n "$NAMESPACE" >/dev/null 2>&1 || continue
    echo "removing $rel"
    helm uninstall "$rel" -n "$NAMESPACE" --wait >/dev/null
    # StatefulSet PVCs (volumeClaimTemplates) are not removed by helm
    kubectl -n "$NAMESPACE" delete pvc -l "app.kubernetes.io/instance=$rel" --ignore-not-found >/dev/null
    kubectl delete pv -l "app.kubernetes.io/instance=$rel" --ignore-not-found >/dev/null
  done
done
[ "${DELETE_NAMESPACE:-0}" = 1 ] && kubectl delete namespace "$NAMESPACE" --ignore-not-found
echo done
