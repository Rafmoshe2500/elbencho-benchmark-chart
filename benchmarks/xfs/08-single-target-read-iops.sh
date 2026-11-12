#!/usr/bin/env bash
# XFS test 08: Max read IOPS with ALL daemons on ONE target (single PVC / export dir / bucket).
#
# usage: ./08-single-target-read-iops.sh [KEY=VALUE ...]      e.g.  ./08-single-target-read-iops.sh STORAGE_CLASS=my-xfs-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" xfs 08 "$@"
