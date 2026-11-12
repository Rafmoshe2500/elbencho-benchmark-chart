#!/usr/bin/env bash
# RAW-BLOCK test 09: Max write IOPS with ALL daemons on ONE target (single PVC / export dir / bucket).
#
# usage: ./09-single-target-write-iops.sh [KEY=VALUE ...]      e.g.  ./09-single-target-write-iops.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE DEV_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 09 "$@"
